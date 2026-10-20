import CoreGraphics
import CoreML
import Foundation

/// MediaPipe Face Landmarker face mesh (Google, Apache 2.0), converted to Core ML:
/// 478 face landmarks → 52 blendshape scores, including blink and squint for each eye.
/// The models (~7 MB) live in "Data folder"/Models and are installed from Settings; without them Culling
/// judges eyes by the macOS contour, which is cruder: squints and downward gazes get confused with blinks.
final class FaceMesh: @unchecked Sendable {
    static let shared = FaceMesh()

    struct Eyes: Codable, Sendable, Hashable {
        var blink: Double      // blink of the less closed eye 0…1: both closed ≥ ~0.42, open ≤ ~0.3
        var squint: Double     // squint (laughing, sun)
        var smile: Double      // mouthSmile, mean of both sides: ≥ 0.6 — a clear smile, 0.35–0.6 a slight one (checked on 1491 faces)
        var lookDown: Double   // downward gaze; the model also gives ≥ ~0.5 for closed lids, ~0 for dark glasses
        var align: [CGPoint] = []   // five alignment points for face recognition (pixels of the analyzed image)
    }

    /// Model archive in the Kadr repository releases.
    static let downloadURL = URL(string: "https://github.com/araoijj/kadr/releases/download/models-1/kadr-facemesh-1.zip")!

    static let modelNames = ["face_landmarks_detector", "face_blendshapes"]
    /// Indices of the 146 landmarks the blendshape model takes from the 478 (from the MediaPipe sources, face_blendshapes_graph.cc).
    private static let subset = [
        0, 1, 4, 5, 6, 7, 8, 10, 13, 14, 17, 21, 33, 37, 39, 40, 46, 52, 53, 54, 55, 58, 61, 63, 65, 66, 67, 70, 78, 80,
        81, 82, 84, 87, 88, 91, 93, 95, 103, 105, 107, 109, 127, 132, 133, 136, 144, 145, 146, 148, 149, 150, 152, 153, 154, 155, 157, 158, 159, 160,
        161, 162, 163, 168, 172, 173, 176, 178, 181, 185, 191, 195, 197, 234, 246, 249, 251, 263, 267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295,
        296, 297, 300, 308, 310, 311, 312, 314, 317, 318, 321, 323, 324, 332, 334, 336, 338, 356, 361, 362, 365, 373, 374, 375, 377, 378, 379, 380, 381, 382,
        384, 385, 386, 387, 388, 389, 390, 397, 398, 400, 402, 405, 409, 415, 454, 466, 468, 469, 470, 471, 472, 473, 474, 475, 476, 477]

    private let lock = NSLock()
    private var landmarks: MLModel?
    private var blend: MLModel?
    private var tried = false
    let folder: URL

