import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension Library {
    /// Итоговый размер кадра в пикселях при текущих настройках сохранения.
    func outputPixels(_ p: Photo, _ s: ExportSettings) -> CGSize {
        let adj = s.applyEdits ? p.adj : Adjustments()
        let full = pixelSize(p)
        let px = CGSize(width: full.width * adj.cropW, height: full.height * adj.cropH)
        if let plan = ExportPlan.make(aspect: Double(px.width / px.height), userCropped: adj.hasCrop, s) {
            return CGSize(width: plan.width, height: plan.height)
        }
        guard s.longSide > 0 else { return px }
        let k = min(1, CGFloat(s.longSide) / max(px.width, px.height))
        return CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
    }
}

/// Ориентировочный размер файлов: образцы реально сжимаются с выбранным качеством и обработкой,
/// затем байты на пиксель пересчитываются на итоговые размеры всех кадров.
struct SizeEstimate: View {
    @Environment(Library.self) private var lib
    @State private var text = ""
    @State private var busy = false

    private struct Key: Hashable {
        let ids: [URL]
        let s: String
    }

    var body: some View {
        let list = lib.photos(for: lib.export.scope)
        HStack(spacing: 6) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.mini) }
            Text(text.isEmpty ? "Считаю размер…" : text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: Key(ids: list.map(\.id), s: settingsKey)) {
            try? await Task.sleep(for: .milliseconds(250))   // ползунок качества тянут — не считаем каждый шаг
            guard !Task.isCancelled else { return }
            busy = true
            text = await SizeEstimator.describe(lib, list, lib.export) ?? text
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

    /// Оценка в байтах: на каждый кадр и всего. Для оригиналов — точная сумма файлов.
    @MainActor
    static func estimate(_ lib: Library, _ list: [Photo], _ s: ExportSettings) async -> (perPhoto: [Double], exact: Bool)? {
        guard !list.isEmpty else { return nil }
        if s.format == .original && s.preset == .custom {
            let fm = FileManager.default
            return (list.map { p in
                Double(Exporter.companions(of: p.url).reduce(Int64(0)) { $0 + Int64((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) })
            }, true)
        }
        // Образцы: до 3 кадров, равномерно по списку.
        let picks = list.count <= 3 ? list : [list[0], list[list.count / 2], list[list.count - 1]]
        var bppSum = 0.0, n = 0.0
        for p in picks {
            let adj = s.applyEdits ? p.adj : Adjustments()
            if let bpp = await sampleBytesPerPixel(p.url, adj, out: lib.outputPixels(p, s), quality: s.jpegQuality) { bppSum += bpp; n += 1 }
            if Task.isCancelled { return nil }
        }
        guard n > 0 else { return nil }
        let bpp = bppSum / n
        return (list.map { p in let o = lib.outputPixels(p, s); return Double(o.width * o.height) * bpp + 30_000 }, false)
    }

    @MainActor
    static func describe(_ lib: Library, _ list: [Photo], _ s: ExportSettings) async -> String? {
        guard !list.isEmpty else { return "Нечего сохранять" }
        guard let r = await estimate(lib, list, s) else { return nil }
        let total = r.perPhoto.reduce(0, +)
        if r.exact { return "Оригиналы: \(bytes(Int64(total))) всего (\(list.count) шт.)" }
        let one = list.count == 1 ? "" : " · ≈ \(bytes(Int64(total))) всего (\(list.count) шт.)"
        return "≈ \(bytes(Int64(total / Double(list.count)))) на кадр" + one
    }

    /// Байт на пиксель при сжатии кадра в итоговом масштабе.
    static func sampleBytesPerPixel(_ url: URL, _ adj: Adjustments, out: CGSize, quality: Double) async -> Double? {
        let long = max(out.width, out.height)
        if long <= 1600 {
            // Небольшой результат (Instagram, 1600 px) — весь кадр по превью с обработкой.
            guard let img = await Task.detached(priority: .utility, operation: { Renderer.shared.thumbnail(url, adj, size: long) }).value
            else { return nil }
            return await encode(img, quality)
        }
        // Крупный — 5 фрагментов 512×512 в итоговом масштабе: центр и четыре четверти.
        // Один центр завышал оценку на 40–50%: там обычно резкий объект, а края — размытый фон.
        let tile = min(512, out.width, out.height)
        let tw = tile / out.width, th = tile / out.height
        var sum = 0.0, n = 0.0
        for (i, c) in [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].enumerated() {
            let region = CGRect(x: c.0 - tw / 2, y: c.1 - th / 2, width: tw, height: th)
            guard let img = await Renderer.shared.renderRegion(url, adj, region: region, pixels: CGSize(width: tile, height: tile), channel: "estimate\(i)"),
                  let bpp = await encode(img, quality) else { continue }
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
