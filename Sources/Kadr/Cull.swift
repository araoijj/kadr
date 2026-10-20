import AppKit
import Foundation

/// Причина, по которой кадр похож на брак. Это подсказка — решает фотограф.
enum CullReason: String, CaseIterable, Identifiable, Hashable {
    case blur, blink, eyesClosed, overexposed, underexposed, tilted, utility, duplicate, weakerInSeries
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
        }
    }

    /// Брак или подсказка. Откалибровано на съёмке 2032 кадра (27.07.2026):
    /// горизонт детектор путает с линиями; закрытые глаза на одиночном кадре — часто поза;
    /// тёмный вечерний кадр вытягивается из RAW; «слабее в серии» — другая поза, а не брак.
    var isDefect: Bool {
        switch self {
        case .blur, .blink, .overexposed, .utility, .duplicate: true
        case .eyesClosed, .underexposed, .tilted, .weakerInSeries: false
        }
    }

    /// Насколько сильно причина снижает оценку кадра.
    var penalty: Int {
        switch self {
        case .blur: 45
        case .blink: 35
        case .eyesClosed: 10
        case .utility: 50
        case .duplicate: 40
        case .weakerInSeries: 10
        case .overexposed: 25
        case .underexposed: 10
        case .tilted: 10
        }
    }
}

struct CullVerdict {
    var reasons: [CullReason] = []
    var score = 100            // 0…100: техника + эстетика
    var suspect: Bool { reasons.contains(where: \.isDefect) }
}

extension Library {
    /// Лицо с открытыми глазами в серии: наклон головы и размер — чтобы сравнивать кадры в одной позе.
    struct OpenPose: Sendable { var id: URL; var pitch: Double; var px: Double }

    // MARK: - Вердикт

    /// Пороги зависят от строгости: 0 — мягко (ловим только явный брак), 1 — строго.
    func verdict(_ p: Photo) -> CullVerdict {
        var v = CullVerdict()
        let st = cullStrictness
        if p.duplicateOf != nil { v.reasons.append(.duplicate) }
        if let c = p.cull {
            // Резкость лиц и резкость кадра в разном масштабе — сравниваем со своей медианой.
            // Резкость надёжного лица и резкость объекта/кадра — в разном масштабе: у каждой своя медиана.
            // Сравниваем внутри сцены: вечерний кадр (темно, шумодав) — с вечерними, дневной — с дневными.
            let byFace = c.faces.contains(where: \.reliable)
            let local = p.sceneID.flatMap { sceneMedians[$0] }
            let median = (byFace ? local?.face : local?.other) ?? (byFace ? cullMedianFaceSharpness : cullMedianSharpness)
            // Недосвет: тёмный кадр без светлых мест. Ночная сцена или low-key со светлыми акцентами — не брак.
            let dark = (c.meanLuma ?? 0.5) < 0.06 + 0.06 * st
                || ((c.meanLuma ?? 0.5) < 0.16 && (c.brightLuma ?? 1) < 0.30 + 0.08 * st)
            // На очень тёмном кадре мало перепадов — это недосвет, а не смаз.
            if !dark, let s = c.subjectSharpness, median > 0, s / median < 0.18 + 0.27 * st {
                v.reasons.append(.blur)
            }
            // Глаза — только у крупных лиц к камере. Моргание — когда в той же серии глаза открыты.
            let rel = c.faces.filter(\.reliable)
            let mesh = c.faces.filter(\.meshUsable)
            if !mesh.isEmpty {
                // Сетка MediaPipe. Моргание — если в серии есть кадр с открытыми глазами в той же позе
                // (наклон головы ±8°, тот же размер лица). Голова опущена ≥ 15° — это взгляд вниз, не брак;
                // одиночный кадр с закрытыми глазами — только подсказка (может быть задумано).
                if let f = mesh.filter({ $0.eyesShut(st) }).max(by: { ($0.px ?? 0) < ($1.px ?? 0) }) {
                    let pitch = f.pitch ?? 0, px = f.px ?? 1
                    let samePose = p.seriesID.flatMap { seriesOpenPoses[$0] }?.contains {
                        $0.id != p.id && abs($0.pitch - pitch) < 8 && abs($0.px - px) / px < 0.3
                    } ?? false
                    if samePose && pitch < 15 { v.reasons.append(.blink) }
                    else if pitch < 12 { v.reasons.append(.eyesClosed) }
                }
            } else if let eyes = rel.compactMap(\.eyes).min() {
                // Контур от macOS (моделей нет): брак — только если глаза закрыты и сами по себе, и относительно лучшего кадра серии.
                if let sid = p.seriesID, let open = seriesOpenEyes[sid], open >= 0.26, eyes < min(0.16 + 0.03 * st, open * (0.5 + 0.1 * st)) {
                    v.reasons.append(.blink)
                } else if eyes < 0.12 + 0.04 * st {
                    v.reasons.append(.eyesClosed)
                }
            }
            // Пересвет — на лице/объекте; весь кадр — только если выбита большая часть (белое небо за спиной — норма).
            // Калибровка: светлое лицо на пасмурном небе даёт 14–25% «выбитых» пикселей — это норма.
            if (c.subjectClip ?? 0) > 0.40 - 0.15 * st || c.clipHigh > 0.45 - 0.15 * st { v.reasons.append(.overexposed) }
            if c.clipLow > 0.30 - 0.12 * st || dark { v.reasons.append(.underexposed) }
            if let h = c.horizon, abs(h) >= 2.5 - 1.0 * st, abs(h) <= 15 { v.reasons.append(.tilted) }
            if c.utility { v.reasons.append(.utility) }
            if let sid = p.seriesID, !p.isBestInSeries, let best = seriesBestSharpness[sid], best > 0,
               let s = c.subjectSharpness, s < best * (0.45 + 0.3 * st), !v.reasons.contains(.blur) {
                v.reasons.append(.weakerInSeries)
            }
            // База — эстетика (0,5 → 75, 0,85 → 92), минус штрафы за брак.
            v.score = Int((50 + (c.aesthetics ?? 0.5) * 50).rounded()) - v.reasons.reduce(0) { $0 + $1.penalty }
        } else {
            v.score = 75 - v.reasons.reduce(0) { $0 + $1.penalty }
        }
        v.score = min(100, max(0, v.score))
        return v
    }

