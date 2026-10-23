import CoreImage
import CoreML
import CryptoKit
import Foundation
import ImageIO

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
    /// Serializes loading: one load in flight, others wait here, while `lock` and `installedLock` stay free for the UI.
    private let loadLock = NSLock()
    private let installedLock = NSLock()
    private var model: MLModel?
    private var tried = false
    private var generation = 0   // bumped by install: a load that started before it is thrown away
    private var installedCache: Bool?
    var folder: URL { FaceMesh.shared.folder }
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// Asked from view bodies: never waits for a model load.
    var installed: Bool {
        installedLock.withLock {
            if let installedCache { return installedCache }
            let v = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.modelName + ".mlmodelc").path)
            installedCache = v
            return v
        }
    }

    func install(from src: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ModelInstall.place(src, at: folder.appendingPathComponent(Self.modelName + ".mlmodelc"))
        lock.withLock { tried = false; model = nil; generation += 1 }
        installedLock.withLock { installedCache = nil }
    }

    private func load() -> MLModel? {
        loadLock.withLock {
            let (done, gen) = lock.withLock { (tried, generation) }
            if !done {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuAndGPU   // the Neural Engine can't run it (window attention); the GPU is fastest
                let m = try? MLModel(contentsOf: folder.appendingPathComponent(Self.modelName + ".mlmodelc"), configuration: cfg)
                lock.withLock { if generation == gen { model = m; tried = true } }
            }
            return lock.withLock { model }
        }
    }

    // MARK: - Cache

    private static var cacheDir: URL {
        let u = AppFolders.support.appendingPathComponent("Cache/Denoise", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        _ = sweptPartials
        return u
    }

    /// Writes cut short by a quit or a crash (`.part.heic`, 10–20 MB each) are never read: removed once per launch.
    /// Finished results are left alone: they are the base of a photo's edits and take minutes to compute again.
    private static let sweptPartials: Void = {
        let dir = AppFolders.support.appendingPathComponent("Cache/Denoise", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default, old = Date().addingTimeInterval(-3600)   // not one being written now
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.lastPathComponent.hasSuffix(".part.heic") {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if m < old { try? fm.removeItem(at: f) }
            }
        }
    }()

    /// One file per photo version (path, size, modification time) and per RAW development that moves or retones
    /// the base: a result computed without lens correction would leave double edges once it is turned on.
    /// 10-bit HEIC (8-bit from older versions, still valid).
    static func cacheURL(_ url: URL, _ raw: RawDevelop) -> URL {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let r = raw.base(for: url)
        var key = "\(url.standardizedFileURL.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if !r.isDefault { key += "|\(r)" }   // the default keeps the old key, so earlier results stay valid
        let h = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(h + ".heic")
    }

    /// Remembered for a few seconds: views ask from body on every pan and zoom step, and each check reads the
    /// file's attributes, hashes and stats the cache.
    func hasResult(_ url: URL, _ raw: RawDevelop) -> Bool {
        let k = Self.knownKey(url, raw), now = Date()
        if let c = lock.withLock({ known[k] }), now.timeIntervalSince(c.at) < 5 { return c.has }
        let has = FileManager.default.fileExists(atPath: Self.cacheURL(url, raw).path)
        lock.withLock { known[k] = (has, now) }
        return has
    }
    private var known: [String: (has: Bool, at: Date)] = [:]
    private static func knownKey(_ url: URL, _ raw: RawDevelop) -> String { "\(url.path)|\(raw.base(for: url))" }

    /// The denoised photo (0…1, sRGB), if computed for this RAW development.
    func result(_ url: URL, _ raw: RawDevelop) -> CIImage? {
        let f = Self.cacheURL(url, raw)
        if let c = images.object(forKey: f.path as NSString) { return c }
        guard FileManager.default.fileExists(atPath: f.path), let img = CIImage(contentsOf: f) else { return nil }
        images.setObject(img, forKey: f.path as NSString)
        return img
    }
    /// A few recent photos: a full-size result held by Core Image is tens of MB, and a shoot can have hundreds.
    private let images: NSCache<NSString, CIImage> = { let c = NSCache<NSString, CIImage>(); c.countLimit = 8; return c }()

    /// The result downscaled to 1600 px, for thumbnails: each would otherwise decode the whole file (24–60 MP).
    func smallResult(_ url: URL, _ raw: RawDevelop) -> CIImage? {
        let f = Self.cacheURL(url, raw)
        if let c = smalls.object(forKey: f.path as NSString) { return CIImage(cgImage: c) }
        guard let src = CGImageSourceCreateWithURL(f as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
        else { return nil }
        smalls.setObject(cg, forKey: f.path as NSString, cost: cg.bytesPerRow * cg.height)
        return CIImage(cgImage: cg)
    }
    private let smalls: NSCache<NSString, CGImage> = { let c = NSCache<NSString, CGImage>(); c.totalCostLimit = 200 << 20; return c }()

    /// For the edit pipeline: the cached result if this photo's settings ask for it; `small` for thumbnails.
    func input(for url: URL, _ a: Adjustments, small: Bool = false) -> CIImage? {
        guard a.aiDenoise > 0 else { return nil }
        return small ? smallResult(url, a.raw) : result(url, a.raw)
    }

    // MARK: - Run

    /// Denoises the whole photo, developed with this photo's RAW settings, and caches it. `progress` gets 0…1.
    /// ~1 minute per 24 MP on an M-series GPU; throws CancellationError between tiles once the task is cancelled.
    func run(_ url: URL, raw: RawDevelop, progress: (Double) -> Void) throws {
        guard let model = load() else { throw CocoaError(.fileNoSuchFile) }
        guard let base = EditPipeline.source(url, maxSide: nil, raw: raw) else { throw CocoaError(.fileReadCorruptFile) }
        let e = base.extent.integral
        let W = Int(e.width), H = Int(e.height)
        let clamped = base.applyingFilter("CIColorClamp").transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // 16 bits in and out: 8 bits band in shadows and skies once exposure is raised in Edit.
        // Rendered one band of tile rows at a time: a whole RGBA16 frame next to the output would be ~850 MB at 60 MP.
        var src = [UInt16](repeating: 0, count: W * min(tile, H) * 4)
        // The output: RGB, big-endian 16-bit samples.
        var dst = [UInt16](repeating: 0, count: W * H * 3)

        let t = tile, step = tile - 2 * overlap
        let xs = W <= t ? [0] : Array(stride(from: 0, to: W - t, by: step)) + [W - t]
        let ys = H <= t ? [0] : Array(stride(from: 0, to: H - t, by: step)) + [H - t]
        let x = try MLMultiArray(shape: [1, 3, NSNumber(value: t), NSNumber(value: t)], dataType: .float32)
        let ptr = x.dataPointer.bindMemory(to: Float32.self, capacity: x.count)
        let xst = x.strides.map(\.intValue)
        var done = 0
        // Rows of the bitmap are top-down; Core Image rendered it top-down too (row 0 = top).
        for y0 in ys {
            // Rows y0 ..< y0 + th, top-down; CI's y axis points up.
            let th = min(t, H - y0)
            context.render(clamped, toBitmap: &src, rowBytes: W * 8, bounds: CGRect(x: 0, y: H - y0 - th, width: W, height: th),
                           format: .RGBA16, colorSpace: srgb)
            for x0 in xs {
                // Stop promptly: a tile takes ~0.5 s, the whole photo a minute.
                if Task.isCancelled { throw CancellationError() }
                for j in 0..<t {
                    let sy = min(y0 + j, H - 1)
                    for i in 0..<t {
                        let sx = min(x0 + i, W - 1), s = ((sy - y0) * W + sx) * 4, d = j * xst[2] + i * xst[3]
                        ptr[d] = Float32(src[s]) / 65535; ptr[xst[1] + d] = Float32(src[s + 1]) / 65535; ptr[2 * xst[1] + d] = Float32(src[s + 2]) / 65535
                    }
                }
                let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": x]))
                guard let o = out.featureValue(for: "output")?.multiArrayValue, o.shape.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
                // Typed reads at the array's own strides (Core ML may pad rows); no NSNumber per pixel.
                let ost = o.strides.map(\.intValue)
                let val: (Int) -> Float
                switch o.dataType {
                case .float16: let op = o.dataPointer.bindMemory(to: Float16.self, capacity: o.count); val = { Float(op[$0]) }
                case .float32: let op = o.dataPointer.bindMemory(to: Float32.self, capacity: o.count); val = { op[$0] }
                case .double: let op = o.dataPointer.bindMemory(to: Double.self, capacity: o.count); val = { Float(op[$0]) }
                default: throw CocoaError(.fileReadCorruptFile)
                }
                func q16(_ v: Float) -> UInt16 { UInt16(max(0, min(65535, v * 65535 + 0.5))).bigEndian }
                // Keep the tile's inner part; at the photo's edges keep up to the edge.
                let ix0 = x0 == 0 ? 0 : overlap, iy0 = y0 == 0 ? 0 : overlap
                let ix1 = x0 + t >= W ? min(t, W - x0) : t - overlap, iy1 = y0 + t >= H ? min(t, H - y0) : t - overlap
                for j in iy0..<iy1 {
                    for i in ix0..<ix1 {
                        let d = j * ost[2] + i * ost[3], q = ((y0 + j) * W + (x0 + i)) * 3
                        dst[q] = q16(val(d))
                        dst[q + 1] = q16(val(ost[1] + d))
                        dst[q + 2] = q16(val(2 * ost[1] + d))
                    }
                }
                done += 1
                progress(Double(done) / Double(xs.count * ys.count))
            }
        }
        // Written aside and moved in: an interrupted write must not pass for a result.
        let file = Self.cacheURL(url, raw), tmp = file.deletingPathExtension().appendingPathExtension("part.heic")
        // 10-bit HEIC: no banding once exposure is raised, ~10–20 MB a frame instead of ~150 MB as a 16-bit PNG.
        // The image reads the buffer in place: no second copy of the whole frame.
        try dst.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base, size: buf.count, releaseData: { _, _, _ in }),
                  let cg = CGImage(width: W, height: H, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: W * 6, space: srgb,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGImageByteOrderInfo.order16Big.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw CocoaError(.fileWriteUnknown) }
            do {
                try context.writeHEIF10Representation(of: CIImage(cgImage: cg), to: tmp, colorSpace: srgb,
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
            } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        }
        dst = []
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
        images.removeObject(forKey: file.path as NSString)
        lock.withLock { known[Self.knownKey(url, raw)] = (true, Date()) }
        smalls.removeObject(forKey: file.path as NSString)
    }

    /// Carries the removed noise over to `base`: base + k·(denoised − clamp(base)); `denoised` is scaled to `base`.
    static func apply(_ base: CIImage, denoised: CIImage, amount k: Double) -> CIImage {
        let e = base.extent, de = denoised.extent
        let d = denoised.transformed(by: CGAffineTransform(scaleX: e.width / de.width, y: e.height / de.height))
            .transformed(by: CGAffineTransform(translationX: e.minX - de.minX * e.width / de.width, y: e.minY - de.minY * e.height / de.height))
        return kernel.apply(extent: e, arguments: [base, d, Float(k)]) ?? base
    }

    // Core Image Kernel Language, deprecated: see the note on EditPipeline's kernels for why it isn't Metal yet.
    private static let kernel = CIColorKernel(source:
        "kernel vec4 dn(__sample b, __sample d, float k) { vec3 c = clamp(b.rgb, 0.0, 1.0); return vec4(b.rgb + (d.rgb - c) * k, b.a); }")!
}

