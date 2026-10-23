import AppKit
import SwiftUI

/// Zoomable frame view: "Fit", 25–800%, pinch, ⌘+scroll wheel, drag to pan, navigator.
/// When zoomed in, only the visible part of the RAW is developed at full resolution, with the current edits.
struct ZoomableLoupe: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @State private var detail: CGImage?
    @State private var detailRegion: CGRect = .zero
    @State private var detailFor: URL?
    @State private var dragStart: CGPoint?
    @State private var rendering = false
    @State private var before: CGImage?
    @State private var beforeRegion: CGRect = .zero
    @State private var beforeFor: URL?

    private var split: Bool { lib.splitCompare && !photo.adj.isIdentity && !lib.showOriginal }

    private var adj: Adjustments { lib.showOriginal ? Adjustments() : photo.adj }

    var body: some View {
        GeometryReader { geo in
            let pane = geo.size
            let px = pixelSize
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            // "Fit" as a fraction of 100%; floored, since a tiny pane would make it negative ("−%" in the bar).
            let fit = min(max(pane.width - 40, 1) / max(px.width, 1), max(pane.height - 40, 1) / max(px.height, 1)) * backing
            ZStack {
                LoupeAnchor()
                if let z = lib.loupeZoom {
                    zoomed(pane: pane, px: px, zoom: z, backing: backing)
                } else {
                    fitted
                        .padding(20)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                            // Double-click zooms to 100% at the click point.
                            let shown = CGSize(width: px.width * fit / backing, height: px.height * fit / backing)
                            let origin = CGPoint(x: (pane.width - shown.width) / 2, y: (pane.height - shown.height) / 2)
                            let p = CGPoint(x: (loc.x - origin.x) / shown.width, y: (loc.y - origin.y) / shown.height)
                            lib.setZoom(1, at: CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)))
                        }
                }
            }
            .gesture(MagnifyGesture()
                .onChanged { v in
                    let base = lib.loupeZoomBase ?? lib.fitZoom
                    lib.setZoomKeepingBase(base * v.magnification)
                }
                .onEnded { _ in lib.loupeZoomBase = lib.loupeZoom })
            .onAppear { lib.fitZoom = fit }
            .onChange(of: fit) { _, f in lib.fitZoom = f }
            .onChange(of: photo.id) { _, _ in detail = nil }
        }
        .clipped()
        .photoContextMenu(photo)
    }

    /// Unzoomed frame: the camera JPEG, or the developed RAW when there are edits.
    @ViewBuilder private var fitted: some View {
        if lib.splitCompare && !photo.adj.isIdentity {
            SplitFit(photo: photo, aspect: pixelSize.width / pixelSize.height)
        } else if photo.adj.isIdentity || lib.showOriginal {
            SharpPreview(photo: photo)
        } else {
            EditedImage(photo: photo, adj: photo.adj)
        }
    }

    /// Frame size in pixels after the in-camera crop and rotation.
    private var pixelSize: CGSize {
        let s = lib.pixelSize(photo)
        return CGSize(width: s.width * photo.adj.cropW, height: s.height * photo.adj.cropH)
    }

    // MARK: - Zoomed frame

    private func zoomed(pane: CGSize, px: CGSize, zoom: CGFloat, backing: CGFloat) -> some View {
        let shown = CGSize(width: px.width * zoom / backing, height: px.height * zoom / backing)
        let c = clampCenter(lib.loupeCenter, shown: shown, pane: pane)
        let visible = CGRect(x: c.x - min(1, pane.width / shown.width) / 2, y: c.y - min(1, pane.height / shown.height) / 2,
                             width: min(1, pane.width / shown.width), height: min(1, pane.height / shown.height))
        let outPx = CGSize(width: (visible.width * shown.width * backing).rounded(), height: (visible.height * shown.height * backing).rounded())
        func place(_ r: CGRect) -> CGRect {   // frame fractions → screen points
            CGRect(x: pane.width / 2 + (r.minX - c.x) * shown.width, y: pane.height / 2 + (r.minY - c.y) * shown.height,
                   width: r.width * shown.width, height: r.height * shown.height)
        }
        let whole = place(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ZStack(alignment: .topLeading) {
            // Backdrop: the whole frame at low resolution, shown immediately (while the sharp tile is being rendered).
            if let low = Renderer.shared.cachedLowRes(photo.url, adj) ?? ImageStore.shared.cachedPreview(photo.url) {
                Image(decorative: low, scale: 1).resizable().interpolation(.medium)
                    .frame(width: whole.width, height: whole.height)
                    .offset(x: whole.minX, y: whole.minY)
            }
            if let detail, detailFor == photo.url {
                let r = place(detailRegion)
                Image(decorative: detail, scale: 1).resizable().interpolation(zoom >= 1 ? .none : .high)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            if split, let before, beforeFor == photo.url {
                let r = place(beforeRegion)
                Image(decorative: before, scale: 1).resizable().interpolation(zoom >= 1 ? .none : .high)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .mask(alignment: .topLeading) { Rectangle().frame(width: pane.width * lib.splitPos, height: pane.height) }
            }
            if split { SplitHandle(width: pane.width, height: pane.height) }
        }
        .frame(width: pane.width, height: pane.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? lib.loupeCenter
                if dragStart == nil { dragStart = start }
                lib.loupeCenter = CGPoint(x: start.x - v.translation.width / shown.width, y: start.y - v.translation.height / shown.height)
            }
            .onEnded { _ in
                dragStart = nil
                lib.loupeCenter = clampCenter(lib.loupeCenter, shown: shown, pane: pane)
            })
        .onTapGesture(count: 2) { lib.setZoom(nil) }
        .overlay(alignment: .topTrailing) { Navigator(photo: photo, visible: visible, adj: adj).padding(12) }
        .overlay(alignment: .topLeading) {
            if rendering {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(tr("Детализация…")).font(.caption) }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(12)
            }
        }
        .onAppear { lib.loupeDisplay = shown }
        .onChange(of: shown) { _, s in lib.loupeDisplay = s }
        .task(id: split ? RegionKey(url: photo.url, adj: photo.adj.beforeVersion, region: visible, pixels: outPx) : nil) {
            guard split else { return }
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            if let img = await Renderer.shared.renderRegion(photo.url, photo.adj.beforeVersion, region: visible, pixels: outPx, channel: "region-before") {
                before = img
                beforeRegion = visible
                beforeFor = photo.url
            }
        }
        .task(id: RegionKey(url: photo.url, adj: adj, region: visible, pixels: outPx)) {
            try? await Task.sleep(for: .milliseconds(25))   // don't re-render on every step while dragging
            guard !Task.isCancelled else { return }
            rendering = true
            if let img = await Renderer.shared.renderRegion(photo.url, adj, region: visible, pixels: outPx) {
                detail = img
                detailRegion = visible
                detailFor = photo.url
            }
            rendering = false
        }
    }

    /// Keeps the center from pushing the frame past the edge.
    private func clampCenter(_ c: CGPoint, shown: CGSize, pane: CGSize) -> CGPoint {
        func axis(_ v: CGFloat, _ img: CGFloat, _ view: CGFloat) -> CGFloat {
            guard img > view else { return 0.5 }
            let half = view / 2 / img
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(c.x, shown.width, pane.width), y: axis(c.y, shown.height, pane.height))
    }
}

