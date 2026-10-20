import CoreImage
import Foundation

/// Отрисовка обработанных кадров. Проявленный RAW (база) кэшируется, поэтому при движении
/// ползунка пересчитываются только фильтры — это десятки миллисекунд, а не секунды.
final class Renderer: @unchecked Sendable {
    static let shared = Renderer()

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
    private let queue = DispatchQueue(label: "kadr.render", qos: .userInitiated)
    private let lock = NSLock()
    private var bases: [String: CIImage] = [:]
    private var baseOrder: [String] = []
    private var generation: [String: Int] = [:]
    private let thumbs = NSCache<NSString, CGImage>()

    init() { thumbs.countLimit = 2000 }

    /// Проявленный кадр для просмотра. Если пока считался этот запрос, пришёл новый
    /// по тому же каналу — возвращаем nil (старую картинку не трогаем).
    func render(_ url: URL, _ adj: Adjustments, maxSide: CGFloat?, channel: String = "loupe") async -> CGImage? {
        let gen = bump(channel)
        return await withCheckedContinuation { cont in
            queue.async {
                guard self.current(channel) == gen else { cont.resume(returning: nil); return }
                guard let base = self.base(url, maxSide: maxSide) else { cont.resume(returning: nil); return }
                let cube = adj.profile == .camera ? CameraMatch.shared.cube(for: url) : nil
                let out = EditPipeline.apply(adj, to: base, cameraCube: cube)
                let cg = self.context.createCGImage(out, from: out.extent.integral, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
                cont.resume(returning: cg)
            }
        }
    }

    /// Заранее проявляет RAW и подбирает профиль камеры — первая правка будет мгновенной.
    func prewarm(_ url: URL, maxSide: CGFloat) {
        queue.async {
            _ = self.base(url, maxSide: maxSide)
            _ = CameraMatch.shared.cube(for: url)
        }
    }

    /// Миниатюра с обработкой: фильтры поверх встроенного превью (быстро, близко к итогу).
    func thumbnail(_ url: URL, _ adj: Adjustments, size: CGFloat = 640) -> CGImage? {
        let key = "\(url.path)|\(adj.hashValue)|\(Int(size))" as NSString
        if let c = thumbs.object(forKey: key) { return c }
        guard let prev = ImageStore.shared.preview(url) else { return nil }
        var img = CIImage(cgImage: prev)
        let k = size / max(img.extent.width, img.extent.height)
        if k < 1 { img = img.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
        let out = EditPipeline.apply(adj, to: img)
        guard let cg = context.createCGImage(out, from: out.extent.integral, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        thumbs.setObject(cg, forKey: key)
        return cg
    }

    /// Миниатюра для сетки и ленты: встроенное превью, а у обработанных — с фильтрами.
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

    private func base(_ url: URL, maxSide: CGFloat?) -> CIImage? {
        let key = "\(url.path)|\(maxSide.map { Int($0) } ?? 0)"
        if let b = bases[key] { return b }
        guard let src = EditPipeline.source(url, maxSide: maxSide) else { return nil }
        let b = src.insertingIntermediate(cache: true)
        bases[key] = b
        baseOrder.append(key)
        // Держим 4 последних кадра: текущий и соседей.
        while baseOrder.count > 4 { bases[baseOrder.removeFirst()] = nil }
        return b
    }
}