extension RawDevelop {
    /// The settings that move or retone the developed base, which results computed from it (AI noise reduction,
    /// removed objects) depend on. Noise reduction, detail and moiré are left out: the AI results replace that
    /// texture, and a minute-long recompute for each slider step would be worse than the tiny difference.
    /// Default for non-RAW files, which ignore RAW settings.
    func base(for url: URL) -> RawDevelop {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return RawDevelop() }
        guard curve != nil || shadowLift != nil || lens != nil || highlightRecovery != nil else { return RawDevelop() }
        // A value equal to what the engine uses anyway is the same image: it must not change the key
        // (the result would be lost, patches marked stale), so it counts as unset. So does one the file can't use.
        let d = ImageStore.shared.rawDefaults(url)
        func same(_ v: Double?, _ e: Double?) -> Double? { if let v, let e, abs(v - e) < 0.5 { return nil }; return v }
        func same(_ v: Bool?, _ e: Bool?, _ supported: Bool?) -> Bool? { supported == false || v == e ? nil : v }
        return RawDevelop(curve: same(curve, d?.curve), shadowLift: same(shadowLift, d?.shadowLift),
                          lens: same(lens, d?.lens, d?.lensSupported),
                          highlightRecovery: same(highlightRecovery, d?.highlightRecovery, d?.highlightRecoverySupported))
    }
}

