import AppKit
import Foundation

/// Why a frame looks like a reject. This is a hint; the photographer decides.
enum CullReason: String, CaseIterable, Identifiable, Hashable {
    case blur, blink, eyesClosed, overexposed, underexposed, tilted, utility, duplicate, weakerInSeries, repeated
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: tr("Нерезкий")
        case .blink: tr("Моргнул в серии")
        case .eyesClosed: tr("Закрыты глаза")
        case .overexposed: tr("Пересвет")
        case .underexposed: tr("Недосвет")
        case .tilted: tr("Завален горизонт")
        case .utility: tr("Служебный кадр")
        case .duplicate: tr("Дубль")
        case .weakerInSeries: tr("Слабее в серии")
        case .repeated: tr("Повтор лучшего")
        }
    }

    var icon: String {
        switch self {
        case .blur: "drop.halffull"
        case .blink: "eye.trianglebadge.exclamationmark"
        case .eyesClosed: "eye.slash"
        case .overexposed: "sun.max.trianglebadge.exclamationmark"
        case .underexposed: "moon.haze"
        case .tilted: "level"
        case .utility: "doc.text.viewfinder"
        case .duplicate: "doc.on.doc"
        case .weakerInSeries: "square.stack.3d.down.right"
        case .repeated: "square.on.square"
        }
    }

    /// Reject or hint. Calibrated on a 2032-frame shoot (27.07.2026):
    /// the horizon detector confuses lines; closed eyes in a single frame are often a pose;
    /// a dark evening frame can be pulled up from RAW; "weaker in series" is a different pose, not a defect.
    var isDefect: Bool {
        switch self {
        case .blur, .blink, .overexposed, .utility, .duplicate: true
        case .eyesClosed, .underexposed, .tilted, .weakerInSeries, .repeated: false
        }
    }

    /// How much the reason lowers the frame's score.
    var penalty: Int {
        switch self {
        case .blur: 45
        case .blink: 35
        case .eyesClosed: 10
        case .utility: 50
        case .duplicate: 40
        case .weakerInSeries: 10
        case .repeated: 5
        case .overexposed: 25
        case .underexposed: 10
        case .tilted: 10
        }
    }
}

struct CullVerdict {
    var reasons: [CullReason] = []
    var score = 100            // 0…100: technique + aesthetics
    var suspect: Bool { reasons.contains(where: \.isDefect) }
}

extension Library {
    /// A face with open eyes in a series: head pitch and size, to compare frames in the same pose.
    struct OpenPose: Sendable { var id: URL; var pitch: Double; var px: Double }

    // MARK: - Verdict

