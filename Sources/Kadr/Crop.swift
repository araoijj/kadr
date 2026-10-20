import AppKit
import SwiftUI

/// Форматы кадрирования, в том числе под Instagram.
struct CropFormat: Identifiable, Hashable {
    let id: String
    let title: String
    let hint: String
    let ratio: Double?        // ширина / высота; nil — свободно, 0 — как у исходника

    static let all: [CropFormat] = [
        .init(id: "free", title: "Свободно", hint: "", ratio: nil),
        .init(id: "original", title: "Исходный", hint: "как снято", ratio: 0),
        .init(id: "4:5", title: "4:5", hint: "пост Instagram", ratio: 4.0 / 5),
        .init(id: "1:1", title: "1:1", hint: "квадрат", ratio: 1),
        .init(id: "9:16", title: "9:16", hint: "сторис, Reels", ratio: 9.0 / 16),
        .init(id: "1.91:1", title: "1.91:1", hint: "пост горизонт.", ratio: 1.91),
        .init(id: "3:2", title: "3:2", hint: "", ratio: 3.0 / 2),
        .init(id: "2:3", title: "2:3", hint: "", ratio: 2.0 / 3),
        .init(id: "4:3", title: "4:3", hint: "", ratio: 4.0 / 3),
        .init(id: "16:9", title: "16:9", hint: "видео, обложка", ratio: 16.0 / 9),
    ]

    static func byID(_ id: String?) -> CropFormat? { all.first { $0.id == id } }
}

extension Library {
    /// Пропорции кадра в пикселях (после кадрирования камеры, до своего кадрирования).
    func imageAspect(_ p: Photo) -> Double {
        let s = pixelSize(p)
        return Double(s.width / s.height)
    }

    /// Размер кадра в пикселях RAW: ориентация и кадрирование камеры — по превью, размеры — из EXIF.
    /// Пропорции превью неточные (1616×1080 ≠ 3:2), поэтому берём только их «форму».
    func pixelSize(_ p: Photo) -> CGSize {
        let ex = p.exif.width != nil ? p.exif : ImageStore.shared.exif(p.url)
        let prev = ImageStore.shared.cachedPreview(p.url) ?? ImageStore.shared.preview(p.url)
        let pa = prev.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
        let long = CGFloat(max(ex.width ?? 0, ex.height ?? 0)), short = CGFloat(min(ex.width ?? 0, ex.height ?? 0))
        guard long > 0, short > 0 else { return CGSize(width: 1000 * pa, height: 1000) }
        var w = pa >= 1 ? long : short, h = pa >= 1 ? short : long
        // Камера кадрировала (например, 4:3) — пропорции превью заметно другие.
        if abs(w / h - pa) / pa > 0.02 { if pa < w / h { w = h * pa } else { h = w / pa } }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// Самая большая рамка нужного формата по центру кадра.
    func centeredCrop(ratio: Double, imageAspect a: Double) -> CGRect {
        // в долях: w/h (доли) = ratio / a
        let k = ratio / a
        return k >= 1 ? CGRect(x: 0, y: (1 - 1 / k) / 2, width: 1, height: 1 / k)
                      : CGRect(x: (1 - k) / 2, y: 0, width: k, height: 1)
    }

    func applyCropFormat(_ f: CropFormat) {
        guard let p = current else { return }
        var a = p.adj
        a.cropAspect = f.id
        if let r = f.ratio {
            let ratio = r == 0 ? imageAspect(p) : r
            a.cropRect = centeredCrop(ratio: ratio, imageAspect: imageAspect(p))
        }
        setAdjustments(a)
    }

    /// Поменять ориентацию формата (4:5 ↔ 5:4).
    func flipCropOrientation() {
        guard let p = current else { return }
        let a0 = imageAspect(p)
        let current = (p.adj.cropW * a0) / p.adj.cropH
        var a = p.adj
        a.cropRect = centeredCrop(ratio: 1 / current, imageAspect: a0)
        setAdjustments(a)
    }

    /// То же кадрирование — на все выделенные (например, 4:5 на всю серию для Instagram).
    func applyCropToTargets() {
        guard let src = current?.adj else { return }
        let before = snapshot(targets.map(\.id))
        defer { record("Кадрирование на \(targets.count) кадров", before: before) }
        for t in targets where t.id != currentID {
            guard let i = photos.firstIndex(where: { $0.id == t.id }) else { continue }
            var a = photos[i].adj
            a.angle = src.angle
            a.cropAspect = src.cropAspect
            if let f = CropFormat.byID(src.cropAspect), let r = f.ratio {
                let ia = imageAspect(photos[i])
                a.cropRect = centeredCrop(ratio: r == 0 ? ia : r, imageAspect: ia)
            } else {
                a.cropRect = src.cropRect
            }
            photos[i].adj = a
            setAdjustmentsRaw(i, a)
        }
        flash("Кадрирование применено к \(targets.count) кадрам")
    }
}

/// Редактор рамки поверх кадра: тянуть за углы и края, двигать внутри; сетка третей.
struct CropEditor: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @State private var rect: CGRect?          // рамка во время перетаскивания (доли кадра)
    @State private var start: CGRect = .zero
    @State private var handle: Handle = .move

