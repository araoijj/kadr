import AppKit
import Foundation

/// Сцена — часть съёмки без долгих пауз (сборы, церемония, банкет).
struct SceneInfo: Identifiable, Hashable {
    let id: Int
    let start: Date
    let end: Date
    let count: Int

    var title: String {
        let day = start.formatted(.dateTime.day().month(.abbreviated).locale(I18n.locale))
        let t = Date.FormatStyle(date: .omitted, time: .shortened).locale(I18n.locale)
        let span = start.formatted(t) == end.formatted(t) ? start.formatted(t) : "\(start.formatted(t))–\(end.formatted(t))"
        return tr("Сцена \(id) · \(day), \(span)")
    }
}

extension Library {
    // MARK: - Сцены

    /// Новая сцена — после паузы дольше заданной (по умолчанию 10 минут). Кадры без даты — в одну сцену.
    func computeScenes() {
        let gap = Double(Prefs.sceneGapMinutes) * 60
        let order = photos.indices.sorted {
            (photos[$0].exif.date ?? .distantPast) < (photos[$1].exif.date ?? .distantPast)
        }
        var id = 0
        var last: Date?
        var info: [Int: (Date, Date, Int)] = [:]
        for i in order {
            let d = photos[i].exif.date ?? .distantPast
            if last == nil || d.timeIntervalSince(last!) > gap { id += 1 }
            last = d
            photos[i].sceneID = id
            let cur = info[id] ?? (d, d, 0)
            info[id] = (min(cur.0, d), max(cur.1, d), cur.2 + 1)
        }
        scenes = info.keys.sorted().map { SceneInfo(id: $0, start: info[$0]!.0, end: info[$0]!.1, count: info[$0]!.2) }
    }

    /// Сколько кадров сцены уже решено (оставлено или в браке).
    func sceneProgress(_ s: SceneInfo) -> Int {
        photos.filter { $0.sceneID == s.id && ($0.rejected || $0.rating > 0) }.count
    }

    // MARK: - Турнир

    var tournamentActive: Bool { !tournamentAll.isEmpty }

    /// Длинная серия (или выделенные): два кадра рядом, выбираете лучший, победитель остаётся.
    func startTournament() {
        var ids: [URL]
        if multiSelected { ids = targets.map(\.id) }
        else if let p = current, p.seriesID != nil { ids = series(of: p).map(\.id) }
        else { flash(tr("Турнир — для серии или 2+ выделенных кадров")); return }
        guard ids.count >= 2 else { flash(tr("Нужно хотя бы 2 кадра")); return }
        tournamentAll = ids
        tournamentQueue = Array(ids.dropFirst(2))
        tournamentRound = 1
        compareIDs = [ids[0], ids[1]]
        compareZoom = 1; compareZoomBase = 1
        compareCenter = CGPoint(x: 0.5, y: 0.5)
        select(photo(ids[0]) ?? photos[0])
        loupe = false
        comparing = true
    }

    /// ← — лучше левый, → — лучше правый.
    func pickTournament(left: Bool) {
        guard tournamentActive, compareIDs.count == 2 else { return }
        let winner = left ? compareIDs[0] : compareIDs[1]
        if tournamentQueue.isEmpty { finishTournament(winner); return }
        compareIDs = [winner, tournamentQueue.removeFirst()]
        tournamentRound += 1
        if let p = photo(winner) { select(p) }
    }

    func cancelTournament() {
        tournamentAll = []
        tournamentQueue = []
        stopCompare()
    }

    private func finishTournament(_ winner: URL) {
        let all = tournamentAll
        tournamentAll = []
        tournamentQueue = []
        stopCompare()
        let a = NSAlert()
        a.messageText = tr("Победитель: \(winner.lastPathComponent)")
        a.informativeText = tr("Отметить его ★ и отклонить остальные кадры турнира (\(all.count - 1))? Отменить — ⌘Z.")
        a.addButton(withTitle: tr("Отклонить остальные"))
        a.addButton(withTitle: tr("Только отметить победителя"))
        a.addButton(withTitle: tr("Ничего не менять"))
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { if let p = photo(winner) { select(p) }; return }
        let before = snapshot(all)
        for id in all {
            guard let i = photos.firstIndex(where: { $0.id == id }) else { continue }
            if id == winner { if photos[i].rating == 0 { photos[i].rating = 1 }; photos[i].rejected = false }
            else if r == .alertFirstButtonReturn && photos[i].rating == 0 { photos[i].rejected = true }
            writeSidecar(i)
        }
        record(tr("Турнир: победил \(winner.lastPathComponent)"), before: before)
        if let p = photo(winner) { select(p) }
        flash(tr("Победитель: \(winner.lastPathComponent)"))
    }
}
