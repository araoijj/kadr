import AppKit
import SwiftUI

/// Side-by-side comparison of 2–8 frames. Zoom and pan are shared, so the same spot is visible in every frame.
struct CompareView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let photos = lib.comparePhotos
        VStack(spacing: 0) {
            toolbar(photos)
            ToolHint(id: lib.tournamentActive ? "tournament" : "compare")
            GeometryReader { geo in
                // Up to 4 frames in one row on a wide window, otherwise two rows (3 or 4 per row for 5–8).
                let n = photos.count
                let rows = n <= 2 || (n <= 4 && geo.size.width > geo.size.height * 2.2) ? 1 : 2
                let cols = Int(ceil(Double(n) / Double(rows)))
                let w = (geo.size.width - CGFloat(cols - 1) * 6) / CGFloat(max(cols, 1))
                let h = (geo.size.height - CGFloat(rows - 1) * 6) / CGFloat(max(rows, 1))
                VStack(spacing: 6) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 6) {
                            ForEach(photos.indices.filter { $0 / cols == r }, id: \.self) { i in
                                ComparePane(photo: photos[i], focused: photos[i].id == lib.currentID)
                                    .frame(width: w, height: h)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func toolbar(_ photos: [Photo]) -> some View {
        if lib.tournamentActive { tournamentBar } else { compareBar(photos) }
    }

    private var tournamentBar: some View {
        Bar {
            ViewThatFits(in: .horizontal) {
                tournamentRow(hint: true)
                tournamentRow(hint: false)
            }
            .controlSize(.small)
        }
    }

    private func tournamentRow(hint: Bool) -> some View {
        HStack(spacing: 14) {
            Label(tr("Турнир · раунд \(lib.tournamentRound) из \(lib.tournamentAll.count - 1)"), systemImage: "trophy")
                .font(.callout.weight(.semibold)).fixedSize()
            if hint {
                Text(tr("← лучше левый · → лучше правый · победитель остаётся слева · Esc — выйти"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
            Button(tr("← Левый")) { lib.pickTournament(left: true) }
            Button(tr("Правый →")) { lib.pickTournament(left: false) }.buttonStyle(.borderedProminent)
            Button(tr("Выйти")) { lib.cancelTournament() }
            HintButton(id: "tournament")
        }
    }

    private func compareBar(_ photos: [Photo]) -> some View {
        Bar {
            ViewThatFits(in: .horizontal) {
                compareRow(photos, hint: true, long: true)
                compareRow(photos, hint: false, long: true)
                compareRow(photos, hint: false, long: false)
            }
            .controlSize(.small)
        }
    }

    private func compareRow(_ photos: [Photo], hint: Bool, long: Bool) -> some View {
        let marked = photos.filter { lib.compareKeep.contains($0.id) }.count
        let dropped = photos.filter { lib.compareReject.contains($0.id) }.count
        return HStack(spacing: 14) {
            Label(tr("Сравнение · \(photos.count)"), systemImage: "rectangle.split.2x1")
                .font(.callout.weight(.semibold)).fixedSize()
            if hint {
                Group {
                    if marked == 0 && dropped == 0 {
                        Text(tr("✓ (P) — оставить, ✗ (X) — в брак; Enter — применить"))
                    } else if dropped == 0 {
                        Text(tr("Отмечено ✓ \(marked) из \(photos.count) · Enter — оставить их, остальные в брак"))
                            .foregroundStyle(Theme.keep)
                    } else {
                        Text(tr("✓ \(marked) · ✗ \(dropped) · Enter — применить, остальные не трогать"))
                            .foregroundStyle(Theme.keep)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
            if marked + dropped > 0 {
                Button(tr("Снять отметки")) { lib.compareKeep = []; lib.compareReject = [] }
            }
            Button {
                lib.rejectOthersInCompare()
            } label: {
                if dropped > 0 {
                    Label(tr("Применить ✓ \(marked) · ✗ \(dropped)"), systemImage: "checkmark.seal")
                } else if long {
                    Label(marked > 0 ? tr("Оставить отмеченные (\(marked)), остальные отклонить") : tr("Оставить активный, остальные отклонить"),
                          systemImage: "checkmark.seal")
                } else {
                    Label(marked > 0 ? tr("Оставить (\(marked))") : tr("Оставить активный"), systemImage: "checkmark.seal")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(marked + dropped > 0 ? Theme.keep : .accentColor)
            .help(dropped > 0 ? tr("✓ получат ★ (если оценки не было), ✗ — в брак, остальные кадры не меняются. Отменить — ⌘Z")
                              : tr("Отмеченные кадры получат ★ (если оценки не было), остальные кадры сравнения — отклонены (X). Отменить — ⌘Z"))
            HintButton(id: "compare")
            Button(tr("Готово")) { lib.stopCompare() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

struct ComparePane: View {
    let photo: Photo
    let focused: Bool
    @Environment(Library.self) private var lib
    @State private var image: CGImage?
    @State private var full: CGImage?
    @State private var dragStart: CGPoint?

    private var marked: Bool { lib.compareKeep.contains(photo.id) }
    private var dropped: Bool { lib.compareReject.contains(photo.id) }
    private var markable: Bool { !lib.tournamentActive }

    var body: some View {
        GeometryReader { geo in
            let pane = geo.size
            ZStack {
                Theme.cell
                if let img = full ?? image {
                    let long = CGFloat(max(photo.exif.width ?? img.width, photo.exif.height ?? img.height))
                    let aspect = CGFloat(img.width) / CGFloat(img.height)
                    let iw = aspect >= 1 ? long : long * aspect, ih = aspect >= 1 ? long / aspect : long
                    let fit = min(pane.width / iw, pane.height / ih)
                    let s = fit * lib.compareZoom
                    let size = CGSize(width: iw * s, height: ih * s)
                    let c = clamp(lib.compareCenter, size: size, pane: pane)
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(lib.compareZoom > 1.5 ? .none : .high)
                        .frame(width: size.width, height: size.height)
                        .position(x: pane.width / 2 + (0.5 - c.x) * size.width, y: pane.height / 2 + (0.5 - c.y) * size.height)
                        .opacity((photo.rejected && !marked) || dropped ? 0.45 : 1)
                        .onAppear { lib.compareZoom100 = 1 / (fit * (NSScreen.main?.backingScaleFactor ?? 2)) }
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                guard lib.compareZoom > 1 else { return }
                                let start = dragStart ?? lib.compareCenter
                                if dragStart == nil { dragStart = start }
                                lib.compareCenter = CGPoint(x: start.x - v.translation.width / size.width,
                                                            y: start.y - v.translation.height / size.height)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                lib.compareCenter = clamp(lib.compareCenter, size: size, pane: pane)
                            })
                } else {
                    ProgressView()
                }
                overlay
                if markable { keepButton }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: marked || dropped || focused ? 3 : 1))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { lib.select(photo); lib.toggleCompareZoom() }
            .onTapGesture { lib.select(photo) }
            .gesture(MagnifyGesture().onChanged { v in
                lib.compareZoom = min(max(1, lib.compareZoomBase * v.magnification), 8)
            }.onEnded { _ in lib.compareZoomBase = lib.compareZoom })
            .photoContextMenu(photo)
        }
        .task(id: ThumbKey(url: photo.url, adj: photo.adj)) {
            let screen = NSScreen.main.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor } ?? 2560
            let url = photo.url
            if image == nil { image = await Task.detached(priority: .userInitiated) { ImageStore.shared.preview(url) }.value }
            if let img = await Renderer.shared.render(photo.url, photo.adj, maxSide: min(screen, 3200), channel: "cmp-\(photo.url.path)") {
                image = img
            }
        }
        .task(id: FullKey(url: photo.url, adj: photo.adj, need: lib.compareZoom > 1.5)) {
            guard lib.compareZoom > 1.5 else { full = nil; return }
            full = await Renderer.shared.render(photo.url, photo.adj, maxSide: nil, channel: "cmpfull-\(photo.url.path)")
        }
    }

    private var border: Color {
        if marked { return Theme.keep }
        if dropped { return Theme.reject }
        return focused ? Color.accentColor : .white.opacity(0.08)
    }

    /// Two marks in the corner: ✓ keep this frame, ✗ reject it. The keys are on the buttons.
    private var keepButton: some View {
        VStack {
            HStack(spacing: 6) {
                Spacer()
                markButton(on: marked, icon: "checkmark.circle.fill", off: "circle", text: tr("Оставить"), key: "P", tint: Theme.keep,
                           help: tr("Оставить этот кадр (P или пробел для активного)")) { lib.toggleCompareKeep(photo.id) }
                markButton(on: dropped, icon: "xmark.circle.fill", off: "circle", text: tr("Брак"), key: "X", tint: Theme.reject,
                           help: tr("В брак этот кадр (X для активного)")) { lib.toggleCompareReject(photo.id) }
            }
            Spacer()
        }
        .padding(8)
    }

    private func markButton(on: Bool, icon: String, off: String, text: String, key: String, tint: Color, help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? icon : off).font(.system(size: 18, weight: .semibold))
                Text(text).font(.caption.weight(.semibold))
                Text(key).font(.caption2.weight(.bold)).opacity(0.7)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
            .foregroundStyle(on ? tint : .white)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(on ? 0.7 : 0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? tint : .white.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var overlay: some View {
        VStack {
            HStack {
                Text(photo.name).font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(focused ? Color.accentColor.opacity(0.85) : .black.opacity(0.55), in: Capsule())
                if photo.isBestInSeries { Badge(text: tr("Самый резкий"), icon: "sparkles", tint: Theme.star) }
                Spacer()
                if lib.compareZoom > 1.5 && full == nil { ProgressView().controlSize(.small) }
                if markable { Color.clear.frame(width: 230, height: 1) }   // room for the mark buttons
            }
            Spacer()
            HStack(spacing: 8) {
                if marked {
                    Label(tr("Остаётся"), systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Theme.keep)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule())
                } else if dropped {
                    Label(tr("В брак"), systemImage: "xmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Theme.reject)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule())
                } else if markable && !lib.compareKeep.isEmpty && !lib.compareHasExplicitRejects {
                    Label(tr("Будет отклонён"), systemImage: "xmark.circle").font(.callout.weight(.medium)).foregroundStyle(Theme.reject)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.7), in: Capsule())
                } else if photo.rejected {
                    Label(tr("Отклонён"), systemImage: "xmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Theme.reject)
                }
                Stars(rating: photo.rating, size: 13)
                if let l = photo.label { Circle().fill(l.color).frame(width: 10, height: 10) }
                Spacer()
                if let s = photo.sharpness, let m = lib.photos.compactMap(\.sharpness).max(), m > 0 {
                    Text(tr("резкость \(Int(s / m * 100))%")).font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    /// Keeps the frame from being pushed past the edge: the center stays at least half a window from the border.
    private func clamp(_ c: CGPoint, size: CGSize, pane: CGSize) -> CGPoint {
        func axis(_ v: CGFloat, _ img: CGFloat, _ view: CGFloat) -> CGFloat {
            guard img > view else { return 0.5 }
            let half = view / 2 / img
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(c.x, size.width, pane.width), y: axis(c.y, size.height, pane.height))
    }
}

struct FullKey: Hashable {
    let url: URL
    let adj: Adjustments
    let need: Bool
}
