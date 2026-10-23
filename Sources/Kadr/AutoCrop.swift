import CoreGraphics
import Foundation
import SwiftUI

/// Suggested crop: straighten by the horizon, then frame the subject on the rule of thirds.
/// It is only a suggestion — it opens in the crop editor, where the photographer accepts,
/// adjusts or skips it (unlike one-size-fits-all auto crops that land the same frame on every photo).
enum AutoCrop {
    struct Result: Equatable {
        var rect: CGRect      // crop in fractions of the straightened frame, top-down (like Adjustments.cropRect)
        var angle: Double     // degrees, same sign as Adjustments.angle
    }

    /// - Parameters:
    ///   - aspect: frame width / height in pixels.
    ///   - ratio: target crop width / height; nil keeps the frame's own proportions.
    ///   - tightest: the smallest crop side as a fraction of the frame — limits how much resolution is lost.
    static func suggest(_ c: CullData, aspect a: Double, ratio: Double?, tightest: Double = 0.8) -> Result? {
        // Horizon: small tilts only. Larger ones are usually intentional (Dutch angle) or a misdetection
        // (night scenes, interiors) — a 7.5° "horizon" in a dark bar is not worth rotating for.
        var angle = 0.0
        if let h = c.horizon, abs(h) >= 0.7, abs(h) <= 5 { angle = (h * 10).rounded() / 10 }

        // Subject: whole figures of people (never cut feet or hands), else head and shoulders, else the salient object.
        let faces = c.faces.filter { ($0.px ?? 0) >= 60 && ($0.quality ?? 0) >= 0.2 }
        let people = (c.people ?? []).map(\.rect).filter { $0.height >= 0.15 }
        let main = faces.max(by: { $0.w * $0.h < $1.w * $1.h })
        var subject: CGRect?
        var anchor: CGPoint?
        if let first = people.first {
            subject = people.dropFirst().reduce(first) { $0.union($1) }
            if let m = main { anchor = CGPoint(x: m.rect.midX, y: m.rect.minY + m.rect.height * 0.42) }
            else { anchor = CGPoint(x: subject!.midX, y: subject!.minY + subject!.height * 0.1) }
        } else if let m = main {
            let u = faces.dropFirst().reduce(faces[0].rect) { $0.union($1.rect) }
            subject = CGRect(x: u.minX - u.width * 0.3, y: u.minY - u.height * 0.35, width: u.width * 1.6, height: u.height * 2.6)
            anchor = CGPoint(x: m.rect.midX, y: m.rect.minY + m.rect.height * 0.42)
        } else if let s = c.subject?.rect, s.width < 0.9 || s.height < 0.9 {
            subject = s
            anchor = CGPoint(x: s.midX, y: s.midY)
        }

        let r = ratio ?? a
        let k = r / a
        let baseW = k >= 1 ? 1 : k, baseH = k >= 1 ? 1 / k : 1

        guard var s = subject, var p = anchor else {
            guard angle != 0 || ratio != nil else { return nil }
            return Result(rect: CGRect(x: (1 - baseW) / 2, y: (1 - baseH) / 2, width: baseW, height: baseH), angle: angle)
        }
        if angle != 0 {
            s = rotated(s, aspect: a, angle: angle)
            p = rotated(p, aspect: a, angle: angle)
        }
        s = s.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !s.isNull, s.width > 0, s.height > 0 else { return nil }
        // Breathing room around the subject; where the camera already cut it (touches the edge), no margin there.
        let mx = 0.06, my = 0.05
        let need0 = CGRect(x: s.minX <= 0.02 ? 0 : s.minX - mx, y: s.minY <= 0.02 ? 0 : s.minY - my,
                           width: 0, height: 0)
        let needMax = CGPoint(x: s.maxX >= 0.98 ? 1 : s.maxX + mx, y: s.maxY >= 0.98 ? 1 : s.maxY + my)
        let keep = CGRect(x: max(0, need0.minX), y: max(0, need0.minY),
                          width: min(1, needMax.x) - max(0, need0.minX), height: min(1, needMax.y) - max(0, need0.minY))

        // Size: tighten only as far as the subject allows; a crop of a few percent is not worth the pixels.
        var z = min(1, max(tightest, keep.width / baseW, keep.height / baseH))
        if z > 0.93 { z = 1 }
        let w = baseW * z, h = baseH * z

        // Position: the anchor to the nearest third (or centered when it already is); a face's eye line to the upper third.
        let tx: Double = p.x < 0.42 ? 1.0 / 3 : p.x > 0.58 ? 2.0 / 3 : 0.5
        let ty: Double = main != nil ? 1.0 / 3 : p.y < 0.45 ? 1.0 / 3 : p.y > 0.55 ? 2.0 / 3 : 0.5
        var x = p.x - tx * w, y = p.y - ty * h
        // Never cut the subject: shift the frame to include it, then keep it inside the photo.
        if keep.width <= w { x = min(max(x, keep.maxX - w), keep.minX) }
        if keep.height <= h { y = min(max(y, keep.maxY - h), keep.minY) }
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
        let rect = CGRect(x: x, y: y, width: w, height: h)

        // Worth suggesting only if the anchor moves noticeably closer to its third, the horizon changes or the format does.
        if angle == 0, ratio == nil {
            let before = hypot(p.x - (tx == 0.5 ? 0.5 : tx), p.y - ty)
            let after = hypot((p.x - x) / w - tx, (p.y - y) / h - ty)
            if z >= 1 || before - after < 0.04 { return nil }
        }
        return Result(rect: rect, angle: angle)
    }

