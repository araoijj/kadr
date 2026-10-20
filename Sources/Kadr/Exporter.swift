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

    var applyEdits = true         // JPEG с обработкой и стилем
    var nameTemplate = "{name}"   // {name} {folder} {date} {n}
    var watermarkOn = false
    var watermarkText = ""
    var watermarkSize = 3.0       // % от длинной стороны
    var watermarkOpacity = 0.6
    var watermarkPosition: Watermark.Position = .bottomRight

    static let key = "exportSettings"

    init() {}

    /// Старые сохранённые настройки без новых полей тоже читаются.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = ExportSettings()
        scope = (try? c.decode(Scope.self, forKey: .scope)) ?? def.scope
        format = (try? c.decode(Format.self, forKey: .format)) ?? def.format
        move = (try? c.decode(Bool.self, forKey: .move)) ?? def.move
        jpegQuality = (try? c.decode(Double.self, forKey: .jpegQuality)) ?? def.jpegQuality
        longSide = (try? c.decode(Int.self, forKey: .longSide)) ?? def.longSide
        subfolder = (try? c.decode(Bool.self, forKey: .subfolder)) ?? def.subfolder
        destination = try? c.decode(URL.self, forKey: .destination)
        applyEdits = (try? c.decode(Bool.self, forKey: .applyEdits)) ?? def.applyEdits
        nameTemplate = (try? c.decode(String.self, forKey: .nameTemplate)) ?? def.nameTemplate
        watermarkOn = (try? c.decode(Bool.self, forKey: .watermarkOn)) ?? def.watermarkOn
        watermarkText = (try? c.decode(String.self, forKey: .watermarkText)) ?? def.watermarkText
        watermarkSize = (try? c.decode(Double.self, forKey: .watermarkSize)) ?? def.watermarkSize
        watermarkOpacity = (try? c.decode(Double.self, forKey: .watermarkOpacity)) ?? def.watermarkOpacity
        watermarkPosition = (try? c.decode(Watermark.Position.self, forKey: .watermarkPosition)) ?? def.watermarkPosition
    }

    static func load() -> ExportSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: d) else { return ExportSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// Один снимок для сохранения.
struct ExportItem: Sendable {
    let url: URL
    let adj: Adjustments
    let date: Date?
    let index: Int      // порядковый номер в сохранении, с 1
}

enum Exporter {
    /// Итоговая папка: destination или destination/<имя съёмки>.
    static func targetFolder(_ s: ExportSettings, shoot: URL?) -> URL? {
        guard let dest = s.destination else { return nil }
        if s.subfolder, let shoot { return dest.appendingPathComponent(shoot.lastPathComponent, isDirectory: true) }
        return dest
    }

    /// Имя файла по шаблону, без расширения.
    static func baseName(_ item: ExportItem, template: String, folder: String?) -> String {
        let original = item.url.deletingPathExtension().lastPathComponent
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let date = item.date.map { f.string(from: $0) } ?? ""
        var name = template
            .replacingOccurrences(of: "{name}", with: original)
            .replacingOccurrences(of: "{folder}", with: folder ?? "")
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{n}", with: String(format: "%03d", item.index))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? original : name
    }

    /// Один снимок. Возвращает false, если файл уже есть или произошла ошибка.
    static func export(_ item: ExportItem, to folder: URL, _ s: ExportSettings, shootName: String?) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = baseName(item, template: s.nameTemplate, folder: shootName)
        switch s.format {
        case .original:
            // RAW, XMP и парный JPEG получают одно новое имя — так Capture One видит XMP.
            var ok = false
            for f in companions(of: item.url) where fm.fileExists(atPath: f.path) {
                let target = folder.appendingPathComponent(base).appendingPathExtension(f.pathExtension)
                guard !fm.fileExists(atPath: target.path) else { continue }
                let done = (try? (s.move ? fm.moveItem(at: f, to: target) : fm.copyItem(at: f, to: target))) != nil
                if f == item.url { ok = done }
            }
            return ok
        case .jpeg:
            let target = uniqueURL(folder.appendingPathComponent(base).appendingPathExtension("jpg"))
            return writeJPEG(item, to: target, s)
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

    private static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// Проявление RAW → обработка → водяной знак → JPEG sRGB с EXIF исходника.
    private static func writeJPEG(_ item: ExportItem, to target: URL, _ s: ExportSettings) -> Bool {
        guard var img = EditPipeline.source(item.url, maxSide: s.longSide > 0 ? CGFloat(s.longSide) : nil) else { return false }
        if s.applyEdits { img = EditPipeline.apply(item.adj, to: img) }
        if s.watermarkOn {
            img = EditPipeline.watermark(img, text: s.watermarkText, sizePercent: s.watermarkSize,
                                         opacity: s.watermarkOpacity, position: s.watermarkPosition)
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: srgb),
              let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }

        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: s.jpegQuality]
        if let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
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