    enum Handle { case move, tl, tr, bl, br, top, bottom, left, right }

    var body: some View {
        GeometryReader { geo in
            let pane = geo.size
            let a = lib.imageAspect(photo)
            // Снизу — место под панель форматов, чтобы она не закрывала нижние ручки рамки.
            let barSpace: CGFloat = 120
            let fit = min((pane.width - 60) / CGFloat(a), pane.height - 40 - barSpace)
            let shown = CGSize(width: fit * CGFloat(a), height: fit)
            let origin = CGPoint(x: (pane.width - shown.width) / 2, y: 20 + (pane.height - 40 - barSpace - shown.height) / 2)
            let r = rect ?? photo.adj.cropRect
            let box = CGRect(x: origin.x + r.minX * shown.width, y: origin.y + r.minY * shown.height,
                             width: r.width * shown.width, height: r.height * shown.height)
            ZStack(alignment: .topLeading) {
                // Кадр без кадрирования (но с выравниванием и обработкой).
                EditedImage(photo: photo, adj: {
                    var x = photo.adj; x.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); return x
                }())
                .frame(width: shown.width, height: shown.height)
                .offset(x: origin.x, y: origin.y)

                // Затемнение вне рамки.
                Path { p in
                    p.addRect(CGRect(origin: origin, size: shown))
                    p.addRect(box)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

                // Сетка третей и рамка.
                Path { p in
                    for i in 1...2 {
                        let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                        p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                ForEach(Array([CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                               CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)].enumerated()), id: \.offset) { _, pt in
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 14, height: 14).offset(x: pt.x - 7, y: pt.y - 7)
                }
                // Размер результата.
                Text(sizeLabel(r, a))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .offset(x: box.minX + 6, y: box.minY + 6)
            }
            .frame(width: pane.width, height: pane.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if rect == nil {
                        start = photo.adj.cropRect
                        handle = hit(v.startLocation, box)
                        rect = start
                    }
                    rect = update(start, handle, dx: v.translation.width / shown.width, dy: v.translation.height / shown.height, imageAspect: a)
                }
                .onEnded { _ in
                    if let r = rect {
                        var adj = photo.adj
                        adj.cropRect = r
                        lib.setAdjustments(adj)
                    }
                    rect = nil
                })
        }
    }

    private func sizeLabel(_ r: CGRect, _ a: Double) -> String {
        let ex = photo.exif
        let long = Double(max(ex.width ?? 0, ex.height ?? 0)), short = Double(min(ex.width ?? 0, ex.height ?? 0))
        guard long > 0 else { return "" }
        var w = a >= 1 ? long : short, h = a >= 1 ? short : long
        if abs(w / h - a) / a > 0.02 { if a < w / h { w = h * a } else { h = w / a } }
        return "\(Int(w * r.width)) × \(Int(h * r.height))"
    }

    private func hit(_ p: CGPoint, _ b: CGRect) -> Handle {
        let t: CGFloat = 18
        let nearL = abs(p.x - b.minX) < t, nearR = abs(p.x - b.maxX) < t
        let nearT = abs(p.y - b.minY) < t, nearB = abs(p.y - b.maxY) < t
        if nearT && nearL { return .tl }
        if nearT && nearR { return .tr }
        if nearB && nearL { return .bl }
        if nearB && nearR { return .br }
        if nearT && p.x > b.minX && p.x < b.maxX { return .top }
        if nearB && p.x > b.minX && p.x < b.maxX { return .bottom }
        if nearL && p.y > b.minY && p.y < b.maxY { return .left }
        if nearR && p.y > b.minY && p.y < b.maxY { return .right }
        return .move
    }

    /// Новая рамка; при выбранном формате пропорции держатся.
    private func update(_ s: CGRect, _ h: Handle, dx: CGFloat, dy: CGFloat, imageAspect a: Double) -> CGRect {
        let minSide: CGFloat = 0.05
        if h == .move {
            let x = min(max(s.minX + dx, 0), 1 - s.width), y = min(max(s.minY + dy, 0), 1 - s.height)
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        var l = s.minX, r = s.maxX, t = s.minY, b = s.maxY
        switch h {
        case .tl: l += dx; t += dy
        case .tr: r += dx; t += dy
        case .bl: l += dx; b += dy
        case .br: r += dx; b += dy
        case .top: t += dy
        case .bottom: b += dy
        case .left: l += dx
        case .right: r += dx
        case .move: break
        }
        l = max(0, min(l, r - minSide)); r = min(1, max(r, l + minSide))
        t = max(0, min(t, b - minSide)); b = min(1, max(b, t + minSide))
        var out = CGRect(x: l, y: t, width: r - l, height: b - t)
        // Фиксированный формат: высоту подгоняем под ширину (в пикселях — с учётом пропорций кадра).
        if let f = CropFormat.byID(photo.adj.cropAspect), let ratio = f.ratio {
            let want = CGFloat((ratio == 0 ? a : ratio) / a)          // w/h в долях
            var w = out.width, hh = w / want
            if [.top, .bottom].contains(h) { hh = out.height; w = hh * want }
            if hh > 1 { hh = 1; w = hh * want }
            if w > 1 { w = 1; hh = w / want }
            let anchorRight = [.tl, .bl, .left].contains(h), anchorBottom = [.tl, .tr, .top].contains(h)
            let x = anchorRight ? s.maxX - w : s.minX
            let y = anchorBottom ? s.maxY - hh : s.minY
            out = CGRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - hh), width: w, height: hh)
        }
        return out
    }
}

