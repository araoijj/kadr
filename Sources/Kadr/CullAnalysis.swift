import CoreGraphics
import Foundation
import Vision

/// A face in the frame: box in frame fractions (y from top to bottom), quality, eye openness, sharpness.
struct FaceInfo: Codable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    var quality: Double?        // built-in macOS score 0…1: sharpness, pose, face lighting
    var eyes: Double?           // eye openness: contour height/width (open ~0.3–0.45)
    var sharpness: Double?      // sharpness within the face area
    var px: Double?             // face width in preview pixels: small faces are unreliable for eyes and sharpness
    var blink: Double?          // blink of both eyes from the MediaPipe face mesh 0…1 (closed ≥ ~0.42), if the models are installed
    var squint: Double?         // squint from MediaPipe: smiles and sun, not a blink
    var smile: Double?          // smile per MediaPipe (mouthSmile), 0…1
    var identity: Data?         // who it is: SFace identity vector (float32 ×128) — to group faces into people
    var lookDown: Double?       // downward gaze from MediaPipe
    var pitch: Double?          // head pitch from macOS, degrees (> 0 means the head is lowered)

    /// The face is usable for eye and sharpness checks: large and turned toward the camera.
    /// Calibrated on 2032 frames: for faces smaller than ~180 px, eye openness and sharpness are measured noticeably worse.
    var reliable: Bool { (px ?? 0) >= 180 && (quality ?? 0) >= 0.35 }

    /// Eyes were measured by the MediaPipe mesh. The macOS "face quality" filter isn't needed here: with closed eyes
    /// macOS lowers the quality itself (~0.3), and the mesh rejects profiles and the backs of heads on its own.
    var meshUsable: Bool { blink != nil && (px ?? 0) >= 120 }
    /// Eyes are open: per MediaPipe if there is a measurement, otherwise per the macOS contour.
    var eyesOpen: Bool { blink.map { $0 < 0.3 } ?? ((eyes ?? 0.3) >= 0.22) }
    /// Eyes are closed (threshold depends on strictness, 0…1). Calibrated on 2032 frames: on blinks both eyes are ≥ 0.42
    /// and "look down" is ≥ 0.5; "look down" ~0 with "closed" eyes means dark glasses.
    func eyesShut(_ st: Double = 0.5) -> Bool {
        guard let blink else { return (eyes ?? 0.3) < 0.12 + 0.04 * st }
        return blink >= 0.45 - 0.1 * st && (lookDown ?? 1) >= 0.35
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Everything Culling needs: computed in the background from the embedded preview and stored in the index.
struct CullData: Codable, Sendable, Hashable {
    var faces: [FaceInfo] = []
    var subject: CGRectCodable?     // main subject, if there are no faces
    var subjectSharpness: Double?   // sharpness of the best face or the main subject
    var clipHigh = 0.0              // fraction of blown-out pixels
    var clipLow = 0.0               // fraction of crushed shadows
    var meanLuma: Double?           // mean luminance 0…1 (for underexposure)
    var brightLuma: Double?         // 95th-percentile luminance: whether the frame has any bright areas
    var subjectClip: Double?        // overexposure on the face or main subject (white sky behind is not a defect)
    var horizon: Double?            // horizon tilt, degrees
    var aesthetics: Double?         // frame aesthetics as scored by macOS (−1…1)
    var utility = false             // utility frame: screen, document, accidental shot
    var tags: [String]?             // what is in the photo (Vision classifier, high-precision labels)
    var print: Data?                // whole-photo feature print (Vision, float32) — similarity for bursts
    var people: [CGRectCodable]?    // full-body boxes of people (for auto crop: never cut a figure)
    var modules: [String]?          // AI modules computed for this photo (AIModule raw values)
    var mesh: Bool?                 // eyes were measured by the MediaPipe face mesh (frames with faces are reanalyzed after the models are installed)
    var vision: String?             // set once Vision really ran ("swift"); nil — older versions, which on macOS 14 ran none
}

extension CullData {
    /// Modules already computed. Index entries from before modules existed: everything of that time,
    /// plus tags / similarity / people if their data is there.
    var computed: Set<AIModule> {
        var s: Set<AIModule>
        if let modules { s = Set(modules.compactMap(AIModule.init(rawValue:))) } else {
            s = [.faces, .subject, .exposure, .horizon, .aesthetics]
            if tags != nil { s.insert(.tags) }
            if print != nil { s.insert(.similarity) }
            if people != nil { s.insert(.people) }
        }
        // Older versions on macOS 14 ran no Vision at all yet marked every module done; that index can come along
        // after an upgrade. Such an entry has no
        // Vision output of any kind (a real run leaves at least an empty people list or a score), whatever modules
        // were on. Only the clipping was really measured. Also applied on macOS 15+, where such an entry is opened
        // too; a genuine old entry with nothing found and aesthetics / tags / similarity / people off gets recomputed once.
        let noVision = faces.isEmpty && subject == nil && horizon == nil && aesthetics == nil
            && tags == nil && print == nil && people == nil
        if vision == nil, noVision, !s.subtracting([.exposure]).isEmpty { s.formIntersection([.exposure]) }
        return s
    }
}

/// Parts of the AI analysis; each can be turned off in Settings → AI so it isn't computed.
enum AIModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case faces, subject, exposure, horizon, aesthetics, tags, similarity, people, identity
    var id: String { rawValue }

    /// Help for the score badges.
    static var scoreHelp: String { tr("Техника и эстетика кадра, 0–100. Подсказка, а не приговор.") }

    var title: String {
        switch self {
        case .faces: tr("Лица и глаза")
        case .subject: tr("Главный объект и резкость")
        case .exposure: tr("Пересвет и недосвет")
        case .horizon: tr("Горизонт")
        case .aesthetics: tr("Оценка кадра и служебные снимки")
        case .tags: tr("Что на снимках (теги)")
        case .similarity: tr("Похожие кадры и повторы")
        case .people: tr("Фигуры людей")
        case .identity: tr("Кто на снимке (люди)")
        }
    }

    /// Measured on 40 frames of a real shoot (M-series, one thread), ms per photo.
    var cost: Int {
        switch self {
        case .faces: 31
        case .subject: 15
        case .exposure, .aesthetics: 5
        case .horizon: 6
        case .tags: 7
        case .similarity, .people: 4
        case .identity: 8
        }
    }

    var detail: String {
        switch self {
        case .faces: tr("Лица в 100%, моргание, закрытые глаза, улыбка (MediaPipe), резкость по лицу")
        case .subject: tr("Смаз: резкость лица или главного объекта относительно сцены")
        case .exposure: tr("Выбитые света на лице и в кадре, тёмные кадры")
        case .horizon: tr("Завал горизонта и кнопка «Выровнять»")
        case .aesthetics: tr("Оценка 0–100, «Лучшие кадры», экраны и документы")
        case .tags: tr("Фильтр «Что на снимках»: люди, природа, собака…")
        case .similarity: tr("Серии по смыслу и «Повтор лучшего»")
        case .people: tr("Автокадрирование не режет фигуры")
        case .identity: tr("Фильтр по людям: лица группируются по человеку (модель SFace, 18 МБ)")
        }
    }
}

