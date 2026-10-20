import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Настройки сохранения — запоминаются между запусками.
struct ExportSettings: Codable, Equatable {
    enum Scope: String, Codable, CaseIterable { case visible, rated, selected = "current" }
    enum Format: String, Codable, CaseIterable { case original, jpeg }

    var scope: Scope = .rated
    var format: Format = .original
    var move = false              // только для оригиналов
    var jpegQuality = 0.9
    var longSide = 0              // 0 — полный размер
    var subfolder = true          // подпапка с именем съёмки
    var destination: URL?

    static let key = "exportSettings"

    static func load() -> ExportSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: d) else { return ExportSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

enum Exporter {
    /// Итоговая папка: destination или destination/<имя съёмки>.
    static func targetFolder(_ s: ExportSettings, shoot: URL?) -> URL? {
        guard let dest = s.destination else { return nil }
        if s.subfolder, let shoot { return dest.appendingPathComponent(shoot.lastPathComponent, isDirectory: true) }
        return dest
    }

    /// Один снимок. Возвращает false, если файл уже есть или произошла ошибка.
    static func export(_ url: URL, to folder: URL, _ s: ExportSettings) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        switch s.format {
        case .original:
            var ok = false
            for f in companions(of: url) where fm.fileExists(atPath: f.path) {
                let target = folder.appendingPathComponent(f.lastPathComponent)
                guard !fm.fileExists(atPath: target.path) else { continue }
                let done = (try? (s.move ? fm.moveItem(at: f, to: target) : fm.copyItem(at: f, to: target))) != nil
                if f == url { ok = done }
            }
            return ok
        case .jpeg:
            let target = uniqueURL(folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("jpg"))
            return writeJPEG(url, to: target, s)
        }
    }

    static func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        var list = [url, Sidecar.url(for: url)]
        for ext in ["JPG", "JPEG", "HIF", "HEIC"] where ext.lowercased() != url.pathExtension.lowercased() {
            list.append(base.appendingPathExtension(ext))
        }
        // На регистронезависимом диске JPG и jpg — один файл.
        var seen = Set<String>()
        return list.filter { seen.insert($0.path.lowercased()).inserted }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Полное проявление RAW → JPEG sRGB, с EXIF исходника.
    private static func writeJPEG(_ url: URL, to target: URL, _ s: ExportSettings) -> Bool {
        var image: CIImage?
        if ImageStore.rawExtensions.contains(url.pathExtension.lowercased()), let raw = CIRAWFilter(imageURL: url) {
            // Уменьшение прямо при проявлении — в разы быстрее, чем проявить 50 Мп и потом сжать.
            if s.longSide > 0 {
                let n = raw.nativeSize
                let k = Double(s.longSide) / max(n.width, n.height)
                if k < 1 { raw.scaleFactor = Float(k) }
            }
            image = raw.outputImage
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard var img = image else { return false }
        if s.longSide > 0 {
            let k = Double(s.longSide) / max(img.extent.width, img.extent.height)
            if k < 0.999 {
                let f = CIFilter(name: "CILanczosScaleTransform")!
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(k, forKey: kCIInputScaleKey)
                f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                img = f.outputImage ?? img
            }
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: srgb),
              let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }

        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: s.jpegQuality]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for k in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary] {
                if let v = p[k] { props[k] = v }
            }
        }
        props[kCGImagePropertyOrientation] = 1   // поворот уже применён при проявлении
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let u = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }
}