extension Library {
    /// "Remove Noise (AI)" for the selection: one photo after another in the background (~1 min each),
    /// then the strength slider in Edit applies the result instantly.
    func denoiseTargets() {
        guard !denoiseRunning else { return }
        guard Denoiser.shared.installed else { flash(tr("Модель шумоподавления не установлена (Настройки → AI)")); return }
        let list = targets.filter { !Denoiser.shared.hasResult($0.url, $0.adj.raw) }.map { ($0.url, $0.adj.raw) }
        let ready = targets.filter { Denoiser.shared.hasResult($0.url, $0.adj.raw) }.map(\.id)
        for id in ready { setDenoiseIfNeeded(id) }
        guard !list.isEmpty else { return }
        denoiseRunning = true; denoiseDone = 0; denoiseTotal = list.count; denoiseFraction = 0
        // A weak let, not a [weak self] capture: that one is a var, and the main-actor hops below would share it.
        weak let lib = self
        denoiseTask = Task.detached(priority: .userInitiated) {
            var ok = 0
            for (u, raw) in list {
                if Task.isCancelled { break }
                do {
                    try Denoiser.shared.run(u, raw: raw) { f in Task { @MainActor in lib?.denoiseFraction = f } }
                    ok += 1
                    await MainActor.run { lib?.setDenoiseIfNeeded(u) }
                } catch is CancellationError {
                    break
                } catch {
                    await MainActor.run { lib?.flash(tr("Не удалось убрать шум: \(u.lastPathComponent)")) }
                }
                await MainActor.run { lib?.denoiseDone += 1 }
            }
            let stopped = Task.isCancelled, done = ok
            await MainActor.run {
                guard let lib else { return }
                lib.denoiseRunning = false
                // Counts only the photos that got a result; after "Stop" it says so, not just "N of M".
                lib.flash((stopped ? tr("Остановлено. ") : "") + tr("Шум убран: \(done) из \(lib.denoiseTotal)"))
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
