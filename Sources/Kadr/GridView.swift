import AppKit
import SwiftUI

struct GridView: View {
    @Environment(Library.self) private var lib
    private let spacing: CGFloat = 10
    private let pad: CGFloat = 16

    // Marquee selection: preview frames and the rectangle in grid coordinates.
    @State private var frames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<URL> = []

    var body: some View {
        let sections = lib.sections
        let list = sections.flatMap(\.photos)
        VStack(spacing: 0) {
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
                .background(ClickAnchor())
            }
            .onChange(of: geo.size.width, initial: true) { _, w in updateColumns(w) }
            .onChange(of: lib.thumbSize) { _, _ in updateColumns(geo.size.width) }
        }
        // Over the grid, not above it: a card in the column's flow would set the column's min height and width.
        .overlay(alignment: .top) { if lib.culling { ToolHint(id: "cull") } }
        }
        .overlay {
            if list.isEmpty && !lib.photos.isEmpty {
                // Empty on purpose (everything in a burst rejected, rejects moved away): the way out is in sight.
                ContentUnavailableView {
                    Label(lib.inSeries ? tr("В этой серии не осталось кадров") : tr("Ничего нет"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(lib.inSeries ? tr("Все кадры серии в браке или перенесены.") : tr("В фильтре «\(lib.filter.title)» пока нет снимков"))
                } actions: {
                    if lib.inSeries {
                        Button(tr("Назад ко всем кадрам (Esc)")) { lib.leaveSeries() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(tr("Показать все кадры")) { lib.showAllPhotos() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    /// Drag with the mouse to select every preview the marquee touches. With ⌘ or ⇧ they're added to the current selection.
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
    @Environment(Library.self) private var lib
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
                if photo.seriesID != nil {
                    // Click: the whole burst on screen (or back out of it); hover shows it's a button.
                    SeriesBadge(photo: photo)
                }
                if photo.duplicateOf != nil {
                    Badge(text: tr("Дубль"), icon: "doc.on.doc", tint: .orange)
                }
                if lib.aiOn, !photo.rejected {
                    let v = lib.verdict(photo)
                    if lib.culling {
                        // The culling layer: every reason as its icon (the name on hover) — a tile has no room
                        // for words; "Дубль" already has its badge above.
                        ForEach(v.reasons.filter { $0 != .duplicate }) { r in
                            Image(systemName: r.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(r.isDefect ? .orange : .yellow)
                                .padding(4)
                                .background(.black.opacity(0.55), in: Circle())
                                .help(r.title + "\n" + lib.explain(r, photo))
                        }
                    } else if v.suspect {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(4)
                            .background(.black.opacity(0.55), in: Circle())
                            .help(v.reasons.filter(\.isDefect).map(\.title).joined(separator: ", "))
                    }
                }
                if !photo.adj.isIdentity {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .help(tr("Есть обработка"))
                }
                Spacer()
                if photo.rejected {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Theme.reject)
                } else if lib.culling, lib.aiOn, photo.cull != nil {
                    Text("\(lib.verdict(photo).score)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .help(tr("Техника и эстетика кадра, 0–100. Подсказка, а не приговор."))
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
            .lineLimit(1).fixedSize()   // never wrapped letter by letter when the tile is crowded
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.8), in: Capsule())   // solid enough to read over a bright photo
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
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
    /// Read in body, so a LUT replaced under the same name re-renders the view.
    var luts = LUTRevision.shared.value
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

/// Chips for active extra filters above the grid, showing why not all frames are visible.

/// The "Серия" / "Лучший" badge on a preview: a button that shows the whole burst, or leaves it.
struct SeriesBadge: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @State private var hover = false

    var body: some View {
        let inside = lib.inSeries && lib.filter == .series(photo.seriesID ?? -1)
        let n = lib.series(of: photo).count
        Button {
            if inside { lib.leaveSeries() } else { lib.showSeries(of: photo) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: inside ? "arrow.uturn.backward" : photo.isBestInSeries ? "sparkles" : "square.stack.3d.up")
                Text(inside ? tr("Все кадры") : photo.isBestInSeries ? tr("Лучший") : tr("Серия"))
                if !inside { Text("\(n)").monospacedDigit().opacity(0.8) }
            }
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1).fixedSize()   // a crowded tile wrapped «Серия» letter by letter
            .foregroundStyle(photo.isBestInSeries && !inside ? Theme.star : .white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            // Solid, with an edge: a light photo under a see-through capsule hid the badge.
            .background(.black.opacity(hover ? 0.9 : 0.8), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hover ? 0.5 : 0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(inside ? tr("Назад ко всем кадрам (Esc)") : tr("Показать все \(n) кадров серии; правый клик по кадру — выделить или сравнить серию"))
    }
}