struct RegionKey: Hashable {
    let url: URL
    let adj: Adjustments
    let region: CGRect
    let pixels: CGSize
    /// Read in body, so a LUT replaced under the same name re-renders the tile (like ThumbKey).
    var luts = LUTRevision.shared.value

    func hash(into h: inout Hasher) {
        h.combine(url); h.combine(adj); h.combine(luts)
        for v in [region.minX, region.minY, region.width, region.height] { h.combine((v * 2000).rounded()) }
        h.combine(pixels.width); h.combine(pixels.height)
    }

    // Field by field on the same rounding as the hash: equal hashes of different keys must not count as equal.
    static func == (a: RegionKey, b: RegionKey) -> Bool {
        func q(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height].map { ($0 * 2000).rounded() } }
        return a.url == b.url && a.adj == b.adj && a.luts == b.luts && q(a.region) == q(b.region) && a.pixels == b.pixels
    }
}

/// Corner thumbnail with a box around the visible area; click or drag to jump there.
struct Navigator: View {
    let photo: Photo
    let visible: CGRect
    let adj: Adjustments
    @Environment(Library.self) private var lib

    var body: some View {
        if let img = Renderer.shared.cachedLowRes(photo.url, adj) ?? ImageStore.shared.cachedPreview(photo.url) {
            let w: CGFloat = 170, h = w * CGFloat(img.height) / CGFloat(img.width)
            ZStack(alignment: .topLeading) {
                Image(decorative: img, scale: 1).resizable().frame(width: w, height: h).opacity(0.85)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .background(Color.white.opacity(0.12))
                    .frame(width: max(6, visible.width * w), height: max(6, visible.height * h))
                    .offset(x: visible.minX * w, y: visible.minY * h)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                lib.loupeCenter = CGPoint(x: min(max(v.location.x / w, 0), 1), y: min(max(v.location.y / h, 0), 1))
            })
            .help(tr("Навигатор: кликните или тяните, чтобы перейти к месту кадра"))
        }
    }
}

