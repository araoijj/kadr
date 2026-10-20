import AppKit
import SwiftUI

struct GridView: View {
    @Environment(Library.self) private var lib
    private let spacing: CGFloat = 10
    private let pad: CGFloat = 16

    // Выделение рамкой: рамки превью и прямоугольник в координатах сетки.
    @State private var frames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<URL> = []

    var body: some View {
        let sections = lib.sections
        let list = sections.flatMap(\.photos)
        VStack(spacing: 0) {
        FilterChips()
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: lib.thumbSize), spacing: spacing)], spacing: spacing,
                              pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.title) { section in
                        Section {
                        ForEach(section.photos) { p in
                            Thumbnail(photo: p, selected: lib.isSelected(p), focused: p.id == lib.currentID && lib.multiSelected)
                                .id(p.id)
                                .onTapGesture(count: 2) { lib.select(p); lib.loupe = true }
                                .onTapGesture { lib.click(p) }
                                .photoContextMenu(p)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("grid")) } action: { frames[p.id] = $0 }
                                .onDisappear { frames[p.id] = nil }
                        }
                        } header: {
                            if !section.title.isEmpty { SectionHeader(title: section.title, count: section.photos.count) }
                        }
                        }
                    }
                    .padding(pad)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { lib.clearSelection() }
                    .gesture(marqueeGesture(list))
                    .overlay(alignment: .topLeading) {
                        if let r = marquee {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(.named("grid"))
                }
                .onChange(of: lib.currentID) { _, id in
                    guard let id, marquee == nil else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear { if let id = lib.currentID { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: geo.size.width, initial: true) { _, w in updateColumns(w) }
            .onChange(of: lib.thumbSize) { _, _ in updateColumns(geo.size.width) }
        }
        }
        .overlay {
            if list.isEmpty && !lib.photos.isEmpty {
                ContentUnavailableView("Ничего нет", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("В фильтре «\(lib.filter.title)» пока нет снимков"))
            }
        }
    }

    /// Тянем мышью — выделяются все превью, которые задела рамка. С ⌘ или ⇧ — добавляются к уже выделенным.
    private func marqueeGesture(_ list: [Photo]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
            .onChanged { v in
                if marquee == nil {
                    let mods = NSEvent.modifierFlags
                    marqueeBase = mods.contains(.command) || mods.contains(.shift)
                        ? Set(lib.targets.map(\.id)) : []
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                marquee = r
                let hit = list.map(\.id).filter { frames[$0]?.intersects(r) ?? false }
                lib.setMarquee(hit, adding: marqueeBase)
            }
            .onEnded { _ in
                marquee = nil
                marqueeBase = []
            }
    }

    private func updateColumns(_ width: CGFloat) {
        lib.columns = max(1, Int((width - pad * 2 + spacing) / (lib.thumbSize + spacing)))
    }
}

struct Thumbnail: View {
    let photo: Photo
    let selected: Bool
    var focused = false
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.16) : Theme.cell)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                        .opacity(photo.rejected ? 0.28 : 1)
                } else {
                    ProgressView().controlSize(.small)
                }
                badges
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: focused ? 4 : 2.5)
            )

            HStack(spacing: 6) {
                if let l = photo.label {
                    Circle().fill(l.color).frame(width: 8, height: 8)
                }
                Text(photo.name)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Stars(rating: photo.rating, size: 9)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .task(id: ThumbKey(url: photo.url, adj: photo.adj)) {
            if let img = await Renderer.thumb(for: photo) { image = img }
        }
    }

    private var badges: some View {
        VStack {
            HStack(spacing: 4) {
                if photo.isBestInSeries {
                    Badge(text: "Лучший", icon: "sparkles", tint: Theme.star)
                } else if photo.seriesID != nil {
                    Badge(text: "Серия", icon: "square.stack.3d.up", tint: .white.opacity(0.7))
                }
                if photo.duplicateOf != nil {
                    Badge(text: "Дубль", icon: "doc.on.doc", tint: .orange)
                }
                if !photo.adj.isIdentity {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .help("Есть обработка")
                }
                Spacer()
                if photo.rejected {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Theme.reject)
                }
            }
            Spacer()
        }
        .padding(8)
    }
}

struct Badge: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

struct Stars: View {
    let rating: Int
    var size: CGFloat = 11

    var body: some View {
        if rating > 0 {
            HStack(spacing: 1) {
                ForEach(0..<rating, id: \.self) { _ in
                    Image(systemName: "star.fill").font(.system(size: size))
                }
            }
            .foregroundStyle(Theme.star)
        }
    }
}

struct ThumbKey: Hashable {
    let url: URL
    let adj: Adjustments
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Theme.canvas.opacity(0.94))
    }
}

/// Плашки активных доп. фильтров над сеткой — видно, почему показаны не все кадры.
struct FilterChips: View {
    @Environment(Library.self) private var lib

    var body: some View {
        if lib.lensFilter != nil || lib.dayFilter != nil {
            HStack(spacing: 8) {
                if let l = lib.lensFilter {
                    chip(l, icon: "camera.aperture") { lib.lensFilter = nil }
                }
                if let d = lib.dayFilter {
                    chip(d.formatted(.dateTime.day().month(.wide).year()), icon: "calendar") { lib.dayFilter = nil }
                }
                Spacer()
                Text("Показано \(lib.visible.count) из \(lib.photos.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func chip(_ text: String, icon: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Снять фильтр")
    }
}