    init(folder: URL? = nil) {
        // KADR_MODELS points to another models folder (for test runs, so the "Data folder" stays untouched).
        let env = ProcessInfo.processInfo.environment["KADR_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.folder = folder ?? env ?? AppFolders.support.appendingPathComponent("Models", isDirectory: true)
    }

    /// Models are installed and load.
    var available: Bool { lock.withLock { load(); return landmarks != nil && blend != nil } }

    /// Models are on disk (without loading). Cached: it's queried for every frame and on every redraw.
    var installed: Bool {
        lock.withLock {
            if let installedCache { return installedCache }
            let v = Self.modelNames.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0 + ".mlmodelc").path) }
            installedCache = v
            return v
        }
    }
    private var installedCache: Bool?

    /// Install models from a folder, a .zip archive or a single .mlpackage: compile to .mlmodelc and put into Models.
    func install(from src: URL) throws {
        let fm = FileManager.default
        var dir = src
        var temp: URL?
        if src.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("kadr-models-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", src.path, t.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            dir = t; temp = t
        } else if src.pathExtension == "mlpackage" {
            dir = src.deletingLastPathComponent()
        }
        defer { if let temp { try? fm.removeItem(at: temp) } }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var found = 0
        let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = en?.nextObject() as? URL {
            let name = u.deletingPathExtension().lastPathComponent
            guard Self.modelNames.contains(name), ["mlpackage", "mlmodelc"].contains(u.pathExtension) else { continue }
            en?.skipDescendants()
            let compiled = u.pathExtension == "mlmodelc" ? u : try MLModel.compileModel(at: u)
            let dst = folder.appendingPathComponent(name + ".mlmodelc")
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: compiled, to: dst)
            if compiled != u { try? fm.removeItem(at: compiled) }
            found += 1
        }
        guard found > 0 else { throw CocoaError(.fileNoSuchFile) }
        lock.withLock { tried = false; landmarks = nil; blend = nil; installedCache = nil }
    }

    /// Models bundled with the app (Contents/Resources/FaceMesh); installed automatically on first launch.
    static var bundled: URL? {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("FaceMesh", isDirectory: true),
              FileManager.default.fileExists(atPath: u.appendingPathComponent(modelNames[0] + ".mlpackage").path) else { return nil }
        return u
    }

    /// Install the bundled models if they aren't there yet (compilation ~0.3 s). The user doesn't need to do anything.
    func installBundledIfNeeded() {
        guard !installed, let b = Self.bundled else { return }
        try? install(from: b)
    }

    func uninstall() {
        lock.withLock { tried = false; landmarks = nil; blend = nil; installedCache = nil }
        for n in Self.modelNames { try? FileManager.default.removeItem(at: folder.appendingPathComponent(n + ".mlmodelc")) }
    }

    private func load() {
        guard !tried else { return }
        tried = true
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        func m(_ n: String) -> MLModel? { try? MLModel(contentsOf: folder.appendingPathComponent(n + ".mlmodelc"), configuration: cfg) }
        landmarks = m(Self.modelNames[0])
        blend = m(Self.modelNames[1])
    }

    /// Blink and squint for a face. `face` is the macOS box in frame fractions (y from top to bottom).
    func eyes(_ img: CGImage, face r: CGRect) -> Eyes? {
        guard let (b, align) = analyze(img, face: r) else { return nil }
        // 9/10 — eyeBlinkLeft/Right, 11/12 — eyeLookDownLeft/Right, 19/20 — eyeSquintLeft/Right, 44/45 — mouthSmileLeft/Right.
        // Blink uses the less closed eye: in a real blink both are closed, whereas when laughing,
        // looking sideways or in half-profile one eye stays open (calibrated on 2032 frames).
        return Eyes(blink: min(b[9], b[10]), squint: max(b[19], b[20]), smile: (b[44] + b[45]) / 2, lookDown: (b[11] + b[12]) / 2, align: align)
    }

    /// 52 MediaPipe blendshape scores (order as in face_blendshapes_graph.cc: 0 _neutral, 9/10 eyeBlink, 11/12 eyeLookDown…).
    /// Two passes, like MediaPipe in tracking mode: a rough crop from the box, then a precise one from the found landmarks
    /// (rotated along the eye line, square ×1.5). ~12 ms per face.
    func blendshapes(_ img: CGImage, face r: CGRect) -> [Double]? { analyze(img, face: r)?.blend }

    /// Blendshapes plus the five points face recognition aligns by (eye centers, nose tip, mouth corners),
    /// in pixels of `img`, image-left first — the ArcFace order.
    func analyze(_ img: CGImage, face r: CGRect) -> (blend: [Double], align: [CGPoint])? {
        lock.withLock {
            load()
            guard let landmarks, let blend else { return nil }
            let W = Double(img.width), H = Double(img.height)
            let side = max(r.width * W, r.height * H) * 1.8
            guard side >= 24,
                  let p1 = mesh(landmarks, img, cx: r.midX * W, cy: r.midY * H, side: side, rot: 0),
                  let p2 = mesh(landmarks, img, roi: p1) else { return nil }
            guard let x = try? MLMultiArray(shape: [1, 146, 2], dataType: .float32) else { return nil }
            let ptr = x.dataPointer.bindMemory(to: Float32.self, capacity: 292)
            for (k, i) in Self.subset.enumerated() {
                ptr[k * 2] = Float32(p2[i].x); ptr[k * 2 + 1] = Float32(p2[i].y)
            }
            guard let out = try? blend.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": x])),
                  let b = out.featureValue(for: "blendshapes")?.multiArrayValue, b.count >= 52 else { return nil }
            // 468 / 473 — iris centers, 1 — nose tip, 61 / 291 — mouth corners.
            return ((0..<52).map { b[$0].doubleValue }, [468, 473, 1, 61, 291].map { p2[$0] })
        }
    }

    /// Second pass: region from the first pass's landmarks: center of the landmark box, rotation from eye corners 33 → 263.
    private func mesh(_ model: MLModel, _ img: CGImage, roi p: [CGPoint]) -> [CGPoint]? {
        let xs = p.map(\.x), ys = p.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let rot = -atan2(-(p[263].y - p[33].y), p[263].x - p[33].x)
        return mesh(model, img, cx: (x0 + x1) / 2, cy: (y0 + y1) / 2, side: max(x1 - x0, y1 - y0) * 1.5, rot: rot)
    }

    /// Square `side` centered at (cx, cy), rotated by `rot` → 256×256 → 478 landmarks in frame pixels (y from top to bottom).
    private func mesh(_ model: MLModel, _ img: CGImage, cx: Double, cy: Double, side: Double, rot: Double) -> [CGPoint]? {
        let n = 256
        // F: crop point (u, v) → frame point (X, Y), both top to bottom.
        let k = side / Double(n), c = cos(rot), s = sin(rot)
        let a = k * c, b = -k * s, d = k * s, e = k * c
        let tx = cx - (a + b) * Double(n) / 2, ty = cy - (d + e) * Double(n) / 2
        let F = CGAffineTransform(a: a, b: d, c: b, d: e, tx: tx, ty: ty)
        // Core Graphics contexts count from bottom to top: flip the crop and the frame.
        let flipCrop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(n))
        let flipImg = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(img.height))
        let G = flipCrop.concatenating(F).concatenating(flipImg)

        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.concatenate(G.inverted())
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))

        guard let x = try? MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: n), 3], dataType: .float32) else { return nil }
        let ptr = x.dataPointer.bindMemory(to: Float32.self, capacity: n * n * 3)
        for i in 0..<(n * n) {
            ptr[i * 3] = Float32(px[i * 4]) / 255
            ptr[i * 3 + 1] = Float32(px[i * 4 + 1]) / 255
            ptr[i * 3 + 2] = Float32(px[i * 4 + 2]) / 255
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": x])),
              let lm = out.featureValue(for: "landmarks")?.multiArrayValue, lm.count >= 1434 else { return nil }
        // Is there a face in the crop at all? The model returns a confidence logit.
        if let pr = out.featureValue(for: "presence")?.multiArrayValue, pr.count > 0, 1 / (1 + exp(-pr[0].doubleValue)) < 0.5 { return nil }
        return (0..<478).map { i in
            let u = lm[i * 3].doubleValue, v = lm[i * 3 + 1].doubleValue
            return CGPoint(x: a * u + b * v + tx, y: d * u + e * v + ty)
        }
    }
}
