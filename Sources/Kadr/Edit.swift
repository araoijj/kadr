import AppKit
import CoreImage
import Foundation
import ImageIO

/// Per-frame edit settings. Sliders are −100…100 (exposure in EV, hues in degrees); 0 means no change.
struct Adjustments: Codable, Equatable, Hashable {
    enum Profile: String, Codable, CaseIterable {
        case camera     // colors as in the camera JPEG (fitted to the embedded preview)
        case standard   // macOS RAW development as is
    }

    var profile: Profile = .camera
    var exposure: Double = 0      // −3…+3 EV
    var wbShift: Double = 0       // white balance: shift from "as shot", in kelvin (+ is warmer)
    var tint: Double = 0          // −150…+150 as in Lightroom: greener ← → more magenta
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var fade: Double = 0          // 0…100, "matte" look: lifted blacks
    var clarity: Double = 0       // local contrast
    var vibrance: Double = 0
    var saturation: Double = 0
    var shadowHue: Double = 0     // shadow toning: 0…360
    var shadowSat: Double = 0     // 0…100
    var highlightHue: Double = 0  // highlight toning
    var highlightSat: Double = 0
    var vignette: Double = 0      // − darkens the edges, + lightens them
    var grain: Double = 0         // 0…100
    var lut: String?              // path inside the LUT folder (.cube or HaldCLUT .png)
    var lutAmount: Double = 100   // 0…200: above 100 amplifies the LUT effect
    var aiDenoise: Double = 0     // 0…100: AI noise reduction strength (needs the cached SCUNet result)

    // Crop: a rectangle in frame fractions (y from top to bottom) plus horizon straightening, in degrees.
    var cropX: Double = 0
    var cropY: Double = 0
    var cropW: Double = 1
    var cropH: Double = 1
    var angle: Double = 0
    var cropAspect: String?       // format selected in the panel (for highlighting); does not affect the image

    var hasCrop: Bool { cropX != 0 || cropY != 0 || cropW != 1 || cropH != 1 }
    var hasGeometry: Bool { hasCrop || angle != 0 }
    var cropRect: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropW, height: cropH) }
        set { cropX = newValue.minX; cropY = newValue.minY; cropW = newValue.width; cropH = newValue.height }
    }

    static let none = Adjustments()
    /// "Before" for the Before/After slider: no color or tone, but the same crop and horizon, so the halves line up.
    var beforeVersion: Adjustments {
        var b = Adjustments()
        b.profile = profile
        b.cropRect = cropRect
        b.angle = angle
        b.cropAspect = cropAspect
        return b
    }

    /// Unchanged: everything at defaults and no LUT selected (its amount doesn't matter then).
    var isIdentity: Bool { var a = self; a.lutAmount = 100; a.cropAspect = nil; return a == .none }
}

extension Adjustments {
    private enum LegacyKeys: String, CodingKey { case temperature }

    /// Recipe builder: Adjustments { $0.contrast = 20; $0.vibrance = 30 }
    init(_ build: (inout Adjustments) -> Void) {
        self.init()
        build(&self)
    }

