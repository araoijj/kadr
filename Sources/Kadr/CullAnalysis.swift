import CoreGraphics
import Foundation
import Vision

/// Лицо на кадре: рамка в долях кадра (y — сверху вниз), качество, открытость глаз, резкость.
struct FaceInfo: Codable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    var quality: Double?        // встроенная оценка macOS 0…1: резкость, поворот, свет лица
    var eyes: Double?           // открытость глаз: высота/ширина контура (открытые ~0,3–0,45)
    var sharpness: Double?      // резкость в области лица
    var px: Double?             // ширина лица в пикселях превью: мелкие лица для глаз и резкости ненадёжны
    var blink: Double?          // моргание обоих глаз по сетке лица MediaPipe 0…1 (закрыты ≥ ~0,42), если модели установлены
    var squint: Double?         // прищур по MediaPipe: улыбка и солнце — не моргание
    var lookDown: Double?       // взгляд вниз по MediaPipe
    var pitch: Double?          // наклон головы от macOS, градусы (> 0 — голова опущена)

    /// Лицо годится для оценки глаз и резкости: крупное и повёрнуто к камере.
    /// Калибровка на 2032 кадрах: у лиц мельче ~180 px открытость глаз и резкость меряются заметно хуже.
    var reliable: Bool { (px ?? 0) >= 180 && (quality ?? 0) >= 0.35 }

    /// Глаза измерены сеткой MediaPipe. Фильтр «качества лица» macOS тут не нужен: при закрытых глазах
    /// macOS сама занижает качество (~0,3), а профиль и затылок сетка отсекает сама.
    var meshUsable: Bool { blink != nil && (px ?? 0) >= 120 }
    /// Глаза открыты: по MediaPipe, если замер есть, иначе по контуру от macOS.
    var eyesOpen: Bool { blink.map { $0 < 0.3 } ?? ((eyes ?? 0.3) >= 0.22) }
    /// Глаза закрыты (порог — от строгости, 0…1). Калибровка на 2032 кадрах: у морганий оба глаза ≥ 0,42
    /// и «взгляд вниз» ≥ 0,5; «взгляд вниз» ~0 при «закрытых» — тёмные очки.
    func eyesShut(_ st: Double = 0.5) -> Bool {
        guard let blink else { return (eyes ?? 0.3) < 0.12 + 0.04 * st }
        return blink >= 0.45 - 0.1 * st && (lookDown ?? 1) >= 0.35
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Всё, что нужно для отбора: считается фоном по встроенному превью и хранится в индексе.
struct CullData: Codable, Sendable, Hashable {
    var faces: [FaceInfo] = []
    var subject: CGRectCodable?     // главный объект, если лиц нет
    var subjectSharpness: Double?   // резкость лучшего лица или главного объекта
    var clipHigh = 0.0              // доля пересвеченных пикселей
    var clipLow = 0.0               // доля «в ноль» в тенях
    var meanLuma: Double?           // средняя яркость 0…1 (для недосвета)
    var brightLuma: Double?         // яркость 95-го процентиля: есть ли в кадре светлые места
    var subjectClip: Double?        // пересвет на лице или главном объекте (белое небо за спиной — не брак)
    var horizon: Double?            // наклон горизонта, градусы
    var aesthetics: Double?         // эстетика кадра по оценке macOS (−1…1)
    var utility = false             // служебный кадр: экран, документ, случайный снимок
    var mesh: Bool?                 // глаза мерили сеткой лица MediaPipe (после установки моделей кадры с лицами пересчитываются)
}

struct CGRectCodable: Codable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

enum CullAnalyzer {
    /// ~25 мс на кадр после первого запуска (модели macOS загружаются ~1 с один раз).
    /// На macOS 14 — без распознавания (резкость по центру, пересвет и провалы).
    static func analyze(_ img: CGImage) async -> CullData {
        if #available(macOS 15.0, *) { return await analyzeVision(img) }
        var d = CullData()
        d.subjectSharpness = ImageStore.shared.sharpness(img)
        (d.clipHigh, d.clipLow, d.meanLuma, d.brightLuma) = clipping(img)
        return d
    }

    @available(macOS 15.0, *)
    private static func analyzeVision(_ img: CGImage) async -> CullData {
        var d = CullData()
        // Vision считает от левого нижнего угла — переводим в «сверху вниз».
        func topDown(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

        let marks = (try? await DetectFaceLandmarksRequest().perform(on: img)) ?? []
        let quality = (try? await DetectFaceCaptureQualityRequest().perform(on: img)) ?? []
        for f in marks {
            let r = topDown(f.boundingBox.cgRect)
            // Качество — от второго запроса, по ближайшему центру рамки.
            let q = quality.min { a, b in
                dist(topDown(a.boundingBox.cgRect), r) < dist(topDown(b.boundingBox.cgRect), r)
            }.flatMap { $0.captureQuality.map { Double($0.score) } }
            var eyes: [Double] = []
            for e in [f.landmarks?.leftEye, f.landmarks?.rightEye].compactMap({ $0 }) {
                let pts = e.points.map(\.cgPoint)
                guard let xmin = pts.map(\.x).min(), let xmax = pts.map(\.x).max(),
                      let ymin = pts.map(\.y).min(), let ymax = pts.map(\.y).max(), xmax > xmin else { continue }
                eyes.append(Double((ymax - ymin) / (xmax - xmin)))
            }
            var face = FaceInfo(x: r.minX, y: r.minY, w: r.width, h: r.height, quality: q,
                                eyes: eyes.isEmpty ? nil : eyes.reduce(0, +) / Double(eyes.count))
            face.px = Double(r.width) * Double(img.width)
            face.pitch = f.pitch.converted(to: .degrees).value
            face.sharpness = ImageStore.shared.sharpness(img, region: r)
            d.faces.append(face)
        }
        d.faces.sort { $0.w * $0.h > $1.w * $1.h }   // крупные лица — первыми
        // Глаза — сеткой лица MediaPipe (~12 мс на лицо): отличает моргание от прищура и взгляда вниз.
        let mesh = FaceMesh.shared
        if !d.faces.isEmpty, mesh.available {
            d.mesh = true
            for i in d.faces.indices.prefix(6) where (d.faces[i].px ?? 0) >= 40 {
                // Сетка не нашла лицо — почти всегда профиль: глаза по нему не судим (контур от macOS тут тоже врёт).
                guard let e = mesh.eyes(img, face: d.faces[i].rect) else { d.faces[i].eyes = nil; continue }
                d.faces[i].blink = e.blink
                d.faces[i].squint = e.squint
                d.faces[i].lookDown = e.lookDown
            }
        }

        if !d.faces.contains(where: \.reliable), let sal = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: img),
           let o = sal.salientObjects.first {
            let xs = [o.topLeft, o.topRight, o.bottomLeft, o.bottomRight].map(\.cgPoint.x)
            let ys = [o.topLeft, o.topRight, o.bottomLeft, o.bottomRight].map(\.cgPoint.y)
            let r = topDown(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            d.subject = CGRectCodable(x: r.minX, y: r.minY, w: r.width, h: r.height)
        }
        // Резкость «главного»: лучшее из крупных лиц к камере, иначе объект внимания, иначе центр кадра.
        // Мелкое лицо при замере растягивается и всегда выглядит «размытым»; затылок — тоже не лицо.
        if let best = d.faces.filter(\.reliable).compactMap(\.sharpness).max() {
            d.subjectSharpness = best
        } else if let s = d.subject {
            d.subjectSharpness = ImageStore.shared.sharpness(img, region: s.rect)
        } else {
            d.subjectSharpness = ImageStore.shared.sharpness(img)
        }

        if let h = try? await DetectHorizonRequest().perform(on: img) {
            d.horizon = h.angle.converted(to: .degrees).value
        }
        if let a = try? await CalculateImageAestheticsScoresRequest().perform(on: img) {
            d.aesthetics = Double(a.overallScore)
            d.utility = a.isUtility
        }
        (d.clipHigh, d.clipLow, d.meanLuma, d.brightLuma) = clipping(img)
        if let f = d.faces.first(where: \.reliable) { d.subjectClip = clipping(img, region: f.rect) }
        else if let s = d.subject { d.subjectClip = clipping(img, region: s.rect) }
        return d
    }

    /// Доля пересвета внутри области кадра.
    static func clipping(_ img: CGImage, region r: CGRect) -> Double? {
        let px = CGRect(x: r.minX * CGFloat(img.width), y: r.minY * CGFloat(img.height),
                        width: r.width * CGFloat(img.width), height: r.height * CGFloat(img.height)).integral
        guard px.width >= 8, px.height >= 8, let crop = img.cropping(to: px) else { return nil }
        return clipping(crop).0
    }

    private static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }

    /// Доля выбитых светов и провалов и средняя яркость — по уменьшенному превью.
    static func clipping(_ img: CGImage) -> (Double, Double, Double, Double) {
        let w = 320, h = max(1, Int(Double(w) * Double(img.height) / Double(img.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (0, 0, 0.5, 0.9) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hi = 0, lo = 0, luma = 0
        var hist = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: px.count, by: 4) {
            let l = (Int(px[i]) * 54 + Int(px[i + 1]) * 183 + Int(px[i + 2]) * 19) >> 8
            luma += l
            hist[min(255, l)] += 1
            let mx = max(px[i], px[i + 1], px[i + 2]), mn = min(px[i], px[i + 1], px[i + 2])
            if mx >= 253 { hi += 1 }
            if mx <= 4 && mn <= 4 { lo += 1 }
        }
        let n = Double(w * h)
        var acc = 0, p95 = 255
        for (v, c) in hist.enumerated() { acc += c; if Double(acc) >= n * 0.95 { p95 = v; break } }
        return (Double(hi) / n, Double(lo) / n, Double(luma) / n / 255, Double(p95) / 255)
    }
}