    /// Thresholds depend on strictness: 0 is lenient (catch only obvious defects), 1 is strict.
    func verdict(_ p: Photo) -> CullVerdict {
        var v = CullVerdict()
        let st = cullStrictness
        let enabled = aiEnabled
        func on(_ m: AIModule) -> Bool { enabled.contains(m) }
        if p.duplicateOf != nil { v.reasons.append(.duplicate) }
        if let c = p.cull {
            // Face sharpness and frame sharpness are on different scales; compare each with its own median.
            // Reliable-face sharpness and subject/frame sharpness are on different scales: each has its own median.
            // Compare within a scene: an evening frame (dark, noise reduction) against evening ones, a daytime frame against daytime ones.
            let byFace = c.faces.contains(where: \.reliable)
            let local = p.sceneID.flatMap { sceneMedians[$0] }
            let median = (byFace ? local?.face : local?.other) ?? (byFace ? cullMedianFaceSharpness : cullMedianSharpness)
            // Underexposure: a dark frame with no bright areas. A night scene or low-key with bright accents is not a defect.
            let dark = (c.meanLuma ?? 0.5) < 0.06 + 0.06 * st
                || ((c.meanLuma ?? 0.5) < 0.16 && (c.brightLuma ?? 1) < 0.30 + 0.08 * st)
            // A very dark frame has few transitions: that's underexposure, not blur.
            if on(.subject), !dark, let s = c.subjectSharpness, median > 0, s / median < 0.18 + 0.27 * st {
                v.reasons.append(.blur)
            }
            // Eyes only for large camera-facing faces. A blink is when eyes are open elsewhere in the same series.
            let rel = on(.faces) ? c.faces.filter(\.reliable) : []
            let mesh = on(.faces) ? c.faces.filter(\.meshUsable) : []
            if !mesh.isEmpty {
                // MediaPipe mesh. A blink if the series has a frame with open eyes in the same pose
                // (head pitch ±8°, same face size). Head lowered ≥ 15° is a downward gaze, not a defect;
                // a single frame with closed eyes is only a hint (it may be intentional).
                if let f = mesh.filter({ $0.eyesShut(st) }).max(by: { ($0.px ?? 0) < ($1.px ?? 0) }) {
                    let pitch = f.pitch ?? 0, px = f.px ?? 1
                    let samePose = p.seriesID.flatMap { seriesOpenPoses[$0] }?.contains {
                        $0.id != p.id && abs($0.pitch - pitch) < 8 && abs($0.px - px) / px < 0.3
                    } ?? false
                    if samePose && pitch < 15 { v.reasons.append(.blink) }
                    else if pitch < 12 { v.reasons.append(.eyesClosed) }
                }
            } else if let eyes = rel.compactMap(\.eyes).min() {
                // macOS contour (no models): a reject only if the eyes are closed both on their own and relative to the best frame in the series.
                if let sid = p.seriesID, let open = seriesOpenEyes[sid], open >= 0.26, eyes < min(0.16 + 0.03 * st, open * (0.5 + 0.1 * st)) {
                    v.reasons.append(.blink)
                } else if eyes < 0.12 + 0.04 * st {
                    v.reasons.append(.eyesClosed)
                }
            }
            // Overexposure on the face/subject; the whole frame only if most of it is blown (white sky behind is normal).
            // Calibration: a bright face against an overcast sky gives 14–25% "blown" pixels; that's normal.
            if on(.exposure), (c.subjectClip ?? 0) > 0.40 - 0.15 * st || c.clipHigh > 0.45 - 0.15 * st { v.reasons.append(.overexposed) }
            if on(.exposure), c.clipLow > 0.30 - 0.12 * st || dark { v.reasons.append(.underexposed) }
            if on(.horizon), let h = c.horizon, abs(h) >= 2.5 - 1.0 * st, abs(h) <= 15 { v.reasons.append(.tilted) }
            if on(.aesthetics), c.utility { v.reasons.append(.utility) }
            if on(.subject), let sid = p.seriesID, !p.isBestInSeries, let best = seriesBestSharpness[sid], best > 0,
               let s = c.subjectSharpness, s < best * (0.45 + 0.3 * st), !v.reasons.contains(.blur) {
                v.reasons.append(.weakerInSeries)
            }
            // A near-copy of the burst's best frame: nothing wrong with it, it's just redundant —
            // the user's own rejects on the 2032-frame shoot were mostly these (8 fps bursts, same pose).
            if on(.similarity), let sid = p.seriesID, !p.isBestInSeries, let bp = seriesBestPrint[sid], let pp = c.print,
               let d = printDistance(bp, pp), d < 0.25 {
                v.reasons.append(.repeated)
            }
            // Base is aesthetics (0.5 → 75, 0.85 → 92), minus penalties for defects.
            v.score = Int((50 + (on(.aesthetics) ? c.aesthetics ?? 0.5 : 0.5) * 50).rounded()) - v.reasons.reduce(0) { $0 + $1.penalty }
        } else {
            v.score = 75 - v.reasons.reduce(0) { $0 + $1.penalty }
        }
        v.score = min(100, max(0, v.score))
        return v
    }