    /// Maps a point of the original frame into the straightened one (rotation about the center plus the
    /// zoom that hides empty corners — the same transform as `EditPipeline.geometry`).
    static func rotated(_ q: CGPoint, aspect a: Double, angle: Double) -> CGPoint {
        let t = angle * .pi / 180
        let c = cos(t), sn = sin(t)
        let zoom = max((a * abs(c) + abs(sn)) / a, a * abs(sn) + abs(c))
        let dx = (q.x - 0.5) * a, dy = q.y - 0.5
        let rx = (c * dx - sn * dy) * zoom, ry = (sn * dx + c * dy) * zoom
        return CGPoint(x: 0.5 + rx / a, y: 0.5 + ry)
    }

    static func rotated(_ r: CGRect, aspect a: Double, angle: Double) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map { rotated($0, aspect: a, angle: angle) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

extension Library {
    /// Face, people and subject data for a suggestion: the AI analysis if it has run and has people boxes,
    /// otherwise a quick analysis of this photo only (~60 ms).
    func autoCropData(_ p: Photo) async -> CullData? {
        if let c = p.cull, c.people != nil { return c }
        let url = p.url
        guard let img = await Task.detached(priority: .userInitiated, operation: { ImageStore.shared.preview(url) }).value else { return nil }
        return await CullAnalyzer.analyze(img)
    }

    /// Suggestion as edit settings: the photo's adjustments with the suggested geometry.
    func autoCropSuggestion(_ p: Photo, ratio: Double?) async -> Adjustments? {
        guard let c = await autoCropData(p),
              let r = AutoCrop.suggest(c, aspect: imageAspect(p), ratio: ratio) else { return nil }
        var a = p.adj
        a.angle = r.angle
        a.cropRect = r.rect
        a.cropAspect = ratio.flatMap { v in CropFormat.all.first { ($0.ratio ?? -1) > 0 && abs(($0.ratio ?? 0) - v) < 0.001 }?.id } ?? "original"
        return a
    }

    /// A in the crop editor / the "Auto" button: suggest a crop for the current photo in the format chosen in the bar.
    func autoCropCurrent() {
        guard let p = current else { return }
        if !cropMode { startCrop() }
        let f = CropFormat.byID(p.adj.cropAspect)
        let ratio: Double? = autoCropQueue.isEmpty ? (f?.ratio).flatMap { $0 > 0 ? $0 : nil } : autoCropRatio
        let id = p.id
        autoCropBusy = true
        Task {
            let s = await autoCropSuggestion(p, ratio: ratio)
            autoCropBusy = false
            guard currentID == id, cropMode else { return }
            if let s { setAdjustments(s) } else { flash(tr("Кадр уже скомпонован — предложить нечего")) }
        }
    }

    /// Auto crop review: kept photos (or the selection) one by one in the crop editor with a suggestion;
    /// Enter accepts (it can be adjusted first), Esc or → skips. Nothing is applied without the photographer.
    func startAutoCropReview(ratio: Double?) {
        let list = multiSelected ? targets : visible.filter { $0.rating > 0 && !$0.rejected && !$0.adj.hasGeometry }
        guard !list.isEmpty else {
            flash(tr("Оставьте кадры (P) или выделите нужные — им будет предложено кадрирование")); return
        }
        // A review already running is replaced: emptied first, so closing its editor doesn't open its next photo.
        autoCropQueue = []
        if cropMode { cancelCrop() }
        autoCropRatio = ratio
        autoCropQueue = list.map(\.id)
        autoCropPos = 0
        autoCropAccepted = 0
        showAutoCropItem()
    }

    func stopAutoCropReview() {
        let n = autoCropAccepted
        autoCropQueue = []
        if cropMode { cancelCrop() }
        flash(tr("Автокадрирование: принято \(n)"))
    }

    /// Called when the crop editor closes: next photo of the review, or the summary at the end.
    func autoCropAdvance(accepted: Bool) {
        guard !autoCropQueue.isEmpty else { return }
        if accepted { autoCropAccepted += 1 }
        autoCropPos += 1
        if autoCropPos < autoCropQueue.count {
            showAutoCropItem()
        } else {
            let n = autoCropAccepted, total = autoCropQueue.count
            autoCropQueue = []
            flash(tr("Автокадрирование: принято \(n) из \(total)"))
        }
    }

    private func showAutoCropItem() {
        guard autoCropPos < autoCropQueue.count, let p = photo(autoCropQueue[autoCropPos]) else { return }
        select(p)
        startCrop()
        autoCropCurrent()
    }
}

/// "Suggest crop" with a format choice — for kept photos or the selection.
struct AutoCropMenu: View {
    let lib: Library   // passed explicitly: menu bar commands have no environment

    var body: some View {
        Menu(tr("Предложить кадрирование")) {
            Button(tr("Как снято (только композиция и горизонт)")) { lib.startAutoCropReview(ratio: nil) }
            Divider()
            Button(tr("4:5 — пост Instagram")) { lib.startAutoCropReview(ratio: 4.0 / 5) }
            Button(tr("1:1 — квадрат")) { lib.startAutoCropReview(ratio: 1) }
            Button(tr("9:16 — сторис, Reels")) { lib.startAutoCropReview(ratio: 9.0 / 16) }
            Button(tr("16:9 — обложка, видео")) { lib.startAutoCropReview(ratio: 16.0 / 9) }
        }
        .help(tr("Оставленным кадрам (или выделенным) по очереди — рамка от AI; каждую принимаете или пропускаете"))
    }
}
