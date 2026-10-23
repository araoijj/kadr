import CoreGraphics
import CoreML
import Foundation

/// Face recognition: SFace (OpenCV Zoo, Apache 2.0) converted to Core ML. A face aligned by five points
/// (from the MediaPipe mesh) becomes a 128-number identity vector; two faces of the same person have
/// cosine similarity above ~0.36 (OpenCV's threshold), so faces can be grouped into people.
final class FaceID: @unchecked Sendable {
    static let shared = FaceID()
    static let modelName = "sface"

    /// ArcFace alignment template for a 112×112 crop: eyes, nose tip, mouth corners (image-left first).
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    private let lock = NSLock()
    private var model: MLModel?
    private var tried = false
    private var installedCache: Bool?
    private let installedLock = NSLock()
    var folder: URL { FaceMesh.shared.folder }

    /// Its own lock: `lock` is held through loading and inference, and this is asked from view bodies.
    var installed: Bool {
        installedLock.withLock {
            if let installedCache { return installedCache }
            let v = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.modelName + ".mlmodelc").path)
            installedCache = v
            return v
        }
    }

    var available: Bool { lock.withLock { load(); return model != nil } }

    /// Compiles an .mlpackage (or copies an .mlmodelc) into the models folder.
    func install(from src: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ModelInstall.place(src, at: folder.appendingPathComponent(Self.modelName + ".mlmodelc"))
        lock.withLock { tried = false; model = nil }
        installedLock.withLock { installedCache = nil }
    }

    func uninstall() {
        lock.withLock { tried = false; model = nil }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.modelName + ".mlmodelc"))
        installedLock.withLock { installedCache = nil }
    }

    private func load() {
        guard !tried else { return }
        tried = true
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try? MLModel(contentsOf: folder.appendingPathComponent(Self.modelName + ".mlmodelc"), configuration: cfg)
    }

    /// Identity vector (L2-normalized float32) of the face whose five points (pixels of `img`, top-down) are given.
    func embedding(_ img: CGImage, align pts: [CGPoint]) -> Data? {
        guard pts.count == 5 else { return nil }
        return lock.withLock {
            load()
            guard let model else { return nil }
            // Least-squares similarity transform template → image (complex form: z = a·w + b).
            let n = 5.0
            let wm = Self.template.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }
            let zm = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n) }
            var re = 0.0, im = 0.0, den = 0.0
            for (w, z) in zip(Self.template, pts) {
                let wx = w.x - wm.x, wy = w.y - wm.y, zx = z.x - zm.x, zy = z.y - zm.y
                re += wx * zx + wy * zy          // Σ conj(w)·z
                im += wx * zy - wy * zx
                den += wx * wx + wy * wy
            }
            guard den > 0 else { return nil }
            let a = re / den, b = im / den        // scale·rotation
            let tx = zm.x - (a * wm.x - b * wm.y), ty = zm.y - (b * wm.x + a * wm.y)
            // Crop (u, v) → image (X, Y), both top-down; Core Graphics contexts are bottom-up, so flip both.
            let F = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
            let flipCrop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 112)
            let flipImg = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(img.height))
            let G = flipCrop.concatenating(F).concatenating(flipImg)
            let side = 112
            var px = [UInt8](repeating: 0, count: side * side * 4)
            guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.concatenate(G.inverted())
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            // Input: RGB 0…255, planar NCHW (the model normalizes itself).
            guard let x = try? MLMultiArray(shape: [1, 3, 112, 112], dataType: .float32) else { return nil }
            let ptr = x.dataPointer.bindMemory(to: Float32.self, capacity: 3 * side * side)
            let plane = side * side
            for i in 0..<plane {
                ptr[i] = Float32(px[i * 4]); ptr[plane + i] = Float32(px[i * 4 + 1]); ptr[2 * plane + i] = Float32(px[i * 4 + 2])
            }
            guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": x])),
                  let e = out.featureValue(for: "embedding")?.multiArrayValue, e.count >= 128 else { return nil }
            var v = (0..<128).map { Float(e[$0].doubleValue) }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return nil }
            v = v.map { $0 / norm }
            return v.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    /// Cosine similarity of two normalized identity vectors.
    static func similarity(_ a: Data, _ b: Data) -> Double {
        guard a.count == b.count else { return 0 }
        return a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
            let x = pa.bindMemory(to: Float.self), y = pb.bindMemory(to: Float.self)
            var s: Float = 0
            for i in 0..<x.count { s += x[i] * y[i] }
            return Double(s)
        } }
    }
}
