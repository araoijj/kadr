import AppKit
import SwiftUI

struct LoupeView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let p = lib.current {
                    if lib.zoom100 {
                        FullResView(photo: p, adj: lib.showOriginal ? .none : p.adj)
                    } else {
                        Group {
                            // Для отбора хватает встроенного превью; с обработкой — проявляем RAW.
                            if p.adj.isIdentity && lib.inspectorTab != .edit {
                                PreviewImage(photo: p)
                            } else {
                                EditedImage(photo: p, adj: lib.showOriginal ? .none : p.adj)
                            }
                        }
                            .padding(20)
                            .onTapGesture(count: 2) { lib.zoom100 = true }
                            .photoContextMenu(p)
                    }
                    overlay(p)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if lib.zoom100 {
                    Badge(text: "100%  ·  Esc — назад", icon: "plus.magnifyingglass", tint: .white.opacity(0.85))
                }
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
    @State private var image: CGImage?
    @State private var shownFor: URL?

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
        .task(id: ThumbKey(url: photo.url, adj: adj)) {
            if shownFor != photo.url { image = nil; shownFor = photo.url }
            let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
            if let img = await Renderer.shared.render(photo.url, adj, maxSide: min(screen, 3200)) { image = img }
        }
    }
}

struct FullResView: View {
    let photo: Photo
    var adj: Adjustments = .none
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: scale)
                        .interpolation(.none)
                }
                .defaultScrollAnchor(.center)
            } else if failed {
                ContentUnavailableView("Не удалось проявить RAW", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Проявляю RAW…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: ThumbKey(url: photo.url, adj: adj)) {
            failed = false
            let img = await Renderer.shared.render(photo.url, adj, maxSide: nil, channel: "full")
            if Task.isCancelled { return }
            if let img { image = img } else if image == nil { failed = true }
        }
        .onChange(of: photo.id) { _, _ in image = nil }
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
