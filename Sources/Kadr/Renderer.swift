import CoreImage
import Foundation

/// Rendering of edited photos. The developed RAW (base) is cached, so when a slider moves
/// only the filters are recomputed: tens of milliseconds, not seconds.
final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
    private let queue = DispatchQueue(label: "kadr.render", qos: .userInitiated)
    private let lock = NSLock()
    private var bases: [String: CIImage] = [:]
    private var baseOrder: [String] = []
    private var generation: [String: Int] = [:]
    private let thumbs = NSCache<NSString, CGImage>()

    init() { applyMemoryLimit() }

    /// Edited thumbnails: a quarter of the preview memory budget.
    func applyMemoryLimit() { thumbs.totalCostLimit = Prefs.previewBytes / 4 }

    /// Developed image for viewing. If a new request came in on the same channel while this one
    /// was being computed, return nil (the old image is left untouched).
    func render(_ url: URL, _ adj: Adjustments, maxSide: CGFloat?, channel: String = "loupe") async -> CGImage? {
        let gen = bump(channel)
        return await withCheckedContinuation { cont in
            queue.async {
                guard self.current(channel) == gen else { cont.resume(returning: nil); return }
                guard let base = self.base(url, maxSide: maxSide, raw: adj.raw) else { cont.resume(returning: nil); return }
                let out = EditPipeline.render(adj, url, source: base)
                let cg = self.context.createCGImage(out, from: out.extent.integral, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
                cont.resume(returning: cg)
            }
        }
    }

    /// Visible part of the image when zoomed in. region: fractions of the image (y top-down); pixels: on-screen size.
    /// Only this part is computed; if resolution falls short, the full-size RAW development is used.
    func renderRegion(_ url: URL, _ adj: Adjustments, region: CGRect, pixels: CGSize, channel: String = "region") async -> CGImage? {
        let gen = bump(channel)
        return await withCheckedContinuation { cont in
            queue.async {
                guard self.current(channel) == gen, pixels.width >= 1, pixels.height >= 1, region.width > 0 else { cont.resume(returning: nil); return }
                guard var base = self.base(url, maxSide: 3200, raw: adj.raw) else { cont.resume(returning: nil); return }
                if pixels.width / region.width > base.extent.width * adj.cropW * 1.05, let full = self.base(url, maxSide: nil, raw: adj.raw) { base = full }
                guard self.current(channel) == gen else { cont.resume(returning: nil); return }
                let out = EditPipeline.render(adj, url, source: base)
                let e = out.extent   // already after cropping
                let r = CGRect(x: e.minX + region.minX * e.width, y: e.minY + (1 - region.maxY) * e.height,
                               width: region.width * e.width, height: region.height * e.height)
                let k = pixels.width / r.width
                var img = out.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                if k > 1 { img = img.samplingNearest() }   // above 100%, no smoothing, so the real pixels are visible
                img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                let cg = self.context.createCGImage(img, from: CGRect(origin: .zero, size: pixels).integral, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
                cont.resume(returning: cg)
            }
        }
    }

    private let estimateQueue = DispatchQueue(label: "kadr.estimate", qos: .utility)
    private let estimateContext = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// Tiles of the edited frame at its final scale (long side `longSide`) for the export size estimate: `tile` px
    /// squares around `centers` (fractions). Denser detail would compress worse, so a frame longer than 3200 px is
    /// developed at the size it needs; only the tiles are computed. Its own queue and no cached base: an estimate
    /// neither waits behind the loupe nor evicts its developed RAWs. The tiles of the last few frames are kept:
    /// they don't depend on the quality, so dragging its slider only re-encodes them.
    func estimateTiles(_ url: URL, _ adj: Adjustments, longSide: CGFloat, tile: CGFloat, centers: [CGPoint]) async -> [CGImage] {
        await withCheckedContinuation { cont in
            estimateQueue.async {
                // Like thumbKey: a noise reduction result that has just appeared changes the tiles.
                let dn = adj.aiDenoise > 0 && Denoiser.shared.hasResult(url, adj.raw) ? "|dn" : ""
                let key = "\(url.path)|\(adj.hashValue)|\(Int(longSide))|\(Int(tile))|\(centers)\(dn)"
                if let m = self.estimateMemo.first(where: { $0.key == key }) { cont.resume(returning: m.tiles); return }
                func edited(_ maxSide: CGFloat?) -> CIImage? {
                    EditPipeline.source(url, maxSide: maxSide, raw: adj.raw).map { EditPipeline.render(adj, url, source: $0) }
                }
                guard var out = edited(3200) else { cont.resume(returning: []); return }
                let need = longSide / max(out.extent.width, out.extent.height)
                if need > 1.01, let big = edited(3200 * need * 1.05) { out = big }
                out = EditPipeline.fit(out, maxSide: longSide)
                let e = out.extent, side = min(tile, e.width, e.height)
                let p3 = CGColorSpace(name: CGColorSpace.displayP3)
                let tiles = centers.compactMap { c in
                    self.estimateContext.createCGImage(out, from: CGRect(x: e.minX + c.x * e.width - side / 2, y: e.minY + c.y * e.height - side / 2,
                                                                         width: side, height: side).integral,
                                                       format: .RGBA8, colorSpace: p3)
                }
                self.estimateMemo.append((key, tiles))
                if self.estimateMemo.count > 3 { self.estimateMemo.removeFirst() }   // the estimate samples 3 frames
                cont.resume(returning: tiles)
            }
        }
    }
    private var estimateMemo: [(key: String, tiles: [CGImage])] = []   // estimateQueue only

    /// Develops the RAW and picks the camera profile ahead of time, so the first edit is instant.
    /// `raw` is the photo's own RAW settings: the base is cached per settings, so a default one would be wasted on an edited RAW.
    func prewarm(_ url: URL, maxSide: CGFloat, raw: RawDevelop = RawDevelop()) {
        queue.async {
            _ = ImageStore.shared.asShotK(url)
            _ = self.base(url, maxSide: maxSide, raw: raw)
            _ = CameraMatch.shared.cube(for: url)
        }
    }

    private let smallLock = NSLock()
    private var smallBases: [String: CIImage] = [:]
    private var smallOrder: [String] = []

    /// Edited thumbnail through the same develop chain as the loupe and the export (RAW settings, profile,
    /// AI noise reduction), only small. Sizes up to 640 share one 640-px development per frame, so the grid cell,
    /// the histogram and the style previews decode the RAW once.
    func thumbnail(_ url: URL, _ adj: Adjustments, size: CGFloat = 640) async -> CGImage? {
        if let c = cachedThumbnail(url, adj, size: size) { return c }
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return makeThumbnail(url, adj, size: size) }
        // A few RAW developments at a time (the base and the camera profile's own 900 px one): a scrolled grid
        // starts dozens, each holding the sensor data. Their own threads, so the queue never ties up Swift's pool.
        return await withCheckedContinuation { cont in
            rawThumbs.addOperation { cont.resume(returning: self.makeThumbnail(url, adj, size: size)) }
        }
    }
    private let rawThumbs: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private func makeThumbnail(_ url: URL, _ adj: Adjustments, size: CGFloat) -> CGImage? {
        let key = thumbKey(url, adj, size)
        if let c = thumbs.object(forKey: key) { return c }
        guard let base = smallBase(url, maxSide: max(size, 640), raw: adj.raw) else { return nil }
        let out = EditPipeline.render(adj, url, source: EditPipeline.fit(base, maxSide: size), small: size <= 1600)
        guard let cg = context.createCGImage(out, from: out.extent.integral, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        thumbs.setObject(cg, forKey: key, cost: cg.bytesPerRow * cg.height)
        return cg
    }

    /// Stand-in for the loupe while the RAW develops: the edits over the embedded preview (tens of ms).
    /// Approximate: ignores the profile, the RAW settings and AI noise reduction.
    func quick(_ url: URL, _ adj: Adjustments, size: CGFloat = 1600) -> CGImage? {
        let key = "q|\(url.path)|\(adj.hashValue)|\(Int(size))" as NSString
        if let c = thumbs.object(forKey: key) { return c }
        guard let prev = ImageStore.shared.preview(url) else { return nil }
        let img = EditPipeline.fit(CIImage(cgImage: prev), maxSide: size)
        let out = EditPipeline.apply(adj, to: img, asShotK: ImageStore.shared.asShotK(url))
        guard let cg = context.createCGImage(out, from: out.extent.integral, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        thumbs.setObject(cg, forKey: key, cost: cg.bytesPerRow * cg.height)
        return cg
    }

    /// Whole frame at low resolution for the zoom backdrop and the navigator, if one is already rendered.
    func cachedLowRes(_ url: URL, _ adj: Adjustments) -> CGImage? {
        thumbs.object(forKey: "q|\(url.path)|\(adj.hashValue)|1600" as NSString) ?? cachedThumbnail(url, adj)
    }

    /// Thumbnail for the grid and filmstrip: the embedded preview, with filters for edited photos.
    static func thumb(for p: Photo) async -> CGImage? {
        let url = p.url, adj = p.adj
        if adj.isIdentity {
            if let c = ImageStore.shared.cachedPreview(url) { return c }
            return await Task.detached(priority: .userInitiated) { ImageStore.shared.preview(url) }.value
        }
        if let c = shared.cachedThumbnail(url, adj) { return c }
        return await Task.detached(priority: .userInitiated) { await shared.thumbnail(url, adj) }.value
    }

    func cachedThumbnail(_ url: URL, _ adj: Adjustments, size: CGFloat = 640) -> CGImage? {
        thumbs.object(forKey: thumbKey(url, adj, size))
    }

    /// Drops edited thumbnails and the estimate's tiles, e.g. when a LUT file they used was replaced.
    func clearThumbnails() {
        thumbs.removeAllObjects()
        estimateQueue.async { self.estimateMemo = [] }
    }

    /// Everything that changes the image: the settings, plus whether the AI noise reduction result exists yet
    /// (it may be switched on before it is computed).
    private func thumbKey(_ url: URL, _ adj: Adjustments, _ size: CGFloat) -> NSString {
        let dn = adj.aiDenoise > 0 && Denoiser.shared.hasResult(url, adj.raw) ? "|dn" : ""
        return "\(url.path)|\(adj.hashValue)|\(Int(size))\(dn)" as NSString
    }

    /// Small developed source for thumbnails: its own little cache, so the grid never evicts the loupe's bases.
    /// A RAW is developed in draft mode up to 640 px (the estimate's bigger samples need the real one); any other
    /// file is read from its preview, which is the image itself downscaled while decoding (a full decode per
    /// thumbnail would be far slower).
    private func smallBase(_ url: URL, maxSide: CGFloat, raw: RawDevelop) -> CIImage? {
        let key = "\(url.path)|\(raw.isDefault ? "" : String(describing: raw))|\(Int(maxSide))"
        if let b = smallLock.withLock({ smallBases[key] }) { return b }
        let src = ImageStore.rawExtensions.contains(url.pathExtension.lowercased())
            ? EditPipeline.source(url, maxSide: maxSide, raw: raw, draft: maxSide <= 640)
            : ImageStore.shared.preview(url).map { EditPipeline.fit(CIImage(cgImage: $0), maxSide: maxSide) }
        guard let src else { return nil }
        let b = src.insertingIntermediate(cache: true)
        // Only the grid's 640-px developments are shared; a bigger one (the estimate's 1600-px sample) is a one-off
        // and would hold ~14 MB of half-float pixels per entry.
        guard maxSide <= 640 else { return b }
        smallLock.withLock {
            if smallBases[key] == nil { smallOrder.append(key) }
            smallBases[key] = b
            while smallOrder.count > 12 { smallBases[smallOrder.removeFirst()] = nil }
        }
        return b
    }

    // MARK: -

    private func bump(_ channel: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let g = (generation[channel] ?? 0) + 1
        generation[channel] = g
        return g
    }

    private func current(_ channel: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generation[channel] ?? 0
    }

    private func base(_ url: URL, maxSide: CGFloat?, raw: RawDevelop = RawDevelop()) -> CIImage? {
        // The size goes last: full-size bases are found by the "|0" suffix.
        let key = "\(url.path)|\(raw.isDefault ? "" : String(describing: raw))|\(maxSide.map { Int($0) } ?? 0)"
        if let b = bases[key] { return b }
        guard let src = EditPipeline.source(url, maxSide: maxSide, raw: raw) else { return nil }
        let b = src.insertingIntermediate(cache: true)
        // Only one full-size base (50 MP ≈ 400 MB); the rest are up to 4 downscaled ones.
        if maxSide == nil {
            for k in baseOrder where k.hasSuffix("|0") { bases[k] = nil }
            baseOrder.removeAll { $0.hasSuffix("|0") }
        }
        bases[key] = b
        baseOrder.append(key)
        // Room for the current frame plus the three prefetched neighbors.
        while baseOrder.count > max(5, Prefs.renderCache) { bases[baseOrder.removeFirst()] = nil }
        return b
    }
}