/// Панель кадрирования под кадром: форматы, поворот, готово/отмена.
struct CropBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let adj = lib.current?.adj ?? Adjustments()
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(CropFormat.all) { f in
                    Button { lib.applyCropFormat(f) } label: {
                        VStack(spacing: 0) {
                            Text(f.title).font(.caption.weight(.semibold))
                            if !f.hint.isEmpty { Text(f.hint).font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill((adj.cropAspect ?? "free") == f.id ? Color.accentColor.opacity(0.4) : .white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
                Button { lib.flipCropOrientation() } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.plain).help("Повернуть рамку: вертикальная ↔ горизонтальная")
            }
            HStack(spacing: 10) {
                Image(systemName: "level").foregroundStyle(.secondary)
                Text("Горизонт").font(.caption)
                Slider(value: Binding(get: { adj.angle }, set: { v in
                    guard var a = lib.current?.adj else { return }
                    a.angle = (v * 10).rounded() / 10
                    lib.setAdjustments(a)
                }), in: -15...15)
                .frame(width: 220)
                Text(String(format: "%+.1f°", adj.angle)).font(.caption.monospacedDigit()).frame(width: 46)
                Divider().frame(height: 16)
                Button("Сбросить") { lib.resetCrop() }
                if lib.multiSelected { Button("На все выделенные") { lib.applyCropToTargets() } }
                Button("Отмена") { lib.cancelCrop() }
                Button("Готово") { lib.finishCrop() }.buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
    }
}
