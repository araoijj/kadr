import AppKit
import CoreImage
import Foundation
import ImageIO

/// Настройки обработки кадра. Ползунки −100…100 (экспозиция — в EV, оттенки — в градусах), 0 — без изменений.
struct Adjustments: Codable, Equatable, Hashable {
    enum Profile: String, Codable, CaseIterable {
        case camera     // цвета как в JPEG камеры (подбираются по встроенному превью)
        case standard   // проявление macOS как есть
    }

    var profile: Profile = .camera
    var exposure: Double = 0      // −3…+3 EV
    var wbShift: Double = 0       // баланс белого: сдвиг от «как снято», кельвины (+ теплее)
    var tint: Double = 0          // −150…+150 как в Lightroom: зеленее ← → пурпурнее
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var fade: Double = 0          // 0…100, «матовость» — приподнятые чёрные
    var clarity: Double = 0       // локальный контраст
    var vibrance: Double = 0
    var saturation: Double = 0
    var shadowHue: Double = 0     // тонирование теней: 0…360
    var shadowSat: Double = 0     // 0…100
    var highlightHue: Double = 0  // тонирование светов
    var highlightSat: Double = 0
    var vignette: Double = 0      // − затемнить края, + осветлить
    var grain: Double = 0         // 0…100
    var lut: String?              // путь в папке LUT (.cube или HaldCLUT .png)
    var lutAmount: Double = 100   // 0…200: больше 100 — усиление эффекта LUT

    // Кадрирование: прямоугольник в долях кадра (y — сверху вниз) и выравнивание горизонта, градусы.
    var cropX: Double = 0
    var cropY: Double = 0
    var cropW: Double = 1
    var cropH: Double = 1
    var angle: Double = 0
    var cropAspect: String?       // выбранный формат в панели (для подсветки), на картинку не влияет

    var hasCrop: Bool { cropX != 0 || cropY != 0 || cropW != 1 || cropH != 1 }
    var hasGeometry: Bool { hasCrop || angle != 0 }
    var cropRect: CGRect {
        get { CGRect(x: cropX, y: cropY, width: cropW, height: cropH) }
        set { cropX = newValue.minX; cropY = newValue.minY; cropW = newValue.width; cropH = newValue.height }
    }

    static let none = Adjustments()
    /// «До» для шторки: без цвета и тона, но с той же рамкой и горизонтом — половинки совпадают.
    var beforeVersion: Adjustments {
        var b = Adjustments()
        b.profile = profile
        b.cropRect = cropRect
        b.angle = angle
        b.cropAspect = cropAspect
        return b
    }

    /// Без изменений: всё по умолчанию и LUT не выбран (его сила тогда не важна).
    var isIdentity: Bool { var a = self; a.lutAmount = 100; a.cropAspect = nil; return a == .none }
}

extension Adjustments {
    private enum LegacyKeys: String, CodingKey { case temperature }

    /// Сборка рецепта: Adjustments { $0.contrast = 20; $0.vibrance = 30 }
    init(_ build: (inout Adjustments) -> Void) {
        self.init()
        build(&self)
    }

    /// Старые edits.json и styles.json без новых полей тоже читаются.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init()
        func v(_ k: CodingKeys) -> Double? { try? c.decodeIfPresent(Double.self, forKey: k) }
        profile = (try? c.decodeIfPresent(Profile.self, forKey: .profile)) ?? .camera
        // Старые сохранения хранили «температуру» в условных −100…100 (1 ед. ≈ 30 K) — переводим в кельвины.
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
        cropX = v(.cropX) ?? 0; cropY = v(.cropY) ?? 0; cropW = v(.cropW) ?? 1; cropH = v(.cropH) ?? 1
        angle = v(.angle) ?? 0
        cropAspect = try? c.decodeIfPresent(String.self, forKey: .cropAspect)
    }
}

/// Разделы настроек — как в окне «Новый пресет» Lightroom: в стиль можно сохранить только часть.
enum StyleGroup: String, Codable, CaseIterable, Identifiable {
    case profile, light, color, toning, effects, lut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: "Профиль"
        case .light: "Свет"
        case .color: "Цвет"
        case .toning: "Тонирование"
        case .effects: "Эффекты"
        case .lut: "LUT"
        }
    }
}

extension Adjustments {
    /// Переносит из стиля только выбранные разделы, остальное в кадре не трогает.
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

    /// Совпадает ли кадр со стилем в его разделах.
    func matches(_ s: Adjustments, groups: Set<StyleGroup>) -> Bool {
        var a = self
        a.merge(s, groups: groups)
        return a == self
    }

    /// Разделы, в которых что-то изменено.
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

    /// Нужен ли для стиля LUT, которого ещё нет (коллекцию не скачали).
    var missingLUT: Bool { adj.lut.map { !LUTStore.shared.exists($0) } ?? false }
}

// MARK: - Хранилища

enum AppFolders {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kadr", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var luts: URL {
        let u = support.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Обработка кадров съёмки: <папка>/.kadr/edits.json, ключ — имя файла.
enum EditStore {
    static func file(in folder: URL) -> URL { folder.appendingPathComponent(".kadr/edits.json") }

    static func load(_ folder: URL) -> [String: Adjustments] {
        guard let d = try? Data(contentsOf: file(in: folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: Adjustments].self, from: d)) ?? [:]
    }

