import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Approximate file size: samples are actually compressed with the chosen quality and edits,
/// then bytes per pixel are scaled to the final dimensions of all frames.
struct SizeEstimate: View {
    @Environment(Library.self) private var lib
    @State private var text = ""
    @State private var busy = false

    private struct Key: Hashable {
        let ids: [URL]
        let s: String
        let denoised: Int   // a noise reduction result finished while the sheet is open changes the frames
    }

    var body: some View {
        let list = lib.photos(for: lib.export.scope)
        HStack(spacing: 6) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.mini) }
            Text(text.isEmpty ? tr("Считаю размер…") : text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: Key(ids: list.map(\.id), s: settingsKey, denoised: lib.denoiseDone)) {
            try? await Task.sleep(for: .milliseconds(250))   // the quality slider is being dragged; don't recompute on every step
            guard !Task.isCancelled else { return }
            busy = true
            text = await SizeEstimator.describe(list.map(SizeEstimator.Frame.init), lib.export) ?? text
            busy = false
        }
    }

    private var settingsKey: String {
        let s = lib.export
        return "\(s.format)|\(s.preset)|\(s.longSide)|\(s.jpegQuality)|\(s.applyEdits)|\(s.presetCrop)"
    }

}

enum SizeEstimator {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// What the estimate needs of a photo, taken on the main actor; the rest runs off it.
    struct Frame: Sendable {
        let url: URL
        let adj: Adjustments
        let exif: ExifInfo
        let previewAspect: CGFloat?

        @MainActor init(_ p: Photo) {
            url = p.url; adj = p.adj; exif = p.exif
            // A RAW's camera crop is known once its preview was decoded this session (the grid, the loupe, indexing).
            previewAspect = ImageStore.shared.previewAspect(p.url)
        }

        /// Final frame size in pixels with the export settings. EXIF and orientation, never a preview decode:
        /// a thousand of them would stall the sheet and push the loupe's previews out of the cache.
        func outputPixels(_ s: ExportSettings) -> CGSize {
            let adj = s.applyEdits ? adj : Adjustments()
            return Exporter.outputSize(edited(adj), userCropped: adj.hasCrop, s)
        }

        /// Long side of the whole edited frame at the export's scale. A preset's center crop scales it by the axis
        /// it keeps, so it is longer than the output's (3:2 into 9:16: 2880 px, not 1920).
        func scaledLongSide(_ s: ExportSettings) -> CGFloat {
            let adj = s.applyEdits ? adj : Adjustments()
            let px = edited(adj), o = Exporter.outputSize(px, userCropped: adj.hasCrop, s)
            guard px.width > 0, px.height > 0 else { return max(o.width, o.height) }
            return (max(px.width, px.height) * max(o.width / px.width, o.height / px.height)).rounded()
        }

        /// Pixels after our crop.
        private func edited(_ adj: Adjustments) -> CGSize {
            // An index from before the orientation was stored: the file's header has it.
            let ex = exif.width == nil || (exif.orientation == nil && previewAspect == nil) ? ImageStore.shared.exif(url) : exif
            let full = ImageStore.frameSize(ex, previewAspect: previewAspect)
            return CGSize(width: full.width * adj.cropW, height: full.height * adj.cropH)
        }
    }

    /// Estimate in bytes: per frame and total. For originals, the exact sum of file sizes.
    /// Not main-actor isolated: file sizes, headers and sample renders are all read off the main thread.
    static func estimate(_ list: [Frame], _ s: ExportSettings) async -> (perPhoto: [Double], exact: Bool)? {
        guard !list.isEmpty else { return nil }
        // Originals are copied as they are, whatever preset was last chosen for JPEG.
        if s.format == .original {
            let fm = FileManager.default
            return (list.map { p in
                Double(Exporter.companions(of: p.url).reduce(Int64(0)) { $0 + Int64((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) })
            }, true)
        }
        let out = list.map { $0.outputPixels(s) }
        // Samples: up to 3 frames, evenly spaced through the list.
        let picks = list.count <= 3 ? Array(list.indices) : [0, list.count / 2, list.count - 1]
        var bppSum = 0.0, n = 0.0
        for i in picks {
            let adj = s.applyEdits ? list[i].adj : Adjustments()
            if let bpp = await sampleBytesPerPixel(list[i].url, adj, long: list[i].scaledLongSide(s), quality: s.jpegQuality) { bppSum += bpp; n += 1 }
            if Task.isCancelled { return nil }
        }
        guard n > 0 else { return nil }
        let bpp = bppSum / n
        return (out.map { o in Double(o.width * o.height) * bpp + 30_000 }, false)
    }

    static func describe(_ list: [Frame], _ s: ExportSettings) async -> String? {
        guard !list.isEmpty else { return tr("Нечего сохранять") }
        guard let r = await estimate(list, s) else { return nil }
        let total = r.perPhoto.reduce(0, +)
        if r.exact { return tr("Оригиналы: \(bytes(Int64(total))) всего (\(list.count) шт.)") }
        let one = list.count == 1 ? "" : tr(" · ≈ \(bytes(Int64(total))) всего (\(list.count) шт.)")
        return tr("≈ \(bytes(Int64(total / Double(list.count)))) на кадр") + one
    }

    /// Bytes per pixel when compressing a frame at the final scale (`long`: the whole frame's long side at it).
    static func sampleBytesPerPixel(_ url: URL, _ adj: Adjustments, long: CGFloat, quality: Double) async -> Double? {
        if long <= 1600 {
            // Small result (Instagram, 1600 px): the whole frame from the preview with edits.
            guard let img = await Task.detached(priority: .utility, operation: { await Renderer.shared.thumbnail(url, adj, size: long) }).value
            else { return nil }
            return await encode(img, quality)
        }
        // Large result: 5 tiles of 512×512 at the final scale: the center and four quarters.
        // The center alone overestimated by 40–50%: it usually holds a sharp subject, while the edges are blurred background.
        let centers = [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { CGPoint(x: $0.0, y: $0.1) }
        var sum = 0.0, n = 0.0
        for part in await Renderer.shared.estimateTiles(url, adj, longSide: long, tile: 512, centers: centers) {
            guard let bpp = await encode(part, quality) else { continue }
            sum += bpp; n += 1
        }
        return n > 0 ? sum / n : nil
    }

    private static func encode(_ img: CGImage, _ quality: Double) async -> Double? {
        await Task.detached(priority: .utility) { () -> Double? in
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return Double(data.length) / Double(img.width * img.height)
        }.value
    }
}
