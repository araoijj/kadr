import CoreImage
import Foundation

/// Профиль «как в камере». Для каждого RAW подбираем 3D-LUT, который переводит проявление macOS
/// в цвета встроенного JPEG камеры: оба изображения уменьшаем до одного размера и усредняем,
/// какой цвет камеры соответствует каждому цвету macOS. Так обработка начинается с привычных цветов Sony.
final class CameraMatch: @unchecked Sendable {
    static let shared = CameraMatch()
    static let size = 17

    private let lock = NSLock()
    private var cache: [String: (size: Int, data: Data)?] = [:]
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    func cube(for url: URL) -> (size: Int, data: Data)? {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        lock.lock()
        if let c = cache[url.path] { lock.unlock(); return c }
        lock.unlock()
        let c = fit(url)
        lock.lock(); cache[url.path] = c; lock.unlock()
        return c
    }

    private func fit(_ url: URL) -> (size: Int, data: Data)? {
        guard let camera = ImageStore.shared.preview(url), let raw = EditPipeline.source(url, maxSide: 900) else { return nil }
        // Кадр превью и RAW должны совпадать по пропорциям (иначе сравнивать нечего).
        let ca = Double(camera.width) / Double(camera.height), ra = raw.extent.width / raw.extent.height
        guard abs(ca - ra) / ca < 0.02 else { return nil }
        let w = 360, h = Int((Double(w) / ca).rounded())
        guard let tgt = pixels(CIImage(cgImage: camera), w, h), let src = pixels(raw, w, h) else { return nil }

        let n = Self.size
        var sum = [Double](repeating: 0, count: n * n * n * 3)
        var weight = [Double](repeating: 0, count: n * n * n)
        let k = Double(n - 1)
        // Края кадра пропускаем: там различаются коррекции объектива и виньетирование.
        for y in (h / 12)..<(h - h / 12) {
            for x in (w / 12)..<(w - w / 12) {
                let i = (y * w + x) * 4
                let s = (Double(src[i]) / 255 * k, Double(src[i + 1]) / 255 * k, Double(src[i + 2]) / 255 * k)
                let t = (Double(tgt[i]) / 255, Double(tgt[i + 1]) / 255, Double(tgt[i + 2]) / 255)
                let r0 = min(Int(s.0), n - 2), g0 = min(Int(s.1), n - 2), b0 = min(Int(s.2), n - 2)
                let dr = s.0 - Double(r0), dg = s.1 - Double(g0), db = s.2 - Double(b0)
                for cb in 0...1 { for cg in 0...1 { for cr in 0...1 {
                    let wgt = (cr == 0 ? 1 - dr : dr) * (cg == 0 ? 1 - dg : dg) * (cb == 0 ? 1 - db : db)
                    guard wgt > 0 else { continue }
                    let j = (r0 + cr) + (g0 + cg) * n + (b0 + cb) * n * n
                    weight[j] += wgt
                    sum[j * 3] += wgt * t.0; sum[j * 3 + 1] += wgt * t.1; sum[j * 3 + 2] += wgt * t.2
                } } }
            }
        }
        // Там, где цветов кадра мало, — сдвиг соседей; где нет совсем — без изменений.
        var shift = [Double](repeating: 0, count: n * n * n * 3)
        var known = [Double](repeating: 0, count: n * n * n)
        for j in 0..<(n * n * n) where weight[j] > 0.5 {
            let id = identity(j, n)
            for ch in 0..<3 { shift[j * 3 + ch] = sum[j * 3 + ch] / weight[j] - id[ch] }
            known[j] = min(1, weight[j] / 4)
        }
        for _ in 0..<6 {   // размываем сдвиг на пустые клетки
            var next = shift, nextKnown = known
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let j = r + g * n + b * n * n
                guard known[j] < 1 else { continue }
                var acc = [0.0, 0.0, 0.0], kw = 0.0
                for (dr, dg, db) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let rr = r + dr, gg = g + dg, bb = b + db
                    guard rr >= 0, rr < n, gg >= 0, gg < n, bb >= 0, bb < n else { continue }
                    let q = rr + gg * n + bb * n * n
                    for ch in 0..<3 { acc[ch] += shift[q * 3 + ch] * known[q] }
                    kw += known[q]
                }
                guard kw > 0 else { continue }
                let blend = 1 - known[j]
                for ch in 0..<3 { next[j * 3 + ch] = shift[j * 3 + ch] * known[j] + acc[ch] / kw * blend }
                nextKnown[j] = max(known[j], min(1, kw / 6) * 0.7)
            } } }
            shift = next
            known = nextKnown
        }
        var values = [Float](repeating: 1, count: n * n * n * 4)
        for j in 0..<(n * n * n) {
            let id = identity(j, n)
            for ch in 0..<3 { values[j * 4 + ch] = Float(min(1, max(0, id[ch] + shift[j * 3 + ch]))) }
        }
        return (n, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private func identity(_ j: Int, _ n: Int) -> [Double] {
        let k = Double(n - 1)
        return [Double(j % n) / k, Double((j / n) % n) / k, Double(j / (n * n)) / k]
    }

    private func pixels(_ img: CIImage, _ w: Int, _ h: Int) -> [UInt8]? {
        let sx = CGFloat(w) / img.extent.width, sy = CGFloat(h) / img.extent.height
        let scaled = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: EditPipeline.srgb)
        return px
    }
}