    static func save(_ edits: [String: Adjustments], in folder: URL) {
        let f = file(in: folder)
        // Не заводим .kadr в папках, где ничего не обрабатывали.
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

/// LUT: .cube (3D) или HaldCLUT .png любого уровня. Разбираем один раз и держим в памяти.
/// Лежат в папке LUT приложения, в том числе в подпапках-коллекциях.
final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()
    private let lock = NSLock()
    private var cache: [String: (size: Int, data: Data)] = [:]

    static func isLUT(_ name: String) -> Bool {
        let e = (name as NSString).pathExtension.lowercased()
        return e == "cube" || e == "png"
    }

    /// Относительные пути всех LUT, например «t3mujinpack/… Portra 400.png».
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

    /// Человеческое имя: без папки, расширения и префикса коллекции.
    static func displayName(_ path: String) -> String {
        var n = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for prefix in ["t3mujinpack - "] where n.hasPrefix(prefix) { n = String(n.dropFirst(prefix.count)) }
        for cat in ["Color Negative - ", "Color Slide - ", "Black and White - "] where n.hasPrefix(cat) { n = String(n.dropFirst(cat.count)) }
        return n
    }

    /// Группа для списка: папка коллекции + категория плёнки.
    static func group(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let n = (path as NSString).lastPathComponent
        let cat = n.contains("Color Negative") ? "негатив" : n.contains("Color Slide") ? "слайд" : n.contains("Black and White") ? "ч/б" : nil
        let base = folder.isEmpty ? "Мои LUT" : folder
        return cat.map { "\(base) · \($0)" } ?? base
    }

    /// Копирует файлы в папку LUT приложения. Возвращает имена принятых.
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
            if line.first?.isLetter == true { continue }   // TITLE, LUT_1D_SIZE и прочее
            let rgb = parts.prefix(3).compactMap { Float($0) }
            guard rgb.count == 3 else { continue }
            for i in 0..<3 { values.append((rgb[i] - lo[i]) / max(hi[i] - lo[i], 0.0001)) }
            values.append(1)
        }
        guard size >= 2, values.count == size * size * size * 4 else { return nil }
        return (size, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// HaldCLUT уровня L: картинка L³×L³, куб L²; при кубе больше 64 — пересэмплируем до 64.
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
        // В HaldCLUT красный меняется быстрее всего — как в кубе Core Image.
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

// MARK: - Конвейер обработки

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

    /// Выравнивание горизонта (с увеличением, чтобы не было пустых углов) и кадрирование.
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

    /// Применяет настройки к линейному изображению (выход CIRAWFilter или превью).
    /// cameraCube — подобранный профиль «как в камере» (только для проявленного RAW).
    /// asShotK — баланс белого «как снято» (из RAW); от него считается сдвиг в кельвинах.
    static func apply(_ a: Adjustments, to input: CIImage, cameraCube: (size: Int, data: Data)? = nil, asShotK: Double = 5500) -> CIImage {
        var img = a.hasGeometry ? geometry(input, a) : input
        let e = img.extent
        let longSide = max(e.width, e.height)

        // 1. Линейная часть — как «Основные» в Lightroom: до профиля.
        if a.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.wbShift != 0 || a.tint != 0 {
            // Как в Lightroom: «свет был K» → картинка пересчитывается от «как снято». Больше K — теплее.
            // Знаки проверены замером R/G/B: «+» оттенок — пурпурнее.
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

        // 2. Профиль камеры: цвета и тон как в JPEG Sony.
        if a.profile == .camera, let cube = cameraCube {
            img = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": srgb,
            ])
        }

        // 3. Чёткость — локальный контраст крупным радиусом (масштабируется с размером кадра).
        if a.clarity != 0 {
            let radius = longSide * 0.012
            if a.clarity > 0 {
                img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: a.clarity / 100 * 0.6])
            } else {
                let blur = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: e)
                img = img.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blur, kCIInputTimeKey: -a.clarity / 100 * 0.35])
            }
        }

        // 4. Кривая в гамма-пространстве: контраст, «плюсовые» света, «минусовые» тени, матовость.
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
            // 0–100% — смешивание с исходным, 100–200% — усиление разницы, как Amount у профилей Lightroom.
            img = a.lutAmount == 100 ? lutted : (mixKernel.apply(extent: e, arguments: [img, lutted, a.lutAmount / 100]) ?? lutted)
        }

        // 6. Тонирование теней и светов: мягкий свет цветом, маской по яркости.
        if a.shadowSat > 0 { img = tone(img, hue: a.shadowHue, sat: a.shadowSat, shadows: true) }
        if a.highlightSat > 0 { img = tone(img, hue: a.highlightHue, sat: a.highlightSat, shadows: false) }

        // 7. Виньетка: плавно от 30% до краёв, на −100 углы почти чёрные, на +100 — почти белые.
        if a.vignette != 0 {
            img = vignetteKernel.apply(extent: e, roiCallback: { _, r in r }, arguments: [
                img, CIVector(x: e.midX, y: e.midY), hypot(e.width, e.height) / 2, a.vignette / 100,
            ]) ?? img
        }

        // 8. Зерно: каждый пиксель умножается на 1 ± шум (средняя яркость не меняется — проверено замером).
        // Шум укрупнён по размеру кадра — одинаково на превью и в экспорте.
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

    /// Исходник как линейный CIImage. maxSide — уменьшить при проявлении (быстрее), nil — полный размер.
    /// У RAW повторяем кадрирование камеры: если JPEG камеры другой пропорции (например, съёмка в 4:3),
    /// обрезаем по центру так же — иначе после первой правки в кадре появлялись бы лишние края.
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

    /// Текстовый водяной знак поверх кадра.
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
            case .bottomRight: "Справа внизу"
            case .bottomLeft: "Слева внизу"
            case .center: "По центру"
            }
        }
    }
}
