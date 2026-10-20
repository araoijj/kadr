import AppKit
import CoreImage
import Foundation

/// Настройки обработки кадра. Все ползунки −100…100 (экспозиция — в EV), 0 — без изменений.
struct Adjustments: Codable, Equatable, Hashable {
    var exposure: Double = 0      // −3…+3 EV
    var temperature: Double = 0   // холоднее ← → теплее
    var tint: Double = 0          // зеленее ← → пурпурнее
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var fade: Double = 0          // 0…100, «матовость» — приподнятые чёрные
    var vibrance: Double = 0
    var saturation: Double = 0
    var lut: String?              // имя файла .cube из папки LUT
    var lutAmount: Double = 100   // 0…100

    static let none = Adjustments()
    /// Без изменений: все ползунки на нуле и LUT не выбран (его сила тогда не важна).
    var isIdentity: Bool { var a = self; a.lutAmount = 100; return a == .none }
}

struct Style: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var adj: Adjustments
    var builtIn = false

    static let builtIns: [Style] = [
        Style(name: "Тёплый свет", adj: .init(temperature: 25, shadows: 10, vibrance: 15), builtIn: true),
        Style(name: "Холодный", adj: .init(temperature: -25, saturation: -5), builtIn: true),
        Style(name: "Мягкий портрет", adj: .init(temperature: 8, contrast: -15, highlights: -20, shadows: 20, vibrance: -10), builtIn: true),
        Style(name: "Сочный", adj: .init(contrast: 20, vibrance: 35), builtIn: true),
        Style(name: "Яркий день", adj: .init(exposure: 0.3, highlights: -25, shadows: 25, vibrance: 20), builtIn: true),
        Style(name: "Матовая плёнка", adj: .init(temperature: 10, contrast: -10, fade: 30, saturation: -15), builtIn: true),
        Style(name: "Ч/Б контраст", adj: .init(contrast: 35, saturation: -100), builtIn: true),
        Style(name: "Ч/Б мягкий", adj: .init(contrast: -10, fade: 20, saturation: -100), builtIn: true),
    ]
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

/// LUT в формате .cube (3D). Разбираем один раз и держим в памяти.
final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()
    private let lock = NSLock()
    private var cache: [String: (size: Int, data: Data)] = [:]

    func list() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: AppFolders.luts.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".cube") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Копирует файлы в папку LUT приложения. Возвращает имена принятых.
    func importFiles(_ urls: [URL]) -> [String] {
        var ok: [String] = []
        for u in urls where u.pathExtension.lowercased() == "cube" {
            let dest = AppFolders.luts.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil, cube(u.lastPathComponent) != nil {
                ok.append(u.lastPathComponent)
            }
        }
        return ok
    }

    func cube(_ name: String) -> (size: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[name] { return c }
        guard let text = try? String(contentsOf: AppFolders.luts.appendingPathComponent(name), encoding: .utf8) else { return nil }
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
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cache[name] = (size, data)
        return (size, data)
    }
}

// MARK: - Конвейер обработки

enum EditPipeline {
    /// Применяет настройки к линейному изображению (выход CIRAWFilter или превью).
    static func apply(_ a: Adjustments, to input: CIImage) -> CIImage {
        guard !a.isIdentity else { return input }
        var img = input

        if a.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.temperature != 0 || a.tint != 0 {
            // Знаки подобраны замером R/G/B: «+» температура — теплее, «+» оттенок — пурпурнее.
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 30, y: -a.tint),  // минус: «+» = пурпурнее
            ])
        }
        // Восстановление светов и подъём теней — локальный фильтр, работает лучше кривой.
        let hlAmount = a.highlights < 0 ? 1 + a.highlights / 100 : 1
        let shAmount = a.shadows > 0 ? a.shadows / 100 : 0
        if hlAmount != 1 || shAmount != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": hlAmount, "inputShadowAmount": shAmount, "inputRadius": 0,
            ])
        }
        // Кривая в гамма-пространстве: контраст, «плюсовые» света, «минусовые» тени, матовость.
        let c = a.contrast / 100
        let hUp = max(a.highlights, 0) / 100, sDown = min(a.shadows, 0) / 100
        let f = a.fade / 100
        if c != 0 || hUp != 0 || sDown != 0 || f != 0 {
            let p0 = 0.0 + f * 0.14
            let p1 = 0.25 - c * 0.07 + sDown * 0.10 + f * 0.06
            let p3 = 0.75 + c * 0.07 + hUp * 0.10
            img = img.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: p0),
                    "inputPoint1": CIVector(x: 0.25, y: p1),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5 + f * 0.02),
                    "inputPoint3": CIVector(x: 0.75, y: p3),
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
        if let name = a.lut, a.lutAmount > 0, let cube = LUTStore.shared.cube(name),
           let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            let lutted = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size, "inputCubeData": cube.data, "inputColorSpace": srgb,
            ])
            img = a.lutAmount >= 100 ? lutted : img.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: lutted, kCIInputTimeKey: a.lutAmount / 100,
            ])
        }
        return img.cropped(to: input.extent)
    }

    /// Исходник как линейный CIImage. maxSide — уменьшить при проявлении (быстрее), nil — полный размер.
    static func source(_ url: URL, maxSide: CGFloat?) -> CIImage? {
        if ImageStore.rawExtensions.contains(url.pathExtension.lowercased()), let raw = CIRAWFilter(imageURL: url) {
            if let maxSide {
                let n = raw.nativeSize
                let k = maxSide / max(n.width, n.height)
                if k < 1 { raw.scaleFactor = Float(k) }
            }
            return raw.outputImage
        }
        guard var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        if let maxSide {
            let k = maxSide / max(img.extent.width, img.extent.height)
            if k < 1 { img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k]) }
        }
        return img
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
