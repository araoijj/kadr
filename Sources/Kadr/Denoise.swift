import CoreImage
import CoreML
import CryptoKit
import Foundation

/// AI noise reduction: SCUNet (Kai Zhang et al., Apache 2.0, "color real" weights) converted to Core ML.
/// Runs on the GPU in 512 px tiles with overlap, ~1 minute for a 24 MP photo (like Lightroom's Denoise),
/// so it is a batch job; the result is cached in the data folder and used instantly afterwards.
/// The network sees the photo clamped to 0…1, so only the removed noise is carried over to the RAW base
/// (base + (denoised − clamp(base))) — highlight headroom from the RAW stays.
final class Denoiser: @unchecked Sendable {
    static let shared = Denoiser()
    static let modelName = "scunet"
    private let tile = 512, overlap = 32

    private let lock = NSLock()
    private var model: MLModel?
    private var tried = false
    private var installedCache: Bool?
    var folder: URL { FaceMesh.shared.folder }
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    var installed: Bool {
        lock.withLock {
            if let installedCache { return installedCache }
            let v = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.modelName + ".mlmodelc").path)
            installedCache = v
            return v
        }
    }

    func install(from src: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let compiled = src.pathExtension == "mlmodelc" ? src : try MLModel.compileModel(at: src)
        let dst = folder.appendingPathComponent(Self.modelName + ".mlmodelc")
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: compiled, to: dst)
        if compiled != src { try? fm.removeItem(at: compiled) }
        lock.withLock { tried = false; model = nil; installedCache = nil }
    }

    private func load() -> MLModel? {
        lock.withLock {
            if !tried {
                tried = true
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuAndGPU   // the Neural Engine can't run it (window attention); the GPU is fastest
                model = try? MLModel(contentsOf: folder.appendingPathComponent(Self.modelName + ".mlmodelc"), configuration: cfg)
            }
            return model
        }
    }

    // MARK: - Cache

    private static var cacheDir: URL {
        let u = AppFolders.support.appendingPathComponent("Cache/Denoise", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// One file per photo version (path, size, modification time).
    static func cacheURL(_ url: URL) -> URL {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.standardizedFileURL.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let h = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(h + ".heic")
    }

    func hasResult(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: Self.cacheURL(url).path) }

    /// The denoised photo (0…1, sRGB), if computed.
    func result(_ url: URL) -> CIImage? {
        let f = Self.cacheURL(url)
        if let c = lock.withLock({ images[f.path] }) { return c }
        guard FileManager.default.fileExists(atPath: f.path), let img = CIImage(contentsOf: f) else { return nil }
        lock.withLock { images[f.path] = img }
        return img
    }
    private var images: [String: CIImage] = [:]

    /// For the edit pipeline: the cached result if this photo's settings ask for it.
    func input(for url: URL, _ a: Adjustments) -> CIImage? { a.aiDenoise > 0 ? result(url) : nil }

    // MARK: - Run

    /// Denoises the whole photo and caches it. `progress` gets 0…1. ~1 minute per 24 MP on an M-series GPU.
    func run(_ url: URL, progress: (Double) -> Void) throws {
        guard let model = load() else { throw CocoaError(.fileNoSuchFile) }
        guard let base = EditPipeline.source(url, maxSide: nil) else { throw CocoaError(.fileReadCorruptFile) }
        let e = base.extent.integral
        let W = Int(e.width), H = Int(e.height)
        let clamped = base.applyingFilter("CIColorClamp").transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var src = [UInt8](repeating: 0, count: W * H * 4)
        context.render(clamped, toBitmap: &src, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: srgb)
        var dst = src

        let t = tile, step = tile - 2 * overlap
        let xs = W <= t ? [0] : Array(stride(from: 0, to: W - t, by: step)) + [W - t]
        let ys = H <= t ? [0] : Array(stride(from: 0, to: H - t, by: step)) + [H - t]
        let x = try MLMultiArray(shape: [1, 3, NSNumber(value: t), NSNumber(value: t)], dataType: .float32)
        let ptr = x.dataPointer.bindMemory(to: Float32.self, capacity: 3 * t * t)
        let plane = t * t
        var done = 0
        // Rows of the bitmap are top-down; Core Image rendered it top-down too (row 0 = top).
        for y0 in ys {
            for x0 in xs {
                for j in 0..<t {
                    let sy = min(y0 + j, H - 1)
                    for i in 0..<t {
                        let sx = min(x0 + i, W - 1), s = (sy * W + sx) * 4, d = j * t + i
                        ptr[d] = Float32(src[s]) / 255; ptr[plane + d] = Float32(src[s + 1]) / 255; ptr[2 * plane + d] = Float32(src[s + 2]) / 255
                    }
                }
                let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": x]))
                guard let o = out.featureValue(for: "output")?.multiArrayValue else { throw CocoaError(.fileReadCorruptFile) }
                let op = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count)
                let isHalf = o.dataType == .float16
                func val(_ k: Int) -> Float { isHalf ? Float(op[k]) : o[k].floatValue }
                // Keep the tile's inner part; at the photo's edges keep up to the edge.
                let ix0 = x0 == 0 ? 0 : overlap, iy0 = y0 == 0 ? 0 : overlap
                let ix1 = x0 + t >= W ? min(t, W - x0) : t - overlap, iy1 = y0 + t >= H ? min(t, H - y0) : t - overlap
                for j in iy0..<iy1 {
                    for i in ix0..<ix1 {
                        let d = j * t + i, q = ((y0 + j) * W + (x0 + i)) * 4
                        dst[q] = UInt8(max(0, min(255, val(d) * 255 + 0.5)))
                        dst[q + 1] = UInt8(max(0, min(255, val(plane + d) * 255 + 0.5)))
                        dst[q + 2] = UInt8(max(0, min(255, val(2 * plane + d) * 255 + 0.5)))
                    }
                }
                done += 1
                progress(Double(done) / Double(xs.count * ys.count))
            }
        }
        let data = Data(dst)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: srgb,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CocoaError(.fileWriteUnknown) }
        try context.writeHEIFRepresentation(of: CIImage(cgImage: cg), to: Self.cacheURL(url), format: .RGBA8, colorSpace: srgb,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
    }

    /// Carries the removed noise over to `base`: base + k·(denoised − clamp(base)); `denoised` is scaled to `base`.
    static func apply(_ base: CIImage, denoised: CIImage, amount k: Double) -> CIImage {
        let e = base.extent, de = denoised.extent
        let d = denoised.transformed(by: CGAffineTransform(scaleX: e.width / de.width, y: e.height / de.height))
            .transformed(by: CGAffineTransform(translationX: e.minX - de.minX * e.width / de.width, y: e.minY - de.minY * e.height / de.height))
        return kernel.apply(extent: e, arguments: [base, d, Float(k)]) ?? base
    }

    private static let kernel = CIColorKernel(source:
        "kernel vec4 dn(__sample b, __sample d, float k) { vec3 c = clamp(b.rgb, 0.0, 1.0); return vec4(b.rgb + (d.rgb - c) * k, b.a); }")!
}

