import CoreGraphics
import Foundation

extension Library {
    /// Matches exposure and white balance of the selection (or, with one photo selected, its burst) to the
    /// current photo: the same absolute kelvin and tint, and exposure that brings the average brightness to the
    /// reference. Everything else on each photo stays as it is. One undo step.
    func matchToCurrent() {
        guard let ref = current else { return }
        let others = (multiSelected ? targets : series(of: ref)).filter { $0.id != ref.id }
        guard !others.isEmpty else { flash(tr("Выделите кадры или откройте кадр из серии — их выровняю по текущему")); return }
        let refK = ImageStore.shared.asShotK(ref.url) + ref.adj.wbShift
        guard let refL = Self.meanLinearLuma(ref.url) else { return }
        let before = snapshot(others.map(\.id))
        var n = 0
        for o in others {
            guard let i = index[o.id] else { continue }
            var a = photos[i].adj
            a.wbShift = ((refK - ImageStore.shared.asShotK(o.url)) / 10).rounded() * 10
            a.tint = ref.adj.tint
            if let l = Self.meanLinearLuma(o.url), l > 0.0005 {
                // Previews are the camera's rendering, so the difference between them is the exposure difference.
                a.exposure = min(3, max(-3, ((ref.adj.exposure + log2(refL / l)) * 20).rounded() / 20))
            }
            photos[i].adj = a
            n += 1
        }
        saveEditsSoon(others.map(\.id))
        record(tr("Выравнивание по эталону: \(n)"), before: before)
        flash(tr("Экспозиция и баланс выровнены по текущему кадру: \(n)"))
    }

    /// Mean linear luminance of the preview (sRGB decoded with gamma 2.2), at 64 px.
    nonisolated static func meanLinearLuma(_ url: URL) -> Double? {
        guard let img = ImageStore.shared.preview(url) else { return nil }
        let w = 64, h = max(1, Int(Double(w) * Double(img.height) / Double(img.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let l = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
            sum += pow(l, 2.2)
        }
        return sum / Double(w * h)
    }
}
