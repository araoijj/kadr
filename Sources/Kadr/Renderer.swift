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
                let cube = adj.profile == .camera ? CameraMatch.shared.cube(for: url) : nil
                let out = EditPipeline.apply(adj, to: base, cameraCube: cube, asShotK: ImageStore.shared.asShotK(url),
                                              denoised: Denoiser.shared.input(for: url, adj))
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
                let cube = adj.profile == .camera ? CameraMatch.shared.cube(for: url) : nil
                let out = EditPipeline.apply(adj, to: base, cameraCube: cube, asShotK: ImageStore.shared.asShotK(url),
                                              denoised: Denoiser.shared.input(for: url, adj))
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

    /// Develops the RAW and picks the camera profile ahead of time, so the first edit is instant.
    func prewarm(_ url: URL, maxSide: CGFloat) {
        queue.async {
            _ = ImageStore.shared.asShotK(url)
            _ = self.base(url, maxSide: maxSide)
            _ = CameraMatch.shared.cube(for: url)
        }
    }

    /// Edited thumbnail: filters on top of the embedded preview (fast, close to the final result).
    func thumbnail(_ url: URL, _ adj: Adjustments, size: CGFloat = 640) -> CGImage? {
        let key = "\(url.path)|\(adj.hashValue)|\(Int(size))" as NSString
        if let c = thumbs.object(forKey: key) { return c }
        guard let prev = ImageStore.shared.preview(url) else { return nil }
        var img = CIImage(cgImage: prev)
        let k = size / max(img.extent.width, img.extent.height)
        if k < 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        let out = EditPipeline.apply(adj, to: img, asShotK: ImageStore.shared.asShotK(url))
        guard let cg = context.createCGImage(out, from: out.extent.integral, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        thumbs.setObject(cg, forKey: key, cost: cg.bytesPerRow * cg.height)
        return cg
    }

    /// Thumbnail for the grid and filmstrip: the embedded preview, with filters for edited photos.
    static func thumb(for p: Photo) async -> CGImage? {
        let url = p.url, adj = p.adj
        if adj.isIdentity {
            if let c = ImageStore.shared.cachedPreview(url) { return c }
            return await Task.detached(priority: .userInitiated) { ImageStore.shared.preview(url) }.value
        }
        if let c = shared.cachedThumbnail(url, adj) { return c }
        return await Task.detached(priority: .userInitiated) { shared.thumbnail(url, adj) }.value
    }

    func cachedThumbnail(_ url: URL, _ adj: Adjustments, size: CGFloat = 640) -> CGImage? {
        thumbs.object(forKey: "\(url.path)|\(adj.hashValue)|\(Int(size))" as NSString)
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