/// Zoom bar below the frame. Narrower variants drop the less used levels, then the captions, so the bar
/// never asks for more than the column has.
struct ZoomBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(levels: [0.5, 1, 2], splitTitle: true)
            row(levels: [1], splitTitle: false)
            row(levels: nil, splitTitle: false)
        }
        .buttonStyle(.plain)
        .floatingBar()
    }

    /// `levels`: the fixed zoom steps after "Fit"; nil leaves out "Fit" too.
    private func row(levels: [CGFloat]?, splitTitle: Bool) -> some View {
        let z = lib.loupeZoom
        return HStack(spacing: 4) {
            Button { lib.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(z == nil).help(tr("Уменьшить (⌘−)"))
            Button { lib.splitCompare.toggle() } label: {
                Group {
                    if splitTitle { Label(tr("До/после"), systemImage: "rectangle.split.2x1") } else { Image(systemName: "rectangle.split.2x1") }
                }
                .font(.caption.weight(lib.splitCompare ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(lib.splitCompare ? Color.accentColor.opacity(0.35) : .clear))
            }
            .help(tr("Шторка «до / после» (Y): тяните линию по кадру"))
            if let levels {
                Divider().frame(height: 14)
                level(tr("Вписать"), nil, active: z == nil, help: tr("⌘0 или двойной клик"))
                ForEach(levels, id: \.self) { v in
                    level("\(Int(v * 100))%", v, active: z == v, help: v == 1 ? tr("⌘1 или Z") : "")
                }
            }
            Button { lib.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help(tr("Увеличить (⌘+)"))
            if levels == nil {
                // No room for the levels: the percentage itself opens them.
                Menu {
                    Button(tr("Вписать")) { lib.setZoom(nil, at: lib.loupeCenter) }
                    ForEach([0.5, 1, 2] as [CGFloat], id: \.self) { v in
                        Button("\(Int(v * 100))%") { lib.setZoom(v, at: lib.loupeCenter) }
                    }
                } label: { percent(z) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()
                .help(tr("Масштаб: вписать, 50%, 100%, 200%"))
            } else {
                percent(z)
            }
        }
    }

    private func percent(_ z: CGFloat?) -> some View {
        Text("\(Int(((z ?? lib.fitZoom) * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 44)
    }

    private func level(_ title: String, _ value: CGFloat?, active: Bool, help: String = "") -> some View {
        Button { lib.setZoom(value, at: lib.loupeCenter) } label: {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.accentColor.opacity(0.35) : .clear))
        }
        .help(help)
    }
}

/// Invisible anchor point that lets wheel/trackpad scrolling know the cursor is over the frame.
struct LoupeAnchor: NSViewRepresentable {
    @MainActor static weak var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = PassthroughView()
        LoupeAnchor.view = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { LoupeAnchor.view = v }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Scrolling over the frame: pans when zoomed in, zooms with ⌘ or ⌥.
@MainActor
enum ScrollZoom {
    static func handle(_ e: NSEvent, _ lib: Library) -> NSEvent? {
        guard lib.loupe, !lib.comparing, let v = LoupeAnchor.view, v.window == e.window,
              v.bounds.contains(v.convert(e.locationInWindow, from: nil)) else { return e }
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            let cur = lib.loupeZoom ?? lib.fitZoom
            lib.loupeZoomBase = cur
            lib.setZoomKeepingBase(cur * exp(e.scrollingDeltaY * k * 0.01))
            return nil
        }
        guard lib.loupeZoom != nil else { return e }
        lib.pan(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k)
        return nil
    }
}

/// Before/After split in "Fit" mode: "after" fills the frame, "before" shows to the left of the line.
struct SplitFit: View {
    let photo: Photo
    let aspect: CGFloat
    @Environment(Library.self) private var lib

    var body: some View {
        GeometryReader { geo in
            let box = geo.size
            let w = min(box.width, box.height * aspect), h = w / aspect
            let r = CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
            ZStack(alignment: .topLeading) {
                EditedImage(photo: photo, adj: photo.adj)
                    .frame(width: w, height: h).offset(x: r.minX, y: r.minY)
                EditedImage(photo: photo, adj: photo.adj.beforeVersion, channel: "loupe-before")
                    .frame(width: w, height: h).offset(x: r.minX, y: r.minY)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: r.minX + w * lib.splitPos, height: box.height)
                    }
                SplitHandle(width: w, height: h).offset(x: r.minX, y: r.minY)
            }
        }
    }
}

/// Split line with a handle and labels; drag to move it. Position is a fraction of the frame/window width.
struct SplitHandle: View {
    let width: CGFloat
    let height: CGFloat
    @Environment(Library.self) private var lib

    var body: some View {
        let x = width * lib.splitPos
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white).frame(width: 2, height: height).offset(x: x - 1)
            Circle().fill(Color.white).frame(width: 30, height: 30)
                .overlay(Image(systemName: "arrow.left.and.right").font(.caption.weight(.bold)).foregroundStyle(.black))
                .offset(x: x - 15, y: height / 2 - 15)
            tag(tr("ДО")).offset(x: max(8, x - 50), y: 10).opacity(lib.splitPos > 0.08 ? 1 : 0)
            tag(tr("ПОСЛЕ")).offset(x: min(width - 70, x + 10), y: 10).opacity(lib.splitPos < 0.92 ? 1 : 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle().offset(x: x - 20).size(width: 40, height: height))
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            lib.splitPos = min(max(v.location.x / width, 0), 1)
        })
        .help(tr("Тяните, чтобы сравнить"))
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }
}