    /// Old edits.json and styles.json files without the new fields still decode.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init()
        func v(_ k: CodingKeys) -> Double? { try? c.decodeIfPresent(Double.self, forKey: k) }
        profile = (try? c.decodeIfPresent(Profile.self, forKey: .profile)) ?? .camera
        // Old saves stored "temperature" in arbitrary −100…100 units (1 unit ≈ 30 K); convert to kelvin.
        let legacy = try? d.container(keyedBy: LegacyKeys.self)
        let oldTemp = (try? legacy?.decodeIfPresent(Double.self, forKey: .temperature)) ?? nil
        exposure = v(.exposure) ?? 0; wbShift = v(.wbShift) ?? (oldTemp.map { $0 * 30 } ?? 0); tint = v(.tint) ?? 0
        contrast = v(.contrast) ?? 0; highlights = v(.highlights) ?? 0; shadows = v(.shadows) ?? 0
        fade = v(.fade) ?? 0; clarity = v(.clarity) ?? 0; vibrance = v(.vibrance) ?? 0; saturation = v(.saturation) ?? 0
        shadowHue = v(.shadowHue) ?? 0; shadowSat = v(.shadowSat) ?? 0
        highlightHue = v(.highlightHue) ?? 0; highlightSat = v(.highlightSat) ?? 0
        vignette = v(.vignette) ?? 0; grain = v(.grain) ?? 0
        lut = try? c.decodeIfPresent(String.self, forKey: .lut)
        lutAmount = v(.lutAmount) ?? 100
        aiDenoise = v(.aiDenoise) ?? 0
        cropX = v(.cropX) ?? 0; cropY = v(.cropY) ?? 0; cropW = v(.cropW) ?? 1; cropH = v(.cropH) ?? 1
        angle = v(.angle) ?? 0
        cropAspect = try? c.decodeIfPresent(String.self, forKey: .cropAspect)
    }
}

/// Settings groups, as in Lightroom's "New Preset" window: a style can store only some of them.
enum StyleGroup: String, Codable, CaseIterable, Identifiable {
    case profile, light, color, toning, effects, lut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: tr("Профиль")
        case .light: tr("Свет")
        case .color: tr("Цвет")
        case .toning: tr("Тонирование")
        case .effects: tr("Эффекты")
        case .lut: "LUT"
        }
    }
}

extension Adjustments {
    private static let syncedNumbers: [WritableKeyPath<Adjustments, Double>] = [
        \.exposure, \.tint, \.contrast, \.highlights, \.shadows, \.fade, \.clarity, \.vibrance, \.saturation,
        \.shadowHue, \.shadowSat, \.highlightHue, \.highlightSat, \.vignette, \.grain, \.lutAmount,
    ]

    /// Applies what changed between `old` and `new` (on another photo) to this photo: changed settings take
    /// the new value, the rest stay. White balance carries the absolute kelvin; crop and horizon are not synced.
    func syncing(from old: Adjustments, to new: Adjustments, asShotK srcK: Double?, target: URL) -> Adjustments {
        var r = self
        for kp in Self.syncedNumbers where old[keyPath: kp] != new[keyPath: kp] { r[keyPath: kp] = new[keyPath: kp] }
        if old.profile != new.profile { r.profile = new.profile }
        if old.lut != new.lut { r.lut = new.lut }
        if old.wbShift != new.wbShift, let srcK {
            r.wbShift = ((srcK + new.wbShift - ImageStore.shared.asShotK(target)) / 10).rounded() * 10
        }
        return r
    }

    /// Copies only the selected groups from the style; leaves the rest of the frame untouched.
    mutating func merge(_ s: Adjustments, groups: Set<StyleGroup>) {
        for g in groups {
            switch g {
            case .profile: profile = s.profile
            case .light: exposure = s.exposure; contrast = s.contrast; highlights = s.highlights; shadows = s.shadows; clarity = s.clarity; fade = s.fade
            case .color: wbShift = s.wbShift; tint = s.tint; vibrance = s.vibrance; saturation = s.saturation
            case .toning: shadowHue = s.shadowHue; shadowSat = s.shadowSat; highlightHue = s.highlightHue; highlightSat = s.highlightSat
            case .effects: vignette = s.vignette; grain = s.grain
            case .lut: lut = s.lut; lutAmount = s.lutAmount
            }
        }
    }

    /// Whether the frame matches the style within the style's groups.
    func matches(_ s: Adjustments, groups: Set<StyleGroup>) -> Bool {
        var a = self
        a.merge(s, groups: groups)
        return a == self
    }

    /// Groups that have something changed.
    var changedGroups: Set<StyleGroup> {
        Set(StyleGroup.allCases.filter { g in
            var a = Adjustments(); a.merge(self, groups: [g]); return a != Adjustments()
        })
    }
}