    /// Rank of a frame within its series: which one to keep.
    func seriesRank(_ p: Photo, maxSharp: Double) -> Double {
        guard let c = p.cull else { return (p.sharpness ?? 0) / max(maxSharp, 1) }
        var r = (c.subjectSharpness ?? p.sharpness ?? 0) / max(maxSharp, 1) * 40
        let big = c.faces.filter { $0.w >= 0.04 }
        if !big.isEmpty {
            if big.allSatisfy(\.eyesOpen) { r += 25 }
            r += big.compactMap(\.quality).reduce(0, +) / Double(big.count) * 15
        }
        if let a = c.aesthetics { r += (a + 1) / 2 * 15 }
        // A smile (MediaPipe) — a plus when choosing the best of a burst: same pose, better expression.
        if let sm = big.compactMap(\.smile).max() { r += sm * 10 }
        // Overexposure "adds sharpness" (hard transitions); without a penalty a blown frame would win.
        if c.clipHigh > 0.05 { r -= 30 }
        if (c.meanLuma ?? 0.5) < 0.08 { r -= 30 }
        if (c.subjectClip ?? 0) > 0.15 { r -= 20 }
        if big.contains(where: { ($0.reliable || $0.meshUsable) && $0.eyesShut() }) { r -= 20 }
        return r
    }

    /// After analysis: the folder's sharpness median and the best frame in each series.
    func updateCullStats() {
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let byFace = { (p: Photo) in p.cull?.faces.contains(where: \.reliable) ?? false }
        cullMedianSharpness = median(photos.filter { !byFace($0) }.compactMap { $0.cull?.subjectSharpness ?? $0.sharpness })
        cullMedianFaceSharpness = median(photos.filter(byFace).compactMap { $0.cull?.subjectSharpness })
        // Medians per scene (if the scene has at least 8 frames of the right kind; otherwise over the whole folder).
        var sm: [Int: (face: Double?, other: Double?)] = [:]
        for (sid, list) in Dictionary(grouping: photos.filter { $0.sceneID != nil }, by: { $0.sceneID! }) {
            let f = list.filter(byFace).compactMap { $0.cull?.subjectSharpness }
            let o = list.filter { !byFace($0) }.compactMap { $0.cull?.subjectSharpness ?? $0.sharpness }
            sm[sid] = (f.count >= 8 ? median(f) : nil, o.count >= 8 ? median(o) : nil)
        }
        sceneMedians = sm
        var best: [Int: Double] = [:]
        for p in photos {
            guard let sid = p.seriesID, let s = p.cull?.subjectSharpness ?? p.sharpness else { continue }
            best[sid] = max(best[sid] ?? 0, s)
        }
        seriesBestSharpness = best
        // How open the eyes are in the series (by the best frame), for blink detection.
        var open: [Int: Double] = [:]
        for p in photos {
            guard let sid = p.seriesID, let e = p.cull?.faces.filter(\.reliable).compactMap(\.eyes).min() else { continue }
            open[sid] = max(open[sid] ?? 0, e)
        }
        seriesOpenEyes = open
        // Per MediaPipe: open-eye poses in each series, used to compare closed-eye frames against.
        var poses: [Int: [OpenPose]] = [:]
        for p in photos {
            guard let sid = p.seriesID else { continue }
            for f in p.cull?.faces ?? [] where f.meshUsable && f.eyesOpen {
                poses[sid, default: []].append(OpenPose(id: p.id, pitch: f.pitch ?? 0, px: f.px ?? 0))
            }
        }
        seriesOpenPoses = poses
        var bestPrints: [Int: Data] = [:]
        for p in photos where p.isBestInSeries { if let sid = p.seriesID, let pr = p.cull?.print { bestPrints[sid] = pr } }
        seriesBestPrint = bestPrints
    }

    /// Brighten a dark frame: set exposure so the mean luminance reaches ~0.35 (up to +3 EV).
    func brightenDark() {
        guard let p = current, let l = p.cull?.meanLuma, l > 0.005 else { return }
        var a = p.adj
        a.exposure = min(3, max(0, (log2(0.35 / l) * 0.85 * 20).rounded() / 20))
        setAdjustments(a)
        flash(tr("Экспозиция \(String(format: "%+.2f EV", a.exposure))"))
    }

