import AppKit
import Foundation

/// Причина, по которой кадр похож на брак. Это подсказка — решает фотограф.
enum CullReason: String, CaseIterable, Identifiable, Hashable {
    case blur, eyesClosed, overexposed, underexposed, tilted, utility, duplicate, weakerInSeries
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: tr("Нерезкий")
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
        case .eyesClosed: "eye.slash"
        case .overexposed: "sun.max.trianglebadge.exclamationmark"
        case .underexposed: "moon.haze"
        case .tilted: "level"
        case .utility: "doc.text.viewfinder"
        case .duplicate: "doc.on.doc"
        case .weakerInSeries: "square.stack.3d.down.right"
        }
    }

    /// Брак или поправимое. Горизонт — поправимое: детектор путает его с линиями в кадре,
    /// и завал не повод выбрасывать кадр — его выравнивают.
    var isDefect: Bool { self != .tilted }

    /// Насколько сильно причина снижает оценку кадра.
    var penalty: Int {
        switch self {
        case .blur: 45
        case .eyesClosed: 35
        case .utility: 50
        case .duplicate: 40
        case .weakerInSeries: 25
        case .overexposed: 20
        case .underexposed: 15
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
    // MARK: - Вердикт

    /// Пороги зависят от строгости: 0 — мягко (ловим только явный брак), 1 — строго.
    func verdict(_ p: Photo) -> CullVerdict {
        var v = CullVerdict()
        let st = cullStrictness
        if p.duplicateOf != nil { v.reasons.append(.duplicate) }
        if let c = p.cull {
            // Резкость лиц и резкость кадра в разном масштабе — сравниваем со своей медианой.
            let median = c.faces.isEmpty ? cullMedianSharpness : cullMedianFaceSharpness
            // Недосвет: тёмный кадр без светлых мест. Ночная сцена или low-key со светлыми акцентами — не брак.
            let dark = (c.meanLuma ?? 0.5) < 0.06 + 0.06 * st
                || ((c.meanLuma ?? 0.5) < 0.16 && (c.brightLuma ?? 1) < 0.30 + 0.08 * st)
            // На очень тёмном кадре мало перепадов — это недосвет, а не смаз.
            if !dark, let s = c.subjectSharpness, median > 0, s / median < 0.18 + 0.27 * st {
                v.reasons.append(.blur)
            }
            // Глаза — только у заметных лиц, которые macOS уверенно распознал.
            if c.faces.contains(where: { $0.w >= 0.04 && ($0.quality ?? 1) >= 0.25 && ($0.eyes ?? 1) < 0.20 + 0.05 * st }) {
                v.reasons.append(.eyesClosed)
            }
            // Яркое окно или небо — норма; брак — когда выбита заметная часть кадра.
            if c.clipHigh > 0.10 - 0.06 * st { v.reasons.append(.overexposed) }
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
            if big.allSatisfy({ ($0.eyes ?? 0.3) >= 0.22 }) { r += 25 }
            r += big.compactMap(\.quality).reduce(0, +) / Double(big.count) * 15
        }
        if let a = c.aesthetics { r += (a + 1) / 2 * 15 }
        // Пересвет «добавляет резкости» (жёсткие перепады) — без штрафа лучшим стал бы выбитый кадр.
        if c.clipHigh > 0.05 { r -= 30 }
        if (c.meanLuma ?? 0.5) < 0.08 { r -= 30 }
        if big.contains(where: { ($0.eyes ?? 0.3) < 0.2 }) { r -= 20 }
        return r
    }

    /// После анализа: медиана резкости папки и лучший в каждой серии.
    func updateCullStats() {
        func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        cullMedianSharpness = median(photos.filter { $0.cull?.faces.isEmpty ?? true }.compactMap { $0.cull?.subjectSharpness ?? $0.sharpness })
        cullMedianFaceSharpness = median(photos.filter { !($0.cull?.faces.isEmpty ?? true) }.compactMap { $0.cull?.subjectSharpness })
        var best: [Int: Double] = [:]
        for p in photos {
            guard let sid = p.seriesID, let s = p.cull?.subjectSharpness ?? p.sharpness else { continue }
            best[sid] = max(best[sid] ?? 0, s)
        }
        seriesBestSharpness = best
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