extension Library {
    /// "Remove Noise (AI)" for the selection: one photo after another in the background (~1 min each),
    /// then the strength slider in Edit applies the result instantly.
    func denoiseTargets() {
        guard !denoiseRunning else { return }
        guard Denoiser.shared.installed else { flash(tr("Модель шумоподавления не установлена (Настройки → AI)")); return }
        let list = targets.filter { !Denoiser.shared.hasResult($0.url) }.map(\.url)
        let ready = targets.filter { Denoiser.shared.hasResult($0.url) }.map(\.id)
        for id in ready { setDenoiseIfNeeded(id) }
        guard !list.isEmpty else { return }
        denoiseRunning = true; denoiseDone = 0; denoiseTotal = list.count; denoiseFraction = 0
        denoiseTask = Task.detached(priority: .userInitiated) { [weak self] in
            for u in list {
                if Task.isCancelled { break }
                do {
                    try Denoiser.shared.run(u) { f in Task { @MainActor in self?.denoiseFraction = f } }
                    await MainActor.run { self?.setDenoiseIfNeeded(u) }
                } catch {
                    await MainActor.run { self?.flash(tr("Не удалось убрать шум: \(u.lastPathComponent)")) }
                }
                await MainActor.run { self?.denoiseDone += 1 }
            }
            await MainActor.run {
                guard let self else { return }
                self.denoiseRunning = false
                self.flash(tr("Шум убран: \(self.denoiseDone) из \(self.denoiseTotal)"))
            }
        }
    }

    func stopDenoise() { denoiseTask?.cancel() }

    /// Turns the result on (70%) unless the photo already has its own strength.
    private func setDenoiseIfNeeded(_ id: URL) {
        guard let i = photos.firstIndex(where: { $0.id == id }), photos[i].adj.aiDenoise == 0 else { return }
        var a = photos[i].adj
        a.aiDenoise = 70
        setAdjustmentsRaw(i, a)
    }
}