    /// Straighten the horizon by the detected angle (up to ±15°), as a single undo step.
    func straightenByHorizon() {
        guard let p = current, let h = p.cull?.horizon, abs(h) <= 15 else { return }
        var a = p.adj
        a.angle = (h * 10).rounded() / 10
        setAdjustments(a)
        flash(tr("Горизонт выровнен: \(String(format: "%+.1f°", a.angle))"))
    }

    // MARK: - Decisions: P keeps, X rejects, U clears

    /// P: keep. With no rating, sets ★ so the pick is visible in Capture One too.
    func keep() {
        let many = multiSelected
        let order = shownOrder
        update(tr("Оставлено")) { if $0.rating == 0 { $0.rating = 1 }; $0.rejected = false }
        flash(tr("Оставлено ★") + countSuffix + " · " + tr("U — снять"), seconds: 2.2)
        if !many { advanceAfterDecision(after: order) }
    }

    /// U: clear the decision: no rating, no reject.
    func unflag() {
        update(tr("Решение снято")) { $0.rating = 0; $0.rejected = false }
        flash(tr("Решение снято") + countSuffix)
    }

    var decided: (kept: Int, rejected: Int, undecided: Int) {
        var k = 0, r = 0, u = 0
        for p in photos { if p.rejected { r += 1 } else if p.rating > 0 { k += 1 } else { u += 1 } }
        return (k, r, u)
    }

    // MARK: - Bulk actions (each is one undo step, with confirmation)

    /// Reject all "suspicious" frames among those shown, except ones you have already kept.
    func acceptSuggestions() {
        let list = visible.filter { !$0.rejected && $0.rating == 0 && verdict($0).suspect }
        guard !list.isEmpty else { flash(tr("Предложений нет")); return }
        guard confirm(tr("Отклонить \(list.count) кадров с признаками брака?"),
                      tr("Оставленные вами (с оценкой) не трогаются. Отменить — ⌘Z.")) else { return }
        let before = snapshot(list.map(\.id))
        for p in list { if let i = photos.firstIndex(where: { $0.id == p.id }) { photos[i].rejected = true; writeSidecar(i) } }
        record(tr("Брак отклонён: \(list.count)"), before: before)
        flash(tr("Отклонено: \(list.count)"))
    }

    /// In each series keep the best (★) and reject the rest. Frames you have already rated are left alone.
    func keepBestInSeries() {
        let series = Dictionary(grouping: photos.filter { $0.seriesID != nil }, by: { $0.seriesID! })
        var ids: [URL] = []
        for (_, s) in series { ids += s.map(\.id) }
        guard !ids.isEmpty else { flash(tr("Серий нет")); return }
        let rejectCount = series.values.reduce(0) { $0 + $1.filter { !$0.isBestInSeries && $0.rating == 0 && !$0.rejected }.count }
        guard confirm(tr("Оставить лучший кадр в каждой из \(series.count) серий и отклонить остальные (\(rejectCount))?"),
                      tr("Кадры, которым вы уже поставили оценку, не трогаются. Отменить — ⌘Z.")) else { return }
        let before = snapshot(ids)
        for (_, s) in series {
            for p in s {
                guard let i = photos.firstIndex(where: { $0.id == p.id }), photos[i].rating == 0 else { continue }
                if p.isBestInSeries { photos[i].rating = 1; photos[i].rejected = false } else { photos[i].rejected = true }
                writeSidecar(i)
            }
        }
        record(tr("Лучшие в сериях: \(series.count), отклонено \(rejectCount)"), before: before)
        flash(tr("Готово: \(series.count) серий"))
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: tr("Да"))
        a.addButton(withTitle: tr("Отмена"))
        return a.runModal() == .alertFirstButtonReturn
    }

    func writeSidecar(_ i: Int) {
        let p = photos[i]
        try? Sidecar.write(.init(rating: p.rating, rejected: p.rejected, label: p.label), for: p.url)
    }
}

