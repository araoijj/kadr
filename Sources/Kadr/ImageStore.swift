import AppKit
import CoreImage
import ImageIO

/// Быстрое чтение снимков. Для просмотра берём JPEG-превью, которое камера встраивает в RAW
/// (у Sony A1 — 1616×1080, ~20 мс на кадр). Полное проявление RAW — только по запросу (зум 100%).
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private let thumbs = NSCache<NSURL, CGImage>()
    private let full = NSCache<NSURL, CGImage>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init() {
        thumbs.countLimit = Prefs.thumbCache
        full.countLimit = 3
    }

    static let rawExtensions: Set<String> = ["arw", "srf", "sr2", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "dng", "pef", "3fr", "iiq"]
    static let imageExtensions: Set<String> = rawExtensions.union(["jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff"])

    /// Встроенное превью (или уменьшенная картинка, если превью нет).
    func preview(_ url: URL) -> CGImage? {
        if let c = thumbs.object(forKey: url as NSURL) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        thumbs.setObject(img, forKey: url as NSURL)
        return img
    }

    func cachedPreview(_ url: URL) -> CGImage? { thumbs.object(forKey: url as NSURL) }

    /// Полное проявление RAW (для зума 100%). У 50 Мп файла ~1–2 с, поэтому кэшируем 3 последних.
    func fullImage(_ url: URL) -> CGImage? {
        if let c = full.object(forKey: url as NSURL) { return c }
        var ci: CIImage?
        if ImageStore.rawExtensions.contains(url.pathExtension.lowercased()), let raw = CIRAWFilter(imageURL: url) {
            ci = raw.outputImage
        } else {
            ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let ci, let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        full.setObject(cg, forKey: url as NSURL)
        return cg
    }

    private let wbLock = NSLock()
    private var wbCache: [String: Double] = [:]

    /// Баланс белого «как снято», кельвины (у не-RAW — 5500 K, дневной свет).
    func asShotK(_ url: URL) -> Double {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return 5500 }
        wbLock.lock()
        if let k = wbCache[url.path] { wbLock.unlock(); return k }
        wbLock.unlock()
        let k = CIRAWFilter(imageURL: url).map { Double($0.neutralTemperature) }.flatMap { $0 > 1000 ? $0 : nil } ?? 5500
        wbLock.lock(); wbCache[url.path] = k; wbLock.unlock()
        return k
    }

    func exif(_ url: URL) -> ExifInfo {
        var info = ExifInfo()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return info }
        let ex = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exAux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        if let s = ex[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if var d = f.date(from: s) {
                if let sub = ex[kCGImagePropertyExifSubsecTimeOriginal] as? String, let v = Double("0." + sub) { d += v }
                info.date = d
            }
        }
        info.camera = tiff[kCGImagePropertyTIFFModel] as? String
        info.lens = (ex[kCGImagePropertyExifLensModel] as? String) ?? (exAux[kCGImagePropertyExifAuxLensModel] as? String)
        info.iso = (ex[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        info.shutter = ex[kCGImagePropertyExifExposureTime] as? Double
        info.aperture = ex[kCGImagePropertyExifFNumber] as? Double
        info.focal = ex[kCGImagePropertyExifFocalLength] as? Double
        info.width = p[kCGImagePropertyPixelWidth] as? Int
        info.height = p[kCGImagePropertyPixelHeight] as? Int
        return info
    }

    // MARK: - Анализ: похожесть и резкость

    /// dHash 64 бита: сравнивает яркость соседних точек уменьшенной до 9×8 картинки.
    /// Устойчив к разной экспозиции, поэтому брекетинг и серии попадают в одну группу.
    func dHash(_ img: CGImage) -> UInt64? {
        guard let g = grayscale(img, width: 9, height: 8) else { return nil }
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                h <<= 1
                if g[y * 9 + x] < g[y * 9 + x + 1] { h |= 1 }
            }
        }
        return h
    }

    /// Резкость = дисперсия лапласиана по центральной части кадра (там обычно объект).
    func sharpness(_ img: CGImage) -> Double? {
        let w = 640, h = Int(Double(w) * Double(img.height) / Double(img.width))
        guard h > 4, let g = grayscale(img, width: w, height: h) else { return nil }
        let x0 = w / 6, x1 = w - w / 6, y0 = h / 6, y1 = h - h / 6
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = y * w + x
                let lap = Double(g[i - 1]) + Double(g[i + 1]) + Double(g[i - w]) + Double(g[i + w]) - 4 * Double(g[i])
                sum += lap; sq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return sq / n - mean * mean
    }

    private func grayscale(_ img: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }
}