    /// Ранг кадра внутри серии: какой оставить.
    func seriesRank(_ p: Photo, maxSharp: Double) -> Double {
        guard let c = p.cull else { return (p.sharpness ?? 0) / max(maxSharp, 1) }
        var r = (c.subjectSharpness ?? p.sharpness ?? 0) / max(maxSharp, 1) * 40
        let big = c.faces.filter { $0.w >= 0.04 }
        if !big.isEmpty {
            if big.allSatisfy(\.eyesOpen) { r += 25 }
            r += big.compactMap(\.quality).reduce(0, +) / Double(big.count) * 15
        }
        if let a = c.aesthetics { r += (a + 1) / 2 * 15 }
        // Пересвет «добавляет резкости» (жёсткие перепады) — без штрафа лучшим стал бы выбитый кадр.
        if c.clipHigh > 0.05 { r -= 30 }
        if (c.meanLuma ?? 0.5) < 0.08 { r -= 30 }
        if (c.subjectClip ?? 0) > 0.15 { r -= 20 }
        if big.contains(where: { ($0.reliable || $0.meshUsable) && $0.eyesShut() }) { r -= 20 }
        return r
    }

    /// После анализа: медиана резкости папки и лучший в каждой серии.
    func updateCullStats() {
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let byFace = { (p: Photo) in p.cull?.faces.contains(where: \.reliable) ?? false }
        cullMedianSharpness = median(photos.filter { !byFace($0) }.compactMap { $0.cull?.subjectSharpness ?? $0.sharpness })
        cullMedianFaceSharpness = median(photos.filter(byFace).compactMap { $0.cull?.subjectSharpness })
        // Медианы по сценам (если в сцене хотя бы 8 кадров нужного вида — иначе по всей папке).
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
        // Насколько открыты глаза в серии (по лучшему кадру) — для поиска моргания.
        var open: [Int: Double] = [:]
        for p in photos {
            guard let sid = p.seriesID, let e = p.cull?.faces.filter(\.reliable).compactMap(\.eyes).min() else { continue }
            open[sid] = max(open[sid] ?? 0, e)
        }
        seriesOpenEyes = open
        // По MediaPipe: позы с открытыми глазами в каждой серии — с ними сравниваем закрытые.
        var poses: [Int: [OpenPose]] = [:]
        for p in photos {
            guard let sid = p.seriesID else { continue }
            for f in p.cull?.faces ?? [] where f.meshUsable && f.eyesOpen {
                poses[sid, default: []].append(OpenPose(id: p.id, pitch: f.pitch ?? 0, px: f.px ?? 0))
            }
        }
        seriesOpenPoses = poses
    }

    /// Осветлить тёмный кадр: экспозиция так, чтобы средняя яркость стала ~0,35 (до +3 EV).
    func brightenDark() {
        guard let p = current, let l = p.cull?.meanLuma, l > 0.005 else { return }
        var a = p.adj
        a.exposure = min(3, max(0, (log2(0.35 / l) * 0.85 * 20).rounded() / 20))
        setAdjustments(a)
        flash(tr("Экспозиция \(String(format: "%+.2f EV", a.exposure))"))
    }

    /// Выровнять горизонт по найденному углу (до ±15°) — одним шагом журнала.
    func straightenByHorizon() {
        guard let p = current, let h = p.cull?.horizon, abs(h) <= 15 else { return }
        var a = p.adj
        a.angle = (h * 10).rounded() / 10
        setAdjustments(a)
        flash(tr("Горизонт выровнен: \(String(format: "%+.1f°", a.angle))"))
    }

    // MARK: - Решения: P — оставить, X — брак, U — снять

    /// P: оставить. Без оценки — ★, чтобы отбор был виден и в Capture One.
    func keep() {
        let many = multiSelected
        update(tr("Оставлено")) { if $0.rating == 0 { $0.rating = 1 }; $0.rejected = false }
        flash(tr("Оставлено") + countSuffix)
        if !many { advanceAfterDecision() }
    }

    /// U: снять решение — ни оценки, ни отклонения.
    func unflag() {
        update(tr("Решение снято")) { $0.rating = 0; $0.rejected = false }
        flash(tr("Решение снято") + countSuffix)
    }

    var decided: (kept: Int, rejected: Int, undecided: Int) {
        var k = 0, r = 0, u = 0
        for p in photos { if p.rejected { r += 1 } else if p.rating > 0 { k += 1 } else { u += 1 } }
        return (k, r, u)
    }

    // MARK: - Массовые действия (каждое — один шаг журнала, с подтверждением)

    /// Отклонить все «подозрительные» кадры среди показанных, кроме уже оставленных вами.
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

    /// В каждой серии лучший — оставить (★), остальные — в брак. Уже оценённые вами не трогаются.
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
