import AppKit
import SwiftUI

/// Просмотр кадра с масштабом: «вписать», 25–800%, щипок, ⌘+колёсико, перетаскивание, навигатор.
/// При увеличении проявляется только видимый кусок RAW в полном разрешении — с текущей обработкой.
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
            let fit = min((pane.width - 40) / px.width, (pane.height - 40) / px.height) * backing   // «вписать» в долях 100%
            ZStack {
                LoupeAnchor()
                if let z = lib.loupeZoom {
                    zoomed(pane: pane, px: px, zoom: z, backing: backing)
                } else {
                    fitted
                        .padding(20)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                            // Двойной клик — 100% в точку клика.
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

    /// Кадр без увеличения: JPEG камеры, а при правках — проявленный RAW.
    @ViewBuilder private var fitted: some View {
        if lib.splitCompare && !photo.adj.isIdentity {
            SplitFit(photo: photo, aspect: pixelSize.width / pixelSize.height)
        } else if photo.adj.isIdentity || lib.showOriginal {
            PreviewImage(photo: photo)
        } else {
            EditedImage(photo: photo, adj: photo.adj)
        }
    }

    /// Размер кадра в пикселях после кадрирования камеры и поворота.
    private var pixelSize: CGSize {
        let s = lib.pixelSize(photo)
        return CGSize(width: s.width * photo.adj.cropW, height: s.height * photo.adj.cropH)
    }

    // MARK: - Увеличенный кадр

    private func zoomed(pane: CGSize, px: CGSize, zoom: CGFloat, backing: CGFloat) -> some View {
        let shown = CGSize(width: px.width * zoom / backing, height: px.height * zoom / backing)
        let c = clampCenter(lib.loupeCenter, shown: shown, pane: pane)
        let visible = CGRect(x: c.x - min(1, pane.width / shown.width) / 2, y: c.y - min(1, pane.height / shown.height) / 2,
                             width: min(1, pane.width / shown.width), height: min(1, pane.height / shown.height))
        let outPx = CGSize(width: (visible.width * shown.width * backing).rounded(), height: (visible.height * shown.height * backing).rounded())
        func place(_ r: CGRect) -> CGRect {   // доли кадра → точки на экране
            CGRect(x: pane.width / 2 + (r.minX - c.x) * shown.width, y: pane.height / 2 + (r.minY - c.y) * shown.height,
                   width: r.width * shown.width, height: r.height * shown.height)
        }
        let whole = place(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ZStack(alignment: .topLeading) {
            // Подложка — весь кадр в низком разрешении, сразу (пока считается резкий кусок).
            if let low = Renderer.shared.cachedThumbnail(photo.url, adj, size: 1600) ?? ImageStore.shared.cachedPreview(photo.url) {
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
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Детализация…").font(.caption) }
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
            try? await Task.sleep(for: .milliseconds(25))   // при перетаскивании не считаем каждый шаг
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

    /// Центр не даёт увести кадр за край.
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

    func hash(into h: inout Hasher) {
        h.combine(url); h.combine(adj)
        for v in [region.minX, region.minY, region.width, region.height] { h.combine((v * 2000).rounded()) }
        h.combine(pixels.width); h.combine(pixels.height)
    }

    static func == (a: RegionKey, b: RegionKey) -> Bool { a.hashValue == b.hashValue }
}

/// Миниатюра в углу с рамкой видимой области; клик или перетаскивание — перейти туда.
struct Navigator: View {
    let photo: Photo
    let visible: CGRect
    let adj: Adjustments
    @Environment(Library.self) private var lib

    var body: some View {
        if let img = Renderer.shared.cachedThumbnail(photo.url, adj, size: 1600) ?? ImageStore.shared.cachedPreview(photo.url) {
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
            .help("Навигатор: кликните или тяните, чтобы перейти к месту кадра")
        }
    }
}

/// Панель масштаба под кадром.
struct ZoomBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let z = lib.loupeZoom
        HStack(spacing: 4) {
            Button { lib.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(z == nil).help("Уменьшить (⌘−)")
            Button { lib.splitCompare.toggle() } label: {
                Label("До/после", systemImage: "rectangle.split.2x1")
                    .font(.caption.weight(lib.splitCompare ? .semibold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(lib.splitCompare ? Color.accentColor.opacity(0.35) : .clear))
            }
            .help("Шторка «до / после» (Y): тяните линию по кадру")
            Divider().frame(height: 14)
            level("Вписать", nil, active: z == nil, help: "⌘0 или двойной клик")
            level("50%", 0.5, active: z == 0.5)
            level("100%", 1, active: z == 1, help: "⌘1 или Z")
            level("200%", 2, active: z == 2)
            Button { lib.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Увеличить (⌘+)")
            Text("\(Int(((z ?? lib.fitZoom) * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }

    private func level(_ title: String, _ value: CGFloat?, active: Bool, help: String = "") -> some View {
        Button { lib.setZoom(value, at: lib.loupeCenter) } label: {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(active ? Color.accentColor.opacity(0.35) : .clear))
        }
        .help(help)
    }
}

/// Невидимая точка привязки: по ней прокрутка колёсиком/трекпадом понимает, что курсор над кадром.
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

/// Прокрутка над кадром: при увеличении — сдвиг, с ⌘ или ⌥ — масштаб.
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

/// Шторка в режиме «вписать»: «после» целиком, «до» — слева от линии.
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

/// Линия шторки с ручкой и подписями; тянуть — двигать. Положение — доля ширины кадра/окна.
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
            tag("ДО").offset(x: max(8, x - 50), y: 10).opacity(lib.splitPos > 0.08 ? 1 : 0)
            tag("ПОСЛЕ").offset(x: min(width - 70, x + 10), y: 10).opacity(lib.splitPos < 0.92 ? 1 : 0)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle().offset(x: x - 20).size(width: 40, height: height))
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            lib.splitPos = min(max(v.location.x / width, 0), 1)
        })
        .help("Тяните, чтобы сравнить")
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }
}