struct Style: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var adj: Adjustments
    var builtIn = false
    var collection = "Мои стили"
    var groups: Set<StyleGroup> = Set(StyleGroup.allCases)

    init(_ name: String, _ collection: String, builtIn: Bool = true, _ build: (inout Adjustments) -> Void) {
        self.name = name
        self.collection = collection
        self.builtIn = builtIn
        self.adj = Adjustments(build)
    }

    init(name: String, adj: Adjustments, groups: Set<StyleGroup> = Set(StyleGroup.allCases), collection: String = "Мои стили") {
        self.name = name
        self.adj = adj
        self.groups = groups
        self.collection = collection
        builtIn = false
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        adj = try c.decode(Adjustments.self, forKey: .adj)
        builtIn = false
        collection = (try? c.decode(String.self, forKey: .collection)) ?? "Мои стили"
        groups = (try? c.decode(Set<StyleGroup>.self, forKey: .groups)) ?? Set(StyleGroup.allCases)
    }

    /// Whether the style needs a LUT that isn't installed yet (the collection wasn't downloaded).
    var missingLUT: Bool { adj.lut.map { !LUTStore.shared.exists($0) } ?? false }
}

// MARK: - Stores

enum AppFolders {
    /// Default data location, or the one chosen in Settings ("Storage → Data folder").
    static var defaultSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kadr", isDirectory: true)
    }

    static var support: URL {
        let u = Prefs.dataFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultSupport
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var luts: URL {
        let u = support.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Edits for a shoot's frames: <folder>/.kadr/edits.json, keyed by file name.
enum EditStore {
    static func file(in folder: URL) -> URL { folder.appendingPathComponent(".kadr/edits.json") }

    static func load(_ folder: URL) -> [String: Adjustments] {
        guard let d = try? Data(contentsOf: file(in: folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: Adjustments].self, from: d)) ?? [:]
    }

    static func save(_ edits: [String: Adjustments], in folder: URL) {
        let f = file(in: folder)
        // Don't create .kadr in folders where nothing was edited.
        if edits.values.allSatisfy(\.isIdentity) && !FileManager.default.fileExists(atPath: f.path) { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(edits.filter { !$0.value.isIdentity }) { try? d.write(to: f, options: .atomic) }
    }
}

enum StyleStore {
    static var file: URL { AppFolders.support.appendingPathComponent("styles.json") }

    static func load() -> [Style] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Style].self, from: d)) ?? []
    }

    static func save(_ styles: [Style]) {
        if let d = try? JSONEncoder().encode(styles.filter { !$0.builtIn }) { try? d.write(to: file, options: .atomic) }
    }
}

