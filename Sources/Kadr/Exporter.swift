import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ready-made sizes for social networks. Each photo's aspect ratio comes from its crop in Kadr,
/// so there's nothing to set up twice; the preset only fits the size to the network's requirements.
enum ExportPreset: String, Codable, CaseIterable, Identifiable {
    case custom, instagram, story, web
    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: tr("Свои настройки")
        case .instagram: tr("Instagram лента")
        case .story: tr("Сторис / Reels")
        case .web: tr("Сайт / Telegram")
        }
    }

    var subtitle: String {
        switch self {
        case .custom: tr("формат, размер и качество — вручную")
        case .instagram: tr("1080 по ширине, формат — из вашего кадрирования")
        case .story: "1080 × 1920"
        case .web: tr("2560 px по длинной стороне")
        }
    }

    /// The old "post/square/landscape" presets are now a single "Instagram feed".
    init(from d: Decoder) throws {
        let raw = try d.singleValueContainer().decode(String.self)
        switch raw {
        case "igPost", "igSquare", "igLandscape": self = .instagram
        case "igStory": self = .story
        default: self = ExportPreset(rawValue: raw) ?? .custom
        }
    }
}

/// What a photo turns into with the chosen preset; the same logic for the dialog summary and for export.
struct ExportPlan: Hashable {
    let width: Int
    let height: Int
    let crop: Double?        // center-crop to this aspect ratio; nil = no crop
    let note: String

    static let igMin = 4.0 / 5, igMax = 1.91, story = 9.0 / 16

    static func make(aspect a: Double, userCropped: Bool, _ s: ExportSettings) -> ExportPlan? {
        switch s.preset {
        case .custom: return nil
        case .web:
            let w = a >= 1 ? 2560 : Int((2560 * a).rounded()), h = a >= 1 ? Int((2560 / a).rounded()) : 2560
            return ExportPlan(width: w, height: h, crop: nil, note: tr("без обрезки"))
        case .instagram:
            // Our 4:5, 1:1, 1.91:1 can come out as 0.802 after pixel rounding, so snap to the exact ratio.
            for (ratio, h) in [(igMin, 1350), (1.0, 1080), (igMax, 566)] where abs(a - ratio) / ratio < 0.015 {
                return ExportPlan(width: 1080, height: h, crop: a == ratio ? nil : ratio,
                                  note: userCropped ? tr("по вашему кадрированию") : tr("как снято, формат подходит Instagram"))
            }
            if a < igMin * 0.995 {
                return ExportPlan(width: 1080, height: 1350, crop: igMin, note: tr("выше 4:5 — обрезка по центру до 4:5 (Instagram больше не принимает)"))
            }
            if a > igMax * 1.005 {
                return ExportPlan(width: 1080, height: 566, crop: igMax, note: tr("шире 1.91:1 — обрезка по центру до 1.91:1"))
            }
            let h = abs(a - igMax) / igMax < 0.01 ? 566 : Int((1080 / a).rounded())
            return ExportPlan(width: 1080, height: h, crop: nil, note: userCropped ? tr("по вашему кадрированию") : tr("как снято, формат подходит Instagram"))
        case .story:
            if abs(a - story) / story < 0.015 {
                return ExportPlan(width: 1080, height: 1920, crop: a == story ? nil : story, note: userCropped ? tr("по вашему кадрированию 9:16") : tr("уже 9:16"))
            }
            if s.presetCrop { return ExportPlan(width: 1080, height: 1920, crop: story, note: tr("обрезка по центру до 9:16")) }
            let w = a < story ? Int((1920 * a).rounded()) : 1080, h = a < story ? 1920 : Int((1080 / a).rounded())
            return ExportPlan(width: w, height: h, crop: nil, note: tr("вписано в 9:16 без обрезки"))
        }
    }
}

/// Save settings, remembered between launches.
struct ExportSettings: Codable, Equatable {
    enum Scope: String, Codable, CaseIterable { case visible, rated, selected = "current" }
    enum Format: String, Codable, CaseIterable { case original, jpeg }

    var scope: Scope = .rated
    var format: Format = .original
    var move = false              // originals only
    var jpegQuality = 0.9
    var longSide = 0              // 0 = full size
    var subfolder = true          // subfolder named after the shoot
    var destination: URL?

