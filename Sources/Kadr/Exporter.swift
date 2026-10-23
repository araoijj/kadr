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

extension DateFormatter {
    /// "2026-10-23" for file and folder names: fixed POSIX locale and Gregorian calendar,
    /// so a Buddhist or Japanese system calendar doesn't produce "2569-10-23".
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
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
        let date = item.date.map { DateFormatter.isoDay.string(from: $0) } ?? ""
        var name = template
            .replacingOccurrences(of: "{name}", with: original)
            .replacingOccurrences(of: "{folder}", with: folder ?? "")
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{n}", with: String(format: "%03d", item.index))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? original : name
    }

    /// One photo of a save with its output name decided up front: `base` is nil when it is already there.
    struct Job: Sendable {
        let item: ExportItem
        let base: String?
    }

    /// What became of one photo. `moved` is the new place of a moved original, so its edits can follow it.
    struct Outcome: Sendable {
        var ok = false
        var skipped = false
        var errors: [String] = []
        var moved: (from: URL, to: URL)?
    }

    /// Output names for the whole save, decided one after another before anything is written: parallel
    /// JPEG workers then never pick the same free name. An original travels with its XMP and twin as one
    /// set — one name for all of them; a set whose photo is already there (same size) is skipped whole.
    static func plan(_ items: [ExportItem], to folder: URL, _ s: ExportSettings, shootName: String?) -> [Job] {
        var reserved = Set<String>()
        return items.map { item in
            let base = baseName(item, template: s.nameTemplate, folder: shootName)
            switch s.format {
            case .original:
                let files = existingCompanions(of: item.url)
                let same = folder.appendingPathComponent(base).appendingPathExtension(item.url.pathExtension)
                if let have = size(same), have == size(item.url) {
                    return Job(item: item, base: nil)
                }
                return Job(item: item, base: freeBase(base, exts: setExtensions(files), in: folder, reserved: &reserved))
            case .jpeg:
                return Job(item: item, base: freeBase(base, exts: ["jpg"], in: folder, reserved: &reserved))
            }
        }
    }

    /// `base`, or `base-2`, `base-3`… — the first under which none of the set's files exists or is taken.
    static func freeBase(_ base: String, exts: [String], in folder: URL, reserved: inout Set<String>) -> String {
        let fm = FileManager.default
        var name = base, n = 2
        // The disk is asked for the exact name (a case-sensitive volume would miss IMG_0001.CR3 asked as
        // img_0001.cr3); the names taken in this run are compared case-insensitively.
        func names(_ b: String) -> [String] { exts.map { "\(b).\($0)" } }
        while names(name).contains(where: { reserved.contains($0.lowercased()) || fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            name = "\(base)-\(n)"
            n += 1
        }
        reserved.formUnion(names(name).map { $0.lowercased() })
        return name
    }

    /// What a set takes up under its new name: its files, and the XMP always — a stale IMG.xmp already
    /// there would otherwise become the photo's when it comes without one (its XMP couldn't be written).
    static func setExtensions(_ files: [URL]) -> [String] {
        let exts = files.map(\.pathExtension)
        return exts.contains { $0.lowercased() == "xmp" } ? exts : exts + ["xmp"]
    }

    /// Moves (or copies) a photo with its companions under one name, all or nothing: when one of them
    /// fails, the ones already done go back, so a RAW never sits in the new place without its XMP.
    /// Returns the photo's new place (nil if the set stayed) and the errors.
    static func transfer(_ files: [URL], of photo: URL, base: String, to folder: URL, move: Bool) -> (URL?, [String]) {
        let fm = FileManager.default, shared = move && sharesSidecar(photo)
        var done: [(from: URL, to: URL, moved: Bool)] = [], errors: [String] = []
        for f in files {
            let target = folder.appendingPathComponent(base).appendingPathExtension(f.pathExtension)
            let moves = move && !(shared && f == Sidecar.url(for: photo))
            do {
                if moves { try fm.moveItem(at: f, to: target) } else { try fm.copyItem(at: f, to: target) }
                done.append((f, target, moves))
            } catch {
                errors.append("\(f.lastPathComponent): \(error.localizedDescription)")
                for d in done.reversed() {
                    do {
                        if d.moved { try fm.moveItem(at: d.to, to: d.from) } else { try fm.removeItem(at: d.to) }
                    } catch {
                        errors.append("\(d.to.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (nil, errors)
            }
        }
        return (folder.appendingPathComponent(base).appendingPathExtension(photo.pathExtension), errors)
    }

    private static func size(_ u: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int
    }

    /// A single photo under the name `plan` gave it.
    static func export(_ job: Job, to folder: URL, _ s: ExportSettings) -> Outcome {
        var out = Outcome()
        guard let base = job.base else { out.skipped = true; return out }
        let item = job.item, fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            out.errors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            return out
        }
        switch s.format {
        case .original:
            // RAW, XMP and the paired JPEG get the same new name so Capture One picks up the XMP.
            let (target, errors) = transfer(existingCompanions(of: item.url), of: item.url, base: base, to: folder, move: s.move)
            out.errors = errors
            if let target {
                out.ok = true
                if s.move { out.moved = (item.url, target) }
            }
        case .jpeg:
            // Written under a hidden temporary name, then renamed without replacing anything (RENAME_EXCL):
            // a file that appeared meanwhile is never overwritten, the JPEG takes the next free name instead.
            let tmp = folder.appendingPathComponent(".\(base)-\(UUID().uuidString).kadr-tmp")
            guard writeJPEG(item, to: tmp, s) else {
                try? fm.removeItem(at: tmp)
                out.errors.append("\(item.url.lastPathComponent): " + tr("не удалось записать JPEG"))
                return out
            }
            var target = folder.appendingPathComponent(base).appendingPathExtension("jpg"), n = 2
            var failure = renameExclusive(tmp, to: target)
            while failure != 0 {
                guard failure == EEXIST else {
                    let reason = String(cString: strerror(failure))
                    try? fm.removeItem(at: tmp)
                    out.errors.append("\(item.url.lastPathComponent): \(reason)")
                    return out
                }
                target = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension("jpg")
                n += 1
                failure = renameExclusive(tmp, to: target)
            }
            out.ok = true
        }
        return out
    }

    /// Renames `tmp` to `target` unless something is already there; 0 or the errno.
    /// exFAT and FAT have no RENAME_EXCL (ENOTSUP): there the name is claimed first with O_EXCL,
    /// then the finished file takes the place of that empty claim.
    private static func renameExclusive(_ tmp: URL, to target: URL) -> Int32 {
        if renamex_np(tmp.path, target.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let e = errno
        guard e == ENOTSUP || e == EINVAL || e == ENOTTY else { return e }
        let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return errno }
        close(fd)
        if rename(tmp.path, target.path) == 0 { return 0 }
        let r = errno
        unlink(target.path)
        return r
    }

    /// The files that travel with a photo: itself, its XMP and — only for a RAW — the camera's JPEG/HEIF twin.
    /// A JPG must not drag along a HEIC of the same name: that one is a photo of its own in the grid.
    static func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        var list = [url, Sidecar.url(for: url)]
        if ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) {
            for ext in ["JPG", "JPEG", "HIF", "HEIC"] { list.append(base.appendingPathExtension(ext)) }
        }
        // On a case-insensitive volume JPG and jpg are the same file.
        var seen = Set<String>()
        return list.filter { seen.insert($0.path.lowercased()).inserted }
    }

    /// A JPG and a HEIC (PNG, TIFF…) of the same name are two photos with one IMG.xmp between them:
    /// moving one of them must leave the XMP for the other, so it goes as a copy.
    static func sharesSidecar(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ImageStore.rawExtensions.contains(ext) else { return false }
        let base = url.deletingPathExtension(), fm = FileManager.default
        return ImageStore.imageExtensions.subtracting([ext]).contains { e in
            [e, e.uppercased()].contains { fm.fileExists(atPath: base.appendingPathExtension($0).path) }
        }
    }

    static func existingCompanions(of url: URL) -> [URL] {
        companions(of: url).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// RAW development → edits → watermark → sRGB JPEG with the source EXIF.
    private static func writeJPEG(_ item: ExportItem, to target: URL, _ s: ExportSettings) -> Bool {
        // Even without edits, use the in-camera profile so colors match the preview.
        let adj = s.applyEdits ? item.adj : Adjustments()
        guard var img = EditPipeline.source(item.url, maxSide: sourceMaxSide(item.url, adj, s), raw: adj.raw) else { return false }
        img = EditPipeline.render(adj, item.url, source: img)
        img = fitToPreset(img, s, userCropped: adj.hasCrop)
        // Own long side: the source was developed with headroom, so it is brought to the exact size here.
        if s.preset == .custom, s.longSide > 0 {
            let out = outputSize(img.extent.size, userCropped: adj.hasCrop, s)
            if out != img.extent.size { img = resize(img, to: out) }
        }
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
        // The source's Exif names the RAW's full size; the JPEG is cropped and scaled.
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = cg.width
        exif[kCGImagePropertyExifPixelYDimension] = cg.height
        props[kCGImagePropertyExifDictionary] = exif
        guard let xmp = culling(item.url) else {
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
        // Rating, label and keywords go in as XMP. ImageIO takes XMP only by copying an encoded image,
        // so the JPEG is encoded in memory first and then copied (without recompression) with the XMP merged in.
        let data = NSMutableData()
        guard let mem = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(mem, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(mem), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: xmp, kCGImageDestinationMergeMetadata: true]
        return CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, nil)
    }

    /// The photo's culling from its XMP (stars or reject, colour label, keywords) for the exported JPEG, so
    /// Lightroom, Bridge and Photos see it there too; nil when there is none.
    private static func culling(_ url: URL) -> CGImageMetadata? {
        let v = Sidecar.read(for: url), words = Sidecar.keywords(for: url)
        let label = v.label?.rawValue ?? v.otherLabel
        guard v.rejected || v.rating > 0 || label != nil || !words.isEmpty else { return nil }
        let m = CGImageMetadataCreateMutable()
        if v.rejected || v.rating > 0 {
            CGImageMetadataSetValueWithPath(m, nil, "xmp:Rating" as CFString, String(v.rejected ? -1 : v.rating) as CFString)
        }
        if let label { CGImageMetadataSetValueWithPath(m, nil, "xmp:Label" as CFString, label as CFString) }
        if !words.isEmpty, let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                              "subject" as CFString, .arrayUnordered, words as CFArray) {
            CGImageMetadataSetTagWithPath(m, nil, "dc:subject" as CFString, tag)
        }
        return m
    }

    /// Final pixel size of a frame that is `px` after our own crop: the preset's plan, or the long side
    /// (never enlarged), or as is. The same for the size estimate and for the export.
    static func outputSize(_ px: CGSize, userCropped: Bool, _ s: ExportSettings) -> CGSize {
        if let plan = ExportPlan.make(aspect: Double(px.width / px.height), userCropped: userCropped, s) {
            return CGSize(width: plan.width, height: plan.height)
        }
        guard s.longSide > 0 else { return px }
        let k = min(1, CGFloat(s.longSide) / max(px.width, px.height))
        return CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
    }

    /// How far the RAW may be downscaled while developing: after our crop, the straightening zoom and a
    /// preset's center crop it must still hold the final pixels on both axes, or the frame is upscaled and soft.
    /// nil = full size. 6000×4000 cropped to half for 2560 px: 5222 px, the crop 2611 → 2560.
    static func sourceMaxSide(_ url: URL, _ adj: Adjustments, _ s: ExportSettings) -> CGFloat? {
        guard s.preset != .custom || s.longSide > 0 else { return nil }
        let ex = ImageStore.shared.exif(url)
        // Only a RAW has a camera crop to take from the preview: its shape if this session has seen it, else
        // decoded once (it is needed for cropToCamera anyway).
        let pa = ImageStore.rawExtensions.contains(url.pathExtension.lowercased())
            ? ImageStore.shared.previewAspect(url) ?? ImageStore.shared.preview(url).map { CGFloat($0.width) / CGFloat($0.height) } : nil
        let frame = ImageStore.frameSize(ex, previewAspect: pa)
        let px = CGSize(width: frame.width * adj.cropW, height: frame.height * adj.cropH)
        guard px.width > 0, px.height > 0, let native = ex.width.flatMap({ w in ex.height.map { max(w, $0) } }) else { return nil }
        let out = outputSize(px, userCropped: adj.hasCrop, s)
        // Cover, not fit: of a preset's center crop only the axis that fills it counts. 2% for rounding.
        let k = max(out.width / px.width, out.height / px.height) * EditPipeline.straightenZoom(frame, angle: adj.angle) * 1.02
        return k < 1 ? k * CGFloat(native) : nil
    }

    /// Lanczos to exactly `size` pixels.
    static func resize(_ input: CIImage, to size: CGSize) -> CIImage {
        let e = input.extent
        let k = size.width / e.width
        // Lanczos and the sub-pixel scale below sample past the edge of the image, where a CIImage is
        // transparent: the outermost column came out half transparent and turned into a light 1-px stripe
        // on the JPEG. Clamp first (edge pixels repeat outward), crop to the exact pixels last.
        var img = input.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k])
        // Bring it to the exact pixels (1080×1350, not 1080×1349 due to rounding).
        let e2 = CGSize(width: e.width * k, height: e.height * k)
        img = img.transformed(by: CGAffineTransform(scaleX: size.width / e2.width, y: size.height / e2.height))
        return img.cropped(to: CGRect(origin: .zero, size: size))
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
        return resize(img, to: CGSize(width: plan.width, height: plan.height))
    }
}