struct CGRectCodable: Codable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Euclidean distance between two Vision feature prints stored as raw float32 data.
func printDistance(_ a: Data, _ b: Data) -> Double? {
    guard a.count == b.count, a.count % 4 == 0 else { return nil }
    return a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
        let x = pa.bindMemory(to: Float.self), y = pb.bindMemory(to: Float.self)
        var s: Float = 0
        for i in 0..<x.count { let d = x[i] - y[i]; s += d * d }
        return Double(s.squareRoot())
    } }
}

enum CullAnalyzer {
    /// ~25 ms per frame after the first run (macOS models load once, ~1 s).
    static func analyze(_ img: CGImage) async -> CullData {
        await analyze(img, modules: Set(AIModule.allCases), into: nil)
    }

    /// Runs only the requested modules and keeps everything else already in `base` —
    /// so turning a module on later computes just that module.
    static func analyze(_ img: CGImage, modules: Set<AIModule>, into base: CullData?) async -> CullData {
        var d = base ?? CullData()
        if base == nil { d.modules = [] }   // a fresh record has nothing computed yet (not the legacy "everything")
        // Taken before the run: setting `vision` turns off the legacy-entry check, which would bring back its false list.
        let had = d.computed
        var m = modules
        if m.contains(.identity) { m.insert(.faces) }   // recognition aligns by the face mesh points
        // New faces drop the identity vectors: recompute them along, or the photo stays "computed" without people.
        if m.contains(.faces), had.contains(.identity) { m.insert(.identity) }
        // Subject sharpness and clipping on the face/subject depend on the faces: recompute them along.
        if m.contains(.faces) || m.contains(.subject) { m.formUnion(had.intersection([.subject, .exposure])) }
        await analyzeVision(img, m, &d)
        d.vision = "swift"
        d.modules = had.union(m).map(\.rawValue).sorted()
        return d
    }