    var applyEdits = true         // JPEG with edits and style
    var nameTemplate = "{name}"   // {name} {folder} {date} {n}
    var watermarkOn = false
    var watermarkText = ""
    var watermarkSize = 3.0       // % of the long side
    var watermarkOpacity = 0.6
    var watermarkPosition: Watermark.Position = .bottomRight
    var preset: ExportPreset = .custom
    var presetCrop = true         // if the photo's aspect ratio differs, center-crop (otherwise fit)

    static let key = "exportSettings"

    init() {}

    /// Old saved settings without the new fields are still readable.
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
        preset = (try? c.decode(ExportPreset.self, forKey: .preset)) ?? def.preset
        presetCrop = (try? c.decode(Bool.self, forKey: .presetCrop)) ?? def.presetCrop
        // Former "Website/Telegram" preset is now just a 2560 px size.
        if preset == .web { preset = .custom; longSide = 2560 }
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

/// A single photo to save.
struct ExportItem: Sendable {
    let url: URL
    let adj: Adjustments
    let date: Date?
    let index: Int      // sequence number within the save, starting at 1
}

enum Exporter {
    /// Output folder: destination or destination/<shoot name>.
    static func targetFolder(_ s: ExportSettings, shoot: URL?) -> URL? {
        guard let dest = s.destination else { return nil }
        if s.subfolder, let shoot { return dest.appendingPathComponent(shoot.lastPathComponent, isDirectory: true) }
        return dest
    }

    /// File name from the template, without extension.
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

    /// A single photo. Returns false if the file already exists or an error occurred.
    static func export(_ item: ExportItem, to folder: URL, _ s: ExportSettings, shootName: String?) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = baseName(item, template: s.nameTemplate, folder: shootName)
        switch s.format {
        case .original:
            // RAW, XMP and the paired JPEG get the same new name so Capture One picks up the XMP.
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
        // On a case-insensitive volume JPG and jpg are the same file.
        var seen = Set<String>()
        return list.filter { seen.insert($0.path.lowercased()).inserted }
    }

    private static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// RAW development → edits → watermark → sRGB JPEG with the source EXIF.
    private static func writeJPEG(_ item: ExportItem, to target: URL, _ s: ExportSettings) -> Bool {
        // How many pixels we need from the RAW: with headroom for our own crop.
        var maxSide: CGFloat? = s.longSide > 0 ? CGFloat(s.longSide) : nil
        if s.preset != .custom {
            let need: CGFloat = s.preset == .web ? 2560 : 1920
            maxSide = need / CGFloat(max(min(item.adj.cropW, item.adj.cropH), 0.2)) * 1.2
        }
        guard var img = EditPipeline.source(item.url, maxSide: maxSide) else { return false }
        // Even without edits, use the in-camera profile so colors match the preview.
        let adj = s.applyEdits ? item.adj : Adjustments()
        img = EditPipeline.apply(adj, to: img, cameraCube: adj.profile == .camera ? CameraMatch.shared.cube(for: item.url) : nil,
                                 asShotK: ImageStore.shared.asShotK(item.url), denoised: Denoiser.shared.input(for: item.url, adj))
        img = fitToPreset(img, s, userCropped: adj.hasCrop)
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
        props[kCGImagePropertyOrientation] = 1   // rotation already applied during development
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// To the social network's planned requirements: center crop (if needed) and exact pixel size.
    static func fitToPreset(_ input: CIImage, _ s: ExportSettings, userCropped: Bool) -> CIImage {
        var img = input
        let e = img.extent
        guard let plan = ExportPlan.make(aspect: Double(e.width / e.height), userCropped: userCropped, s) else { return img }
        if let t = plan.crop {
            let target = CGFloat(t)
            let r = (e.width / e.height > target
                ? CGRect(x: e.midX - e.height * target / 2, y: e.minY, width: e.height * target, height: e.height)
                : CGRect(x: e.minX, y: e.midY - e.width / target / 2, width: e.width, height: e.width / target)).integral
            img = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        let e2 = img.extent
        let k = CGFloat(plan.width) / e2.width
        img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k])
        // Bring it to the plan's exact pixels (1080×1350, not 1080×1349 due to rounding).
        let e3 = img.extent
        img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(plan.width) / e3.width, y: CGFloat(plan.height) / e3.height))
        return img.cropped(to: CGRect(x: 0, y: 0, width: plan.width, height: plan.height))
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