// MARK: - The good ones

extension Library {
    /// "Best photos": one per burst (its best) and single photos, with no defects or closed eyes and a good score.
    /// Calibrated on 2032 frames: the median score of non-rejected photos is 80, the quartile 72.
    func isRecommended(_ p: Photo) -> Bool {
        guard aiReady, !p.rejected, p.duplicateOf == nil, p.cull != nil, p.seriesID == nil || p.isBestInSeries else { return false }
        let v = verdict(p)
        return !v.reasons.contains { $0.isDefect || $0 == .eyesClosed } && v.score >= 72
    }
}

// MARK: - Why: the numbers behind each finding

extension Library {
    /// Typical sharpness of reliable faces in the photo's scene (or the whole folder).
    func medianFaceSharpness(_ p: Photo) -> Double? {
        let m = p.sceneID.flatMap { sceneMedians[$0]?.face } ?? cullMedianFaceSharpness
        return m > 0 ? m : nil
    }

    /// One line per reason with the measured value and the threshold at the current strictness —
    /// shown on hover over the reason tag, like Lightroom's Culling Info.
    func explain(_ r: CullReason, _ p: Photo) -> String {
        let st = cullStrictness
        guard let c = p.cull else { return r == .duplicate ? tr("Точная копия другого файла (тот же размер, время и картинка)") : r.title }
        func pct(_ v: Double) -> Int { Int((v * 100).rounded()) }
        switch r {
        case .blur:
            let byFace = c.faces.contains(where: \.reliable)
            let local = p.sceneID.flatMap { sceneMedians[$0] }
            let median = (byFace ? local?.face : local?.other) ?? (byFace ? cullMedianFaceSharpness : cullMedianSharpness)
            let rel = median > 0 ? (c.subjectSharpness ?? 0) / median : 0
            return tr("Резкость \(byFace ? tr("лица") : tr("объекта")): \(pct(rel))% от обычной для сцены; брак ниже \(pct(0.18 + 0.27 * st))%")
        case .blink, .eyesClosed:
            let f = c.faces.filter(\.meshUsable).max { ($0.blink ?? 0) < ($1.blink ?? 0) }
            let b = f?.blink.map { String(format: "%.2f", $0) } ?? "—"
            return r == .blink
                ? tr("Оба глаза закрыты (моргание \(b), порог \(String(format: "%.2f", 0.45 - 0.1 * st))); в серии есть кадр в той же позе с открытыми глазами")
                : tr("Оба глаза закрыты (моргание \(b)) — кадр без пары с открытыми глазами, может быть задумано")
        case .overexposed:
            return tr("Пересвет: на лице или объекте \(pct(c.subjectClip ?? 0))% (порог \(pct(0.40 - 0.15 * st))%), во всём кадре \(pct(c.clipHigh))% (порог \(pct(0.45 - 0.15 * st))%)")
        case .underexposed:
            return tr("Средняя яркость \(pct(c.meanLuma ?? 0))%, светлые места \(pct(c.brightLuma ?? 0))%, провалы в чёрное \(pct(c.clipLow))%")
        case .tilted:
            return tr("Горизонт завален на \(String(format: "%.1f°", abs(c.horizon ?? 0)))")
        case .utility:
            return tr("Похоже на служебный снимок: экран, документ, случайный кадр")
        case .duplicate:
            return tr("Точная копия другого файла (тот же размер, время и картинка)")
        case .repeated:
            return tr("Почти копия лучшего кадра серии — оставьте лучший, этот можно в брак")
        case .weakerInSeries:
            let best = p.seriesID.flatMap { seriesBestSharpness[$0] } ?? 0
            return tr("Резкость \(pct(best > 0 ? (c.subjectSharpness ?? 0) / best : 0))% от лучшего кадра серии")
        }
    }
}
