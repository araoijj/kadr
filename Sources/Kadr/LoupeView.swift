import AppKit
import SwiftUI

struct LoupeView: View {
    @Environment(Library.self) private var lib
    /// Height of the bar floating at the bottom (zoom, remove, crop with up to four rows), with its margin.
    @State private var bottomBar: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
            HStack(spacing: 0) {
            ZStack {
                if let p = lib.current {
                    if lib.cropMode { CropEditor(photo: p) } else if lib.removeMode { RemoveView(photo: p) } else { ZoomableLoupe(photo: p) }
                    overlay(p)
                } else if lib.loading {
                    // Space or Enter while the folder is read in the background (Library.open).
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(tr("Читаю папку…")).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let p = lib.current {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if p.seriesID != nil, !lib.cropMode, !lib.removeMode { seriesBadge(p) }
                            // AI edits in effect on this photo — always visible, so nothing works unnoticed.
                            if p.adj.aiDenoise > 0, Denoiser.shared.hasResult(p.url, p.adj.raw) {
                                Badge(text: tr("AI-шумоподавление \(Int(p.adj.aiDenoise))"), icon: "wand.and.stars", tint: Color.accentColor)
                            }
                            if !p.adj.removals.isEmpty {
                                Badge(text: tr("Убрано объектов: \(p.adj.removals.count)"), icon: "eraser", tint: Color.accentColor)
                            }
                        }
                        // The culling layer: decision, AI reasons with their fixes, the score.
                        if lib.culling, !lib.cropMode, !lib.removeMode { CullOverlay(photo: p).frame(maxWidth: .infinity) }
                        // Below the badges, so the hint never covers the burst badge or the culling layer;
                        // in a frame too low for it, left out rather than run over the bar at the bottom.
                        ViewThatFits(in: .vertical) {
                            toolHint.frame(maxWidth: .infinity)
                            Color.clear.frame(height: 0)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(16)
                    // Measured, not guessed: in a narrow column the crop bar grows to four rows.
                    .padding(.bottom, bottomBar + 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Over the photo, not the whole area: centred on the frame when the faces column is on the right.
            .overlay(alignment: .bottom) {
                Group {
                    if lib.cropMode { CropBar() } else if lib.removeMode { RemoveBar() } else { ZoomBar() }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
                // Only pads the badges above; the bar's own size never depends on it, so no layout loop.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBar = $0 }
            }
            // Faces at 100% while culling, if the frame still has room (narrow window: faces are viewed via zoom).
            if lib.culling, lib.aiOn, g.size.width >= 640, !lib.cropMode, !lib.removeMode,
               let p = lib.current, !(p.cull?.faces.isEmpty ?? true) {
                Divider()
                FacesColumn(photo: p).frame(width: 210)
            }
            }
            }
            .task(id: lib.currentID) {
                // Prepare the current frame's RAW in advance so the first style applies instantly.
                guard let u = lib.currentID, ImageStore.rawExtensions.contains(u.pathExtension.lowercased()) else { return }
                let raw = lib.current?.adj.raw ?? RawDevelop()
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
                Renderer.shared.prewarm(u, maxSide: min(screen, 3200), raw: raw)
            }
            Filmstrip()
        }
    }

    @ViewBuilder private var toolHint: some View {
        if lib.cropMode { ToolHint(id: "crop") }
        else if lib.removeMode { ToolHint(id: "remove") }
        else if lib.splitCompare, lib.current?.adj.isIdentity == false { ToolHint(id: "split") }
        else if lib.culling { ToolHint(id: "cull") }
    }

    /// The burst badge: a click shows the whole burst, the arrow opens the rest. It lives outside `overlay(_:)`,
    /// the info layer that doesn't take clicks, so the photo underneath keeps its gestures.
    @MainActor private func seriesBadge(_ p: Photo) -> some View {
            let s = lib.series(of: p)
            let pos = (s.firstIndex { $0.id == p.id } ?? 0) + 1
            // Click shows the burst; the arrow opens the rest of what you can do with it. Plain button and
            // menu, not a borderless menu: on macOS 26+ that one redraws its label and drops the capsule.
            return HStack(spacing: 4) {
                Button {
                    if lib.inSeries { lib.leaveSeries() } else { lib.showSeries(of: p) }
                } label: {
                    Badge(text: (lib.inSeries ? tr("Серия: \(pos) из \(s.count) · Esc — назад") : tr("Серия: \(pos) из \(s.count)"))
                          + (p.isBestInSeries ? tr(" · самый резкий") : ""),
                          icon: p.isBestInSeries ? "sparkles" : "square.stack.3d.up",
                          tint: p.isBestInSeries ? Theme.star : .white)
                }
                .buttonStyle(.plain)
                Menu {
                    Button(tr("Показать только эту серию (\(s.count))"), systemImage: "square.stack.3d.up") { lib.showSeries(of: p) }
                    Button(tr("Выделить всю серию (⌘⇧A)"), systemImage: "checkmark.square.fill") { lib.select(p); lib.selectSeries() }
                    Button(tr("Сравнить кадры серии (C)"), systemImage: "rectangle.split.2x1") { lib.select(p); lib.startCompare() }
                    Button(tr("Турнир: выбрать лучший (T)"), systemImage: "trophy") { lib.select(p); lib.startTournament() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .overlayCircle(edge: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .fixedSize()
            .help(tr("Клик — показать всю серию (Esc — назад); стрелка — выделить, сравнить, турнир"))
    }

    private func overlay(_ p: Photo) -> some View {
        VStack {
            Spacer()
            HStack {
                if p.rejected {
                    Label(tr("Отклонён"), systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.reject)
                }
                Stars(rating: p.rating, size: 16)
                if let l = p.label { Circle().fill(l.color).frame(width: 12, height: 12) }
                Spacer()
            }
        }
        .padding(16)
        .allowsHitTesting(false)
    }
}

struct PreviewImage: View {
    let photo: Photo
    @State private var image: CGImage?
    @State private var imageFor: URL?     // the view is reused while browsing: never show the last frame under the new name

    var body: some View {
        Group {
            // The new frame's preview if it is already cached (an NSCache lookup), else a neutral spinner.
            if let image = imageFor == photo.url ? image : ImageStore.shared.cachedPreview(photo.url) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(photo.rejected ? 0.45 : 1)
            } else {
                ProgressView()
            }
        }
        .task(id: photo.id) {
            let url = photo.url
            if let c = ImageStore.shared.cachedPreview(url) { image = c; imageFor = url } else {
                let shapeKnown = ImageStore.shared.previewAspect(url) != nil
                let ex = photo.exif
                let img = await Task.detached(priority: .userInitiated) {
                    if ex.width == nil { _ = ImageStore.shared.headerExif(url) }   // not indexed yet: views size from it
                    return ImageStore.shared.preview(url)
                }.value
                if !shapeKnown && img != nil { PreviewShapes.shared.learn(url, ex) }   // views sized from EXIF redraw
                guard !Task.isCancelled else { return }
                image = img; imageFor = url
            }
        }
    }
}

/// Unedited frame: the camera preview right away, then moments later a sharp RAW render sized to the screen.
/// Many cameras embed a 1616 px preview, which looks stretched and blurry on Retina.
/// The "Camera matching" profile keeps the camera JPEG colors. The next frame is developed in advance.
struct SharpPreview: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @State private var sharp: CGImage?
    @State private var sharpFor: URL?

    var body: some View {
        Group {
            if let sharp, sharpFor == photo.url {
                Image(decorative: sharp, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(photo.rejected ? 0.45 : 1)
            } else {
                PreviewImage(photo: photo)
            }
        }
        .task(id: photo.id) {
            let url = photo.url
            try? await Task.sleep(for: .milliseconds(120))   // fast browsing: don't develop every frame
            guard !Task.isCancelled else { return }
            let side = Self.screenSide
            // JPEG and other formats: just read at screen size (~50 ms).
            guard ImageStore.rawExtensions.contains(url.pathExtension.lowercased()) else {
                if let img = await Task.detached(priority: .userInitiated, operation: { ImageStore.shared.decoded(url, maxSide: side) }).value,
                   !Task.isCancelled { sharp = img; sharpFor = url }
                return
            }
            if let img = await Renderer.shared.render(url, .none, maxSide: side, channel: "sharp"), !Task.isCancelled {
                sharp = img; sharpFor = url
            }
            guard !Task.isCancelled else { return }
            // Neighbors in the queue, in advance, so they are already sharp when browsing: two ahead, one back.
            // Camera previews of the next few are read too, so even a fast flick shows a picture at once.
            let vis = lib.visible
            if let i = vis.firstIndex(where: { $0.id == photo.id }) {
                for j in [i + 1, i + 2, i - 1] where vis.indices.contains(j) && vis[j].adj.isIdentity
                    && ImageStore.rawExtensions.contains(vis[j].url.pathExtension.lowercased()) {
                    Renderer.shared.prewarm(vis[j].url, maxSide: side, raw: vis[j].adj.raw)
                }
                let ahead = vis[min(i + 1, vis.count)..<min(i + 6, vis.count)].map(\.url)
                Task.detached(priority: .utility) { for u in ahead { _ = ImageStore.shared.preview(u) } }
            }
        }
    }

    static var screenSide: CGFloat {
        min(NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560, 3200)
    }
}

/// Full RAW render, 1 image pixel = 1 screen pixel. Drag with the mouse / scroll.
/// Frame developed from RAW with edits. Shows the preview while the first render is in progress.
struct EditedImage: View {
    let photo: Photo
    let adj: Adjustments
    var channel = "loupe"          // "before" in the split view has its own channel so the two renders don't evict each other
    @State private var image: CGImage?
    @State private var shownFor: URL?
    @State private var exact = false      // the exact RAW is shown, not the fast preview-based version
    @State private var rendering: UUID?   // the render owning the badge: a cancelled one clears it only if no successor took it

    var body: some View {
        Group {
            // Until the task below resets it, `image` may still be the previous frame's.
            if let image, shownFor == photo.url {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .opacity(photo.rejected ? 0.45 : 1)
            } else {
                PreviewImage(photo: photo)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if rendering != nil && !exact {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Проявляю RAW…")).font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlayCapsule()
                .padding(10)
            }
        }
        .task(id: ThumbKey(url: photo.url, adj: adj)) {
            if shownFor != photo.url { image = nil; exact = false; shownFor = photo.url }
            let url = photo.url, a = adj
            let shapeKnown = ImageStore.shared.previewAspect(url) != nil
            // Until the exact RAW is ready, show the grid's thumbnail (same colors) or the edits over the camera preview (tens of ms).
            // A render already running on the serial queue isn't dropped when the frame changes: a cancelled task
            // must not put the previous frame under the new one's name.
            if !exact, let quick = await Task.detached(priority: .userInitiated, operation: {
                Renderer.shared.cachedThumbnail(url, a) ?? Renderer.shared.quick(url, a)
            }).value {
                guard !Task.isCancelled, shownFor == url else { return }
                image = quick
            }
            // Crop and retouch size the frame from EXIF until a preview is decoded: learn its camera crop now,
            // alongside the exact render rather than before it (and even if this frame is left meanwhile).
            if !shapeKnown {
                let ex = photo.exif
                Task.detached(priority: .utility) {
                    if ex.width == nil { _ = ImageStore.shared.headerExif(url) }
                    if ImageStore.shared.preview(url) != nil { await MainActor.run { PreviewShapes.shared.learn(url, ex) } }
                }
            }
            guard !Task.isCancelled else { return }
            let token = UUID()
            rendering = token
            defer { if rendering == token { rendering = nil } }
            let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
            if let img = await Renderer.shared.render(url, a, maxSide: min(screen, 3200), channel: channel),
               !Task.isCancelled, shownFor == url {
                image = img
                exact = true
            }
        }
    }
}

struct Filmstrip: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(lib.visible) { p in
                        StripCell(photo: p, selected: lib.isSelected(p))
                            .id(p.id)
                            .onTapGesture { lib.click(p) }
                            .photoContextMenu(p)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 92)
            .background(.black.opacity(0.25))
            .background(ClickAnchor())
            .onChange(of: lib.currentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct StripCell: View {
    let photo: Photo
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(photo.rejected ? 0.3 : 1)
            } else {
                Color.white.opacity(0.05)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .bottomLeading) {
            if photo.rating > 0 {
                Text("\(photo.rating)★")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.star)
                    .padding(3)
            }
        }
        .task(id: ThumbKey(url: photo.url, adj: photo.adj)) {
            if let img = await Renderer.thumb(for: photo) { image = img }
        }
    }
}
