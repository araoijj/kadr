import AppKit
import SwiftUI

struct LoupeView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let p = lib.current {
                    if lib.cropMode { CropEditor(photo: p) } else { ZoomableLoupe(photo: p) }
                    overlay(p)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if lib.cropMode { CropBar().padding(.bottom, 12) } else { ZoomBar().padding(.bottom, 12) }
            }
            .task(id: lib.currentID) {
                // Готовим RAW текущего кадра заранее, чтобы первый стиль применился сразу.
                guard let u = lib.currentID, ImageStore.rawExtensions.contains(u.pathExtension.lowercased()) else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
                Renderer.shared.prewarm(u, maxSide: min(screen, 3200))
            }
            Filmstrip()
        }
    }

    private func overlay(_ p: Photo) -> some View {
        VStack {
            HStack(alignment: .top) {
                if p.seriesID != nil {
                    let s = lib.series(of: p)
                    let pos = (s.firstIndex { $0.id == p.id } ?? 0) + 1
                    Badge(text: "Серия: \(pos) из \(s.count)" + (p.isBestInSeries ? " · самый резкий" : ""),
                          icon: p.isBestInSeries ? "sparkles" : "square.stack.3d.up",
                          tint: p.isBestInSeries ? Theme.star : .white.opacity(0.8))
                }
                Spacer()

            }
            Spacer()
            HStack {
                if p.rejected {
                    Label("Отклонён", systemImage: "xmark.circle.fill")
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

    var body: some View {
        Group {
            if let image {
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
            if let c = ImageStore.shared.cachedPreview(photo.url) { image = c } else {
                let url = photo.url
                image = await Task.detached(priority: .userInitiated) { ImageStore.shared.preview(url) }.value
            }
        }
    }
}

/// Полное проявление RAW, 1 пиксель снимка = 1 пиксель экрана. Тянуть мышью / скроллить.
/// Кадр, проявленный из RAW с обработкой. Пока считается первый раз — показываем превью.
struct EditedImage: View {
    let photo: Photo
    let adj: Adjustments
    var channel = "loupe"          // у «до» в шторке свой канал, чтобы два рендера не вытесняли друг друга
    @State private var image: CGImage?
    @State private var shownFor: URL?
    @State private var exact = false      // показан точный RAW, а не быстрый вариант по превью
    @State private var rendering = false

    var body: some View {
        Group {
            if let image {
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
            if rendering && !exact {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Проявляю RAW…").font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(10)
            }
        }
        .task(id: ThumbKey(url: photo.url, adj: adj)) {
            if shownFor != photo.url { image = nil; exact = false; shownFor = photo.url }
            let url = photo.url, a = adj
            // Пока точного RAW нет — сразу показываем обработку поверх превью камеры (десятки мс).
            if !exact, let quick = await Task.detached(priority: .userInitiated, operation: { Renderer.shared.thumbnail(url, a, size: 1600) }).value {
                image = quick
            }
            rendering = true
            let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
            if let img = await Renderer.shared.render(url, a, maxSide: min(screen, 3200), channel: channel) {
                image = img
                exact = true
            }
            rendering = false
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
