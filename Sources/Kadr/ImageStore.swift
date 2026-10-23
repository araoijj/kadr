import AppKit
import CoreImage
import ImageIO

/// Fast image reading. For viewing we use the JPEG preview the camera embeds in the RAW
/// (1616×1080 on the Sony A1, ~20 ms per photo). Full RAW development only on demand (100% zoom).
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private let thumbs = NSCache<NSURL, CGImage>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init() {
        applyMemoryLimit()
    }

    /// Previews are limited by bytes, not by count: a decoded 1616×1080 preview is ~7 MB,
    /// so "4000 previews" could mean tens of gigabytes on a big shoot.
    func applyMemoryLimit() {
        thumbs.totalCostLimit = Prefs.previewBytes
        Renderer.shared.applyMemoryLimit()
    }

    static let rawExtensions: Set<String> = ["arw", "srf", "sr2", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "dng", "pef", "3fr", "iiq"]
    static let imageExtensions: Set<String> = rawExtensions.union(["jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff"])

    /// Embedded preview (or a downscaled image if there's no preview).
    func preview(_ url: URL) -> CGImage? {
        if let c = thumbs.object(forKey: url as NSURL) { return c }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // RAW: the camera-embedded preview (fast). The embedded EXIF thumbnail in a JPEG is only 160×120
        // (and letterboxed in black for portrait shots), so JPEG and other formats are read from the image itself.
        // If even the RAW preview is tiny, read from the image itself as well.
        let raw = Self.rawExtensions.contains(url.pathExtension.lowercased())
        func make(_ always: Bool) -> CGImage? {
            var opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if always { opts[kCGImageSourceCreateThumbnailFromImageAlways] = true }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        var img: CGImage
        if !raw, let fast = subsampled(src) {
            img = fast
        } else {
            guard let m = make(!raw) else { return nil }
            img = m
        }
        if raw, max(img.width, img.height) < 1000, let big = make(true) { img = big }
        thumbs.setObject(img, forKey: url as NSURL, cost: img.bytesPerRow * img.height)
        aspectLock.lock(); aspects[url] = CGFloat(img.width) / CGFloat(img.height); aspectLock.unlock()
        return img
    }

    private let aspectLock = NSLock()
    private var aspects: [URL: CGFloat] = [:]

    /// Shape of a preview decoded this session (orientation and camera crop), kept after the preview
    /// itself leaves the cache: sizes are then right without decoding it again.
    func previewAspect(_ url: URL) -> CGFloat? {
        if let c = thumbs.object(forKey: url as NSURL) { return CGFloat(c.width) / CGFloat(c.height) }
        aspectLock.lock(); defer { aspectLock.unlock() }
        return aspects[url]
    }

    /// JPEG downscaled while decoding (4× DCT: 6000 px → 1500 px), twice as fast as a full decode.
    /// EXIF orientation is applied manually: this path doesn't apply it.
    private func subsampled(_ src: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(w, h) >= 4800,   // smaller than that, 4× downscaling gives too small an image; let it go the normal path
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceSubsampleFactor: 4, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let o = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard o != 1 else { return img }
        let ci = CIImage(cgImage: img).oriented(forExifOrientation: Int32(o))
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Image downscaled to maxSide, for a sharp JPEG/HEIC view at screen size.
    func decoded(_ url: URL, maxSide: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    func cachedPreview(_ url: URL) -> CGImage? { thumbs.object(forKey: url as NSURL) }

    private let wbLock = NSLock()
    private var wbCache: [String: Double] = [:]
    private var rawDefaultsCache: [String: RawDevelop.Defaults?] = [:]   // nil = the RAW engine can't open it

    /// As-shot white balance in Kelvin (5500 K daylight for non-RAW).
    func asShotK(_ url: URL) -> Double {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return 5500 }
        wbLock.lock()
        if let k = wbCache[url.path] { wbLock.unlock(); return k }
        wbLock.unlock()
        let k = CIRAWFilter(imageURL: url).map { Double($0.neutralTemperature) }.flatMap { $0 > 1000 ? $0 : nil } ?? 5500
        wbLock.lock(); wbCache[url.path] = k; wbLock.unlock()
        return k
    }

    /// What the RAW engine uses for this file by default (for the "RAW development" sliders); nil for non-RAW.
    func rawDefaults(_ url: URL) -> RawDevelop.Defaults? {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        wbLock.lock()
        if let d = rawDefaultsCache[url.path] { wbLock.unlock(); return d }
        wbLock.unlock()
        // A failure is remembered too: otherwise every return to the frame opens the RAW again.
        let d = CIRAWFilter(imageURL: url).map(RawDevelop.defaults)
        wbLock.lock(); rawDefaultsCache[url.path] = .some(d); wbLock.unlock()
        return d
    }

    /// The values above if already read, without opening the RAW (for views: their body runs on the main thread).
    /// asShotK: nil while unknown; rawDefaults: .some(nil) for a non-RAW or one it can't open, nil while unknown.
    func cachedAsShotK(_ url: URL) -> Double? {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return 5500 }
        return wbLock.withLock { wbCache[url.path] }
    }

    func cachedRawDefaults(_ url: URL) -> RawDevelop.Defaults?? {
        guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else { return .some(nil) }
        return wbLock.withLock { rawDefaultsCache[url.path] }
    }

    /// `exif` read once per file, for a frame not indexed yet: by crop actions and by the loupe off the main thread.
    /// Views take only `cachedHeaderExif`: their body runs on the main thread, for every frame in the export summary.
    func headerExif(_ url: URL) -> ExifInfo {
        if let e = cachedHeaderExif(url) { return e }
        let e = exif(url)
        wbLock.withLock {
            if exifMemo.count >= 2000 { exifMemo.removeAll() }   // only until the index has them; a cap, not an LRU
            exifMemo[url.path] = e
        }
        return e
    }
    func cachedHeaderExif(_ url: URL) -> ExifInfo? { wbLock.withLock { exifMemo[url.path] } }
    private var exifMemo: [String: ExifInfo] = [:]

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
        info.orientation = p[kCGImagePropertyOrientation] as? Int
        return info
    }

    /// Frame size in pixels as shown: dimensions from EXIF, the shape (orientation and the camera crop,
    /// e.g. a 4:3 shot in a 3:2 RAW) from the preview. Preview proportions are inexact (1616×1080 ≠ 3:2),
    /// so only their "shape" is taken. Without a preview the EXIF orientation turns the frame.
    static func frameSize(_ ex: ExifInfo, previewAspect pa: CGFloat?) -> CGSize {
        let W = CGFloat(ex.width ?? 0), H = CGFloat(ex.height ?? 0)
        guard W > 0, H > 0 else { return CGSize(width: 1000 * (pa ?? 1.5), height: 1000) }
        guard let pa else { return (5...8).contains(ex.orientation ?? 1) ? CGSize(width: H, height: W) : CGSize(width: W, height: H) }
        let long = max(W, H), short = min(W, H)
        var w = pa >= 1 ? long : short, h = pa >= 1 ? short : long
        // The camera cropped (e.g. 4:3): the preview proportions are noticeably different.
        if abs(w / h - pa) / pa > 0.02 { if pa < w / h { w = h * pa } else { h = w / pa } }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    // MARK: - Analysis: similarity and sharpness

    /// 64-bit dHash: compares the brightness of neighboring pixels in the image downscaled to 9×8.
    /// Robust to exposure differences, so brackets and series fall into the same group.
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

    /// Sharpness = variance of the Laplacian over the central part of the frame (where the subject usually is).
    func sharpness(_ img: CGImage) -> Double? {
        let w = 640, h = Int(Double(w) * Double(img.height) / Double(img.width))
        guard h > 4, let g = grayscale(img, width: w, height: h) else { return nil }
        // The Laplacian reads the neighbours: keep a 1-px border even when a panorama leaves only a few rows.
        let x0 = max(1, w / 6), x1 = min(w - 1, w - w / 6), y0 = max(1, h / 6), y1 = min(h - 1, h - h / 6)
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

    /// Sharpness within a region (fractions of the image, y top-down), e.g. a face. The region is scaled to 160 px
    /// so faces of different sizes are compared fairly.
    func sharpness(_ img: CGImage, region r: CGRect) -> Double? {
        let pad = 0.08
        let rr = CGRect(x: max(0, r.minX - r.width * pad), y: max(0, r.minY - r.height * pad),
                        width: min(1, r.width * (1 + 2 * pad)), height: min(1, r.height * (1 + 2 * pad)))
        let px = CGRect(x: rr.minX * CGFloat(img.width), y: rr.minY * CGFloat(img.height),
                        width: rr.width * CGFloat(img.width), height: rr.height * CGFloat(img.height)).integral
        guard px.width >= 24, px.height >= 24, let crop = img.cropping(to: px) else { return nil }
        let w = 160, h = max(24, Int(160 * px.height / px.width))
        guard let g = grayscale(crop, width: w, height: h) else { return nil }
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
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
