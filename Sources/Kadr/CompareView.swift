import AppKit
import SwiftUI

/// Сравнение 2–4 кадров рядом. Зум и сдвиг общие: видно одно и то же место на всех кадрах.
struct CompareView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let photos = lib.comparePhotos
        VStack(spacing: 0) {
            toolbar(photos)
            GeometryReader { geo in
                let cols = photos.count <= 2 || geo.size.width > geo.size.height * 2.2 ? photos.count : 2
                let rows = Int(ceil(Double(photos.count) / Double(max(cols, 1))))
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

    private func toolbar(_ photos: [Photo]) -> some View {
        HStack(spacing: 14) {
            Label(tr("Сравнение · \(photos.count)"), systemImage: "rectangle.split.2x1")
                .font(.callout.weight(.semibold))
            Text(tr("← → — выбрать кадр · 1–5, X — оценка · Z — зум 100% · тянуть мышью — сдвиг · Esc — выход"))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                lib.rejectOthersInCompare()
            } label: {
                Label(tr("Оставить выбранный, остальные отклонить"), systemImage: "checkmark.seal")
            }
            .help(tr("Выбранный кадр остаётся, остальные помечаются отклонёнными (X)"))
            Button(tr("Готово")) { lib.stopCompare() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.25))
    }
}

struct ComparePane: View {
    let photo: Photo
    let focused: Bool
    @Environment(Library.self) private var lib
    @State private var image: CGImage?
    @State private var full: CGImage?
    @State private var dragStart: CGPoint?

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
                        .opacity(photo.rejected ? 0.45 : 1)
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : .white.opacity(0.08), lineWidth: focused ? 3 : 1))
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

    private var overlay: some View {
        VStack {
            HStack {
                Text(photo.name).font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                if photo.isBestInSeries { Badge(text: tr("Самый резкий"), icon: "sparkles", tint: Theme.star) }
                Spacer()
                if lib.compareZoom > 1.5 && full == nil { ProgressView().controlSize(.small) }
            }
            Spacer()
            HStack(spacing: 8) {
                if photo.rejected {
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

    /// Не даём увести кадр за край: центр не ближе половины окна к границе.
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