    private static func analyzeVision(_ img: CGImage, _ m: Set<AIModule>, _ d: inout CullData) async {
        if m.contains(.faces) {
            d.mesh = nil
            d.faces = await faces(img).map { f in
                var face = FaceInfo(x: f.rect.minX, y: f.rect.minY, w: f.rect.width, h: f.rect.height, quality: f.quality, eyes: f.eyes)
                face.px = Double(f.rect.width) * Double(img.width)
                face.pitch = f.pitch
                face.sharpness = ImageStore.shared.sharpness(img, region: f.rect)
                return face
            }
            d.faces.sort { $0.w * $0.h > $1.w * $1.h }   // largest faces first
            // Eyes via the MediaPipe face mesh (~12 ms per face): tells a blink apart from a squint or a downward gaze.
            let mesh = FaceMesh.shared
            if !d.faces.isEmpty, mesh.available {
                d.mesh = true
                for i in d.faces.indices.prefix(6) where (d.faces[i].px ?? 0) >= 40 {
                    // The mesh didn't find a face: almost always a profile, so we don't judge the eyes (the macOS contour is wrong here too).
                    guard let e = mesh.eyes(img, face: d.faces[i].rect) else { d.faces[i].eyes = nil; continue }
                    d.faces[i].blink = e.blink
                    d.faces[i].squint = e.squint
                    d.faces[i].lookDown = e.lookDown
                    d.faces[i].smile = e.smile
                    if m.contains(.identity), (d.faces[i].px ?? 0) >= 60 {
                        d.faces[i].identity = FaceID.shared.embedding(img, align: e.align)
                    }
                }
            }
        }

        if m.contains(.subject) {
            d.subject = nil
            if !d.faces.contains(where: \.reliable), let r = await salientObject(img) {
                d.subject = CGRectCodable(x: r.minX, y: r.minY, w: r.width, h: r.height)
            }
            // Sharpness of the "main" subject: the best of the large camera-facing faces, otherwise the saliency object, otherwise the frame center.
            // A small face gets stretched when measured and always looks "blurry"; the back of a head isn't a face either.
            if let best = d.faces.filter(\.reliable).compactMap(\.sharpness).max() {
                d.subjectSharpness = best
            } else if let s = d.subject {
                d.subjectSharpness = ImageStore.shared.sharpness(img, region: s.rect)
            } else {
                d.subjectSharpness = ImageStore.shared.sharpness(img)
            }
        }

        if m.contains(.tags), let t = await tags(img) { d.tags = t }
        if m.contains(.similarity), let p = await featurePrint(img) { d.print = p }
        if m.contains(.people) {
            d.people = await people(img).map { CGRectCodable(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) }
        }
        if m.contains(.horizon) { d.horizon = await horizon(img) }
        if m.contains(.aesthetics), let a = try? await CalculateImageAestheticsScoresRequest().perform(on: img) {
            d.aesthetics = Double(a.overallScore)
            d.utility = a.isUtility
        }
        if m.contains(.exposure) {
            (d.clipHigh, d.clipLow, d.meanLuma, d.brightLuma) = clipping(img)
            if let f = d.faces.first(where: \.reliable) { d.subjectClip = clipping(img, region: f.rect) }
            else if let s = d.subject { d.subjectClip = clipping(img, region: s.rect) }
            else { d.subjectClip = nil }
        }
    }