/// LUTs: .cube (3D) or HaldCLUT .png of any level. Parsed once and kept in memory.
/// Stored in the app's LUT folder, including collection subfolders.
final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()
    private let lock = NSLock()
    private var cache: [String: (size: Int, data: Data)] = [:]

    static func isLUT(_ name: String) -> Bool {
        let e = (name as NSString).pathExtension.lowercased()
        return e == "cube" || e == "png"
    }

    /// Relative paths of all LUTs, e.g. "t3mujinpack/… Portra 400.png".
    func list() -> [String] {
        let root = AppFolders.luts
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var out: [String] = []
        while let u = en?.nextObject() as? URL {
            guard Self.isLUT(u.lastPathComponent) else { continue }
            out.append(String(u.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: AppFolders.luts.appendingPathComponent(name).path) }

    /// Human-readable name: no folder, extension or collection prefix.
    static func displayName(_ path: String) -> String {
        var n = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for prefix in ["t3mujinpack - "] where n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)) }
        for cat in ["Color Negative - ", "Color Slide - ", "Black and White - "] where n.hasPrefix(cat) { n = String(n.dropFirst(cat.count)) }
        return n
    }

    /// Group for the list: collection folder + film category.
    static func group(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let n = (path as NSString).lastPathComponent
        let cat = n.contains("Color Negative") ? tr("негатив") : n.contains("Color Slide") ? tr("слайд") : n.contains("Black and White") ? tr("ч/б") : nil
        let base = folder.isEmpty ? tr("Мои LUT") : folder
        return cat.map { "\(base) · \($0)" } ?? base
    }

    /// Copies files into the app's LUT folder. Returns the names of the accepted ones.
    func importFiles(_ urls: [URL]) -> [String] {
        var ok: [String] = []
        for u in urls where Self.isLUT(u.lastPathComponent) {
            let dest = AppFolders.luts.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil, cube(u.lastPathComponent) != nil {
                ok.append(u.lastPathComponent)
            } else {
                try? FileManager.default.removeItem(at: dest)
            }
        }
        return ok
    }

    func cube(_ name: String) -> (size: Int, data: Data)? {
        lock.lock()
        if let c = cache[name] { lock.unlock(); return c }
        lock.unlock()
        let url = AppFolders.luts.appendingPathComponent(name)
        let parsed = url.pathExtension.lowercased() == "png" ? Self.parseHald(url) : Self.parseCube(url)
        guard let parsed else { return nil }
        lock.lock(); cache[name] = parsed; lock.unlock()
        return parsed
    }

    private static func parseCube(_ url: URL) -> (size: Int, data: Data)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var size = 0
        var values: [Float] = []
        var lo: [Float] = [0, 0, 0], hi: [Float] = [1, 1, 1]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if line.hasPrefix("LUT_3D_SIZE"), parts.count > 1 { size = Int(parts[1]) ?? 0; continue }
            if line.hasPrefix("DOMAIN_MIN"), parts.count > 3 { lo = parts[1...3].compactMap { Float($0) }; continue }
            if line.hasPrefix("DOMAIN_MAX"), parts.count > 3 { hi = parts[1...3].compactMap { Float($0) }; continue }
            if line.first?.isLetter == true { continue }   // TITLE, LUT_1D_SIZE and the like
            let rgb = parts.prefix(3).compactMap { Float($0) }
            guard rgb.count == 3 else { continue }
            for i in 0..<3 { values.append((rgb[i] - lo[i]) / max(hi[i] - lo[i], 0.0001)) }
            values.append(1)
        }
        guard size >= 2, values.count == size * size * size * 4 else { return nil }
        return (size, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// HaldCLUT of level L: an L³×L³ image, an L² cube; cubes larger than 64 are resampled to 64.
    private static func parseHald(_ url: URL) -> (size: Int, data: Data)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width == img.height else { return nil }
        let w = img.width
        let level = Int(pow(Double(w), 1.0 / 3).rounded())   // w = L³ → L
        guard level >= 2, level * level * level == w else { return nil }
        let n = level * level
        var px = [UInt8](repeating: 0, count: w * w * 4)
        guard let ctx = CGContext(data: &px, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: w))
        // In HaldCLUT red changes fastest, same as in a Core Image cube.
        func at(_ r: Int, _ g: Int, _ b: Int, _ ch: Int) -> Float { Float(px[(r + g * n + b * n * n) * 4 + ch]) / 255 }
        let out = min(n, 64)
        var values = [Float](repeating: 1, count: out * out * out * 4)
        let k = Float(n - 1) / Float(out - 1)
        for b in 0..<out {
            for g in 0..<out {
                for r in 0..<out {
                    let fr = Float(r) * k, fg = Float(g) * k, fb = Float(b) * k
                    let r0 = Int(fr), g0 = Int(fg), b0 = Int(fb)
                    let r1 = min(r0 + 1, n - 1), g1 = min(g0 + 1, n - 1), b1 = min(b0 + 1, n - 1)
                    let dr = fr - Float(r0), dg = fg - Float(g0), db = fb - Float(b0)
                    let i = (r + g * out + b * out * out) * 4
                    for ch in 0..<3 {
                        let c00 = at(r0, g0, b0, ch) * (1 - dr) + at(r1, g0, b0, ch) * dr
                        let c10 = at(r0, g1, b0, ch) * (1 - dr) + at(r1, g1, b0, ch) * dr
                        let c01 = at(r0, g0, b1, ch) * (1 - dr) + at(r1, g0, b1, ch) * dr
                        let c11 = at(r0, g1, b1, ch) * (1 - dr) + at(r1, g1, b1, ch) * dr
                        values[i + ch] = (c00 * (1 - dg) + c10 * dg) * (1 - db) + (c01 * (1 - dg) + c11 * dg) * db
                    }
                }
            }
        }
        return (out, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

// MARK: - Processing pipeline

enum EditPipeline {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let vignetteKernel = CIKernel(source: """
        kernel vec4 vignette(sampler s, vec2 c, float radius, float amount) {
            vec4 p = sample(s, samplerCoord(s));
            float d = distance(destCoord(), c) / radius;
            float k = smoothstep(0.3, 1.0, d);
            k = k * k * (3.0 - 2.0 * k);
            vec3 rgb = amount < 0.0 ? p.rgb * (1.0 + amount * 0.95 * k) : p.rgb + (vec3(1.0) - p.rgb) * amount * 0.9 * k;
            return vec4(rgb, p.a);
        }
        """)!

    private static let mixKernel = CIColorKernel(source:
        "kernel vec4 mixk(__sample a, __sample b, float k) { return vec4(max(a.rgb + (b.rgb - a.rgb) * k, vec3(0.0)), a.a); }")!

    /// Horizon straightening (with zoom so there are no empty corners) and cropping.
    static func geometry(_ input: CIImage, _ a: Adjustments) -> CIImage {
        var img = input
        let e = input.extent
        if a.angle != 0 {
            let t: CGFloat = CGFloat(abs(a.angle)) * .pi / 180
            let w: CGFloat = e.width, h: CGFloat = e.height
            let c: CGFloat = cos(t), sn: CGFloat = sin(t)
            let sx: CGFloat = (w * c + h * sn) / w
            let sy: CGFloat = (w * sn + h * c) / h
            let s: CGFloat = max(sx, sy)
            let rot: CGFloat = CGFloat(-a.angle) * .pi / 180
            var tr = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            tr = tr.concatenating(CGAffineTransform(rotationAngle: rot))
            tr = tr.concatenating(CGAffineTransform(scaleX: s, y: s))
            tr = tr.concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
            img = img.clampedToExtent().transformed(by: tr).cropped(to: e)
        }
        if a.hasCrop {
            let r = CGRect(x: e.minX + a.cropX * e.width, y: e.minY + (1 - a.cropY - a.cropH) * e.height,
                           width: a.cropW * e.width, height: a.cropH * e.height).integral
            img = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        return img
    }

    private static let grainKernel = CIColorKernel(source:
        "kernel vec4 grain(__sample s, __sample n, float a) { return vec4(s.rgb * (1.0 + (n.r - 0.5) * a), s.a); }")!

    /// Applies the settings to a linear image (CIRAWFilter output or a preview).
    /// cameraCube is the fitted "Camera matching" profile (developed RAW only).
    /// asShotK is the "as shot" white balance (from the RAW); the kelvin shift is relative to it.
    static func apply(_ a: Adjustments, to input: CIImage, cameraCube: (size: Int, data: Data)? = nil, asShotK: Double = 5500,
                      denoised: CIImage? = nil) -> CIImage {
        // 0. AI noise reduction — on the RAW base, before everything else.
        let base = a.aiDenoise > 0 && denoised != nil ? Denoiser.apply(input, denoised: denoised!, amount: a.aiDenoise / 100) : input
        var img = a.hasGeometry ? geometry(base, a) : base
        let e = img.extent
        let longSide = max(e.width, e.height)

        // 1. Linear stage, like Lightroom's "Basic" panel: before the profile.
        if a.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.wbShift != 0 || a.tint != 0 {
            // As in Lightroom: "the light was K" → the image is recomputed from "as shot". Higher K is warmer.
            // Signs verified by measuring R/G/B: "+" tint is more magenta.
            let k = min(max(asShotK + a.wbShift, 2000), 50000)
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: k, y: 0),
                "inputTargetNeutral": CIVector(x: asShotK, y: -a.tint),
            ])
        }
        let hlAmount = a.highlights < 0 ? 1 + a.highlights / 100 : 1
        let shAmount = a.shadows > 0 ? a.shadows / 100 : 0
        if hlAmount != 1 || shAmount != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": hlAmount, "inputShadowAmount": shAmount, "inputRadius": 0,
            ])
        }

        // 2. Camera profile: colors and tone as in the Sony JPEG.
        if a.profile == .camera, let cube = cameraCube {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": srgb,
            ])
        }

        // 3. Clarity: local contrast with a large radius (scaled with the frame size).
        if a.clarity != 0 {
            let radius = longSide * 0.012
            if a.clarity > 0 {
                img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: a.clarity / 100 * 0.6])
            } else {
                let blur = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: e)
                img = img.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blur, kCIInputTimeKey: -a.clarity / 100 * 0.35])
            }
        }

        // 4. Curve in gamma space: contrast, "positive" highlights, "negative" shadows, matte.
        let c = a.contrast / 100
        let hUp = max(a.highlights, 0) / 100, sDown = min(a.shadows, 0) / 100
        let f = a.fade / 100
        if c != 0 || hUp != 0 || sDown != 0 || f != 0 {
            img = img.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: f * 0.14),
                    "inputPoint1": CIVector(x: 0.25, y: 0.25 - c * 0.07 + sDown * 0.10 + f * 0.06),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5 + f * 0.02),
                    "inputPoint3": CIVector(x: 0.75, y: 0.75 + c * 0.07 + hUp * 0.10),
                    "inputPoint4": CIVector(x: 1, y: 1 - f * 0.04),
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        if a.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100])
        }
        if a.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + a.saturation / 100])
        }

        // 5. LUT.
        if let name = a.lut, a.lutAmount > 0, let cube = LUTStore.shared.cube(name) {
            let lutted = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": srgb,
            ])
            // 0–100% blends with the original, 100–200% amplifies the difference, like Amount on Lightroom profiles.
            img = a.lutAmount == 100 ? lutted : (mixKernel.apply(extent: e, arguments: [img, lutted, a.lutAmount / 100]) ?? lutted)
        }

        // 6. Shadow and highlight toning: soft light with a color, masked by luminance.
        if a.shadowSat > 0 { img = tone(img, hue: a.shadowHue, sat: a.shadowSat, shadows: true) }
        if a.highlightSat > 0 { img = tone(img, hue: a.highlightHue, sat: a.highlightSat, shadows: false) }

        // 7. Vignette: smooth falloff from 30% to the edges; at −100 the corners are nearly black, at +100 nearly white.
        if a.vignette != 0 {
            img = vignetteKernel.apply(extent: e, roiCallback: { _, r in r }, arguments: [
                img, CIVector(x: e.midX, y: e.midY), hypot(e.width, e.height) / 2, a.vignette / 100,
            ]) ?? img
        }

        // 8. Grain: each pixel is multiplied by 1 ± noise (mean brightness is unchanged; verified by measurement).
        // Noise is scaled up with the frame size, so it looks the same in the preview and in the export.
        if a.grain > 0 {
            let scale = max(1, longSide / 2400)
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: e)
            img = grainKernel.apply(extent: e, arguments: [img, noise, a.grain / 100 * 0.7]) ?? img
        }
        return img.cropped(to: e)
    }

    private static func tone(_ img: CIImage, hue: Double, sat: Double, shadows: Bool) -> CIImage {
        let e = img.extent
        let rgb = NSColor(hue: hue / 360, saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB) ?? .gray
        let k = sat / 100 * 0.6
        let color = CIImage(color: CIColor(red: 0.5 + (rgb.redComponent - 0.5) * k,
                                           green: 0.5 + (rgb.greenComponent - 0.5) * k,
                                           blue: 0.5 + (rgb.blueComponent - 0.5) * k)).cropped(to: e)
        let toned = color.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
        var mask = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CILinearToSRGBToneCurve")
        if shadows { mask = mask.applyingFilter("CIColorInvert") }
        return toned.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask]).cropped(to: e)
    }

    /// The source as a linear CIImage. maxSide downscales during development (faster); nil means full size.
    /// For RAW we replicate the camera crop: if the camera JPEG has a different aspect ratio (e.g. shot in 4:3),
    /// we center-crop the same way; otherwise extra edges would appear in the frame after the first edit.
    static func source(_ url: URL, maxSide: CGFloat?) -> CIImage? {
        if ImageStore.rawExtensions.contains(url.pathExtension.lowercased()), let raw = CIRAWFilter(imageURL: url) {
            if let maxSide {
                let n = raw.nativeSize
                let k = maxSide / max(n.width, n.height)
                if k < 1 { raw.scaleFactor = Float(k) }
            }
            guard let img = raw.outputImage else { return nil }
            return cropToCamera(img, url)
        }
        guard var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        if let maxSide {
            let k = maxSide / max(img.extent.width, img.extent.height)
            if k < 1 { img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k]) }
        }
        return img
    }

    static func cropToCamera(_ img: CIImage, _ url: URL) -> CIImage {
        guard let prev = ImageStore.shared.preview(url) else { return img }
        let e = img.extent
        let want = CGFloat(prev.width) / CGFloat(prev.height), have = e.width / e.height
        guard abs(want - have) / want > 0.02 else { return img }
        let r = want < have
            ? CGRect(x: e.midX - e.height * want / 2, y: e.minY, width: e.height * want, height: e.height)
            : CGRect(x: e.minX, y: e.midY - e.width / want / 2, width: e.width, height: e.width / want)
        let c = img.cropped(to: r.integral)
        return c.transformed(by: CGAffineTransform(translationX: -c.extent.minX, y: -c.extent.minY))
    }

    /// Text watermark over the frame.
    static func watermark(_ img: CIImage, text: String, sizePercent: Double, opacity: Double, position: Watermark.Position) -> CIImage {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return img }
        let e = img.extent
        let fontSize = max(10, max(e.width, e.height) * sizePercent / 100)
        let attr = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
        ])
        guard let mark = CIFilter(name: "CIAttributedTextImageGenerator", parameters: ["inputText": attr, "inputScaleFactor": 1])?.outputImage
        else { return img }
        let m = fontSize * 0.8
        let x: CGFloat, y: CGFloat
        switch position {
        case .bottomRight: x = e.maxX - mark.extent.width - m; y = e.minY + m
        case .bottomLeft: x = e.minX + m; y = e.minY + m
        case .center: x = e.midX - mark.extent.width / 2; y = e.midY - mark.extent.height / 2
        }
        return mark.transformed(by: CGAffineTransform(translationX: x - mark.extent.minX, y: y - mark.extent.minY))
            .composited(over: img)
            .cropped(to: e)
    }
}

enum Watermark {
    enum Position: String, Codable, CaseIterable { case bottomRight, bottomLeft, center
        var title: String {
            switch self {
            case .bottomRight: tr("Справа внизу")
            case .bottomLeft: tr("Слева внизу")
            case .center: tr("По центру")
            }
        }
    }
}
