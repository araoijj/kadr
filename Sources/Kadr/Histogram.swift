import SwiftUI

/// Histogram of the R, G, B and luminance channels, as in Capture One.
struct HistogramData: Equatable {
    var r = [Double](repeating: 0, count: 256)
    var g = [Double](repeating: 0, count: 256)
    var b = [Double](repeating: 0, count: 256)
    var l = [Double](repeating: 0, count: 256)
    var clippedShadows = 0.0      // fraction of pixels with a channel ≤ 1
    var clippedHighlights = 0.0   // fraction with a channel ≥ 254

    static func compute(_ img: CGImage) -> HistogramData {
        let w = 320, h = max(1, Int(Double(w) * Double(img.height) / Double(img.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return HistogramData() }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var d = HistogramData()
        var lo = 0, hi = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            d.r[r] += 1; d.g[g] += 1; d.b[b] += 1
            d.l[min(255, (r * 54 + g * 183 + b * 19) >> 8)] += 1
            if max(r, g, b) >= 254 { hi += 1 }
            if min(r, g, b) <= 1 { lo += 1 }
        }
        let n = Double(w * h)
        d.clippedHighlights = Double(hi) / n
        d.clippedShadows = Double(lo) / n
        // Scale by the 99th percentile of the bins, so a single peak doesn't flatten everything else.
        let all = (d.r + d.g + d.b).sorted()
        let top = max(all[Int(Double(all.count - 1) * 0.99)], 1)
        // Smooth over 5 neighboring bins: otherwise an 8-bit preview produces a "comb".
        func norm(_ a: [Double]) -> [Double] {
            (0..<256).map { i in
                let r = max(0, i - 2)...min(255, i + 2)
                return min(1, r.reduce(0) { $0 + a[$1] } / Double(r.count) / top)
            }
        }
        d.r = norm(d.r); d.g = norm(d.g); d.b = norm(d.b); d.l = norm(d.l)
        return d
    }
}

struct HistogramView: View {
    let photo: Photo?
    @State private var data = HistogramData()

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                Canvas { ctx, size in
                    for x in [0.25, 0.5, 0.75] {   // grid at quarters
                        var p = Path(); p.move(to: CGPoint(x: size.width * x, y: 0)); p.addLine(to: CGPoint(x: size.width * x, y: size.height))
                        ctx.stroke(p, with: .color(.white.opacity(0.07)))
                    }
                    ctx.blendMode = .plusLighter
                    for (bins, color) in [(data.r, Color(red: 0.95, green: 0.25, blue: 0.25)),
                                          (data.g, Color(red: 0.25, green: 0.85, blue: 0.35)),
                                          (data.b, Color(red: 0.3, green: 0.45, blue: 1))] {
                        ctx.fill(area(bins, size), with: .color(color.opacity(0.55)))
                    }
                    ctx.blendMode = .normal
                    ctx.stroke(line(data.l, size), with: .color(.white.opacity(0.75)), lineWidth: 1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                HStack {
                    clipMark(data.clippedShadows, tr("Провалы в тенях"))
                    Spacer()
                    clipMark(data.clippedHighlights, tr("Пересветы"))
                }
                .padding(4)
            }
            .frame(height: 90)
            HStack {
                Text(data.clippedShadows > 0.005 ? tr("тени: \(pct(data.clippedShadows)) в ноль") : tr("тени в норме"))
                Spacer()
                Text(data.clippedHighlights > 0.005 ? tr("света: \(pct(data.clippedHighlights)) пересвет") : tr("света в норме"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .task(id: photo.map { ThumbKey(url: $0.url, adj: $0.adj) }) {
            guard let p = photo else { return }
            let url = p.url, adj = p.adj
            // A small render through the same develop chain as the loupe, so it matches what's on screen.
            let d = await Task.detached(priority: .utility) { () -> HistogramData? in
                await Renderer.shared.thumbnail(url, adj, size: 480).map(HistogramData.compute)
            }.value
            if let d { withAnimation(.easeOut(duration: 0.15)) { data = d } }
        }
    }

    private func pct(_ v: Double) -> String { v < 0.01 ? "<1%" : "\(Int((v * 100).rounded()))%" }

    private func clipMark(_ v: Double, _ help: String) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(v > 0.005 ? (help == tr("Пересветы") ? Color.white : Color.blue) : .white.opacity(0.15))
            .help("\(help): \(pct(v))")
    }

    private func area(_ bins: [Double], _ size: CGSize) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in bins.enumerated() {
            p.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        return p
    }

    private func line(_ bins: [Double], _ size: CGSize) -> Path {
        var p = Path()
        for (i, v) in bins.enumerated() {
            let pt = CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