    // MARK: Vision requests. Boxes are top-down frame fractions.

    /// Vision measures from the bottom-left corner; convert to top-to-bottom.
    private static func topDown(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    private struct RawFace { var rect: CGRect, quality: Double?, eyes: Double?, pitch: Double? }

    /// Eye openness from the landmark contours: height / width, averaged over both eyes.
    private static func eyeOpenness(_ eyes: [[CGPoint]]) -> Double? {
        var r: [Double] = []
        for pts in eyes {
            guard let xmin = pts.map(\.x).min(), let xmax = pts.map(\.x).max(),
                  let ymin = pts.map(\.y).min(), let ymax = pts.map(\.y).max(), xmax > xmin else { continue }
            r.append(Double((ymax - ymin) / (xmax - xmin)))
        }
        return r.isEmpty ? nil : r.reduce(0, +) / Double(r.count)
    }

    private static func faces(_ img: CGImage) async -> [RawFace] {
        let marks = (try? await DetectFaceLandmarksRequest().perform(on: img)) ?? []
        let quality = (try? await DetectFaceCaptureQualityRequest().perform(on: img)) ?? []
        return marks.map { f in
            let r = topDown(f.boundingBox.cgRect)
            // Quality comes from the second request, matched by the nearest box center.
            let q = quality.min { a, b in
                dist(topDown(a.boundingBox.cgRect), r) < dist(topDown(b.boundingBox.cgRect), r)
            }.flatMap { $0.captureQuality.map { Double($0.score) } }
            let eyes = [f.landmarks?.leftEye, f.landmarks?.rightEye].compactMap { $0?.points.map(\.cgPoint) }
            return RawFace(rect: r, quality: q, eyes: eyeOpenness(eyes), pitch: f.pitch.converted(to: .degrees).value)
        }
    }

    private static func salientObject(_ img: CGImage) async -> CGRect? {
        guard let sal = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: img),
              let o = sal.salientObjects.first else { return nil }
        let xs = [o.topLeft, o.topRight, o.bottomLeft, o.bottomRight].map(\.cgPoint.x)
        let ys = [o.topLeft, o.topRight, o.bottomLeft, o.bottomRight].map(\.cgPoint.y)
        return topDown(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
    }

    /// Only labels the classifier is confident in (90% precision).
    private static func tags(_ img: CGImage) async -> [String]? {
        guard let cls = try? await ClassifyImageRequest().perform(on: img) else { return nil }
        return Array(cls.filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }.prefix(10).map(\.identifier))
    }

    private static func featurePrint(_ img: CGImage) async -> Data? {
        return try? await GenerateImageFeaturePrintRequest().perform(on: img).data
    }

    /// Full-body boxes of people found with confidence.
    private static func people(_ img: CGImage) async -> [CGRect] {
        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        return ((try? await humans.perform(on: img)) ?? []).filter { $0.confidence >= 0.5 }.map { topDown($0.boundingBox.cgRect) }
    }

    /// Horizon tilt, degrees.
    private static func horizon(_ img: CGImage) async -> Double? {
        return (try? await DetectHorizonRequest().perform(on: img)).map { $0.angle.converted(to: .degrees).value }
    }

    /// Fraction of overexposed pixels within a frame region.
    static func clipping(_ img: CGImage, region r: CGRect) -> Double? {
        let px = CGRect(x: r.minX * CGFloat(img.width), y: r.minY * CGFloat(img.height),
                        width: r.width * CGFloat(img.width), height: r.height * CGFloat(img.height)).integral
        guard px.width >= 8, px.height >= 8, let crop = img.cropping(to: px) else { return nil }
        return clipping(crop).0
    }

    private static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }

    /// Fraction of blown highlights and crushed shadows plus mean luminance, from a downscaled preview.
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
