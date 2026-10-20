import AppKit
import CryptoKit
import Foundation

/// Состояние кадра, которое можно отменить: обработка, кадрирование, оценка, отклонение, метка.
/// Хранятся только параметры (неразрушающая обработка) — сотни байт на кадр, не пиксели.
struct PhotoState: Codable, Equatable {
    var adj: Adjustments
    var rating: Int
    var rejected: Bool
    var label: ColorLabel?

    init(_ p: Photo) {
        adj = p.adj; rating = p.rating; rejected = p.rejected; label = p.label
    }
}

/// Один шаг журнала. Изменения кадров хранятся только для тех, кого шаг затронул.
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var key: String?                       // для склейки движений одного ползунка
    var changes: [String: Change]          // путь файла → было/стало

    struct Change: Codable {
        var before: PhotoState
        var after: PhotoState
    }

    var photoNames: [String] { changes.keys.map { ($0 as NSString).lastPathComponent }.sorted() }
}

/// Журнал папки на диске: ~/Library/Application Support/Kadr/History/<папка>.json — переживает перезапуск.
enum HistoryStore {
    /// Сколько шагов храним. Замер (20.10): шаг для одного кадра ~1,1 КБ, запись/отмена ~0,1 мс;
    /// пакетный шаг на 1000 кадров ~0,7 МБ, и 100 таких — уже 70 МБ и 2,5 с на сохранение.
    /// Поэтому два предела: 100 шагов и не больше 20 000 изменений кадров всего (~14 МБ, ~0,5 с фоном).
    static let limit = 100
    static let maxPhotoChanges = 20_000

    private struct File: Codable {
        var entries: [HistoryEntry]
        var position: Int
    }

    static func url(for folder: URL) -> URL {
        let dir = AppFolders.support.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        return dir.appendingPathComponent(digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    static func load(_ folder: URL) -> ([HistoryEntry], Int) {
        guard let d = try? Data(contentsOf: url(for: folder)), let f = try? JSONDecoder().decode(File.self, from: d) else { return ([], 0) }
        return (f.entries, min(f.position, f.entries.count))
    }

    static func save(_ entries: [HistoryEntry], _ position: Int, for folder: URL) {
        if let d = try? JSONEncoder().encode(File(entries: entries, position: position)) { try? d.write(to: url(for: folder), options: .atomic) }
    }
}

extension Library {
    // MARK: - Запись

    /// Снимок состояний кадров перед изменением.
    func snapshot(_ ids: [URL]) -> [URL: PhotoState] {
        var out: [URL: PhotoState] = [:]
        for id in ids { if let p = photo(id) { out[id] = PhotoState(p) } }
        return out
    }

    /// Записать шаг: сравнивает «до» с текущим, неизменённые кадры не пишет.
    /// key — склейка: подряд идущие движения одного ползунка на том же кадре (в пределах 1,5 с) — один шаг.
    func record(_ title: String, before: [URL: PhotoState], key: String? = nil) {
        guard !historyPaused else { return }
        var changes: [String: HistoryEntry.Change] = [:]
        for (id, b) in before {
            guard let p = photo(id) else { continue }
            let a = PhotoState(p)
            if a != b { changes[id.path] = .init(before: b, after: a) }
        }
        guard !changes.isEmpty else { return }
        // Отменённые шаги после текущей позиции больше не вернуть — как в любом редакторе.
        if historyPos < history.count { history.removeSubrange(historyPos...) }
        if let key, let last = history.last, last.key == key, Date().timeIntervalSince(last.date) < 1.5,
           Set(last.changes.keys) == Set(changes.keys) {
            var merged = last
            for (k, c) in changes { merged.changes[k]?.after = c.after }
            merged.title = title
            merged.date = Date()
            history[history.count - 1] = merged
        } else {
            history.append(HistoryEntry(title: title, key: key, changes: changes))
            if history.count > HistoryStore.limit { history.removeFirst(history.count - HistoryStore.limit) }
            // Самые старые пакетные шаги уходят первыми, если журнал разросся.
            while history.count > 1, history.reduce(0, { $0 + $1.changes.count }) > HistoryStore.maxPhotoChanges { history.removeFirst() }
        }
        historyPos = history.count
        scheduleHistorySave()
    }

    /// Изменения без записи в журнал (например, «Сравнить без LUT», пока зажата кнопка).
    func withoutHistory(_ f: () -> Void) {
        let was = historyPaused
        historyPaused = true
        f()
        historyPaused = was
    }

    // MARK: - Отмена и возврат

    var canUndo: Bool { historyPos > 0 }
    var canRedo: Bool { historyPos < history.count }
    var undoTitle: String? { canUndo ? history[historyPos - 1].title : nil }
    var redoTitle: String? { canRedo ? history[historyPos].title : nil }

    func undo() {
        guard canUndo else { flash("Нечего отменять"); return }
        let e = history[historyPos - 1]
        apply(e, forward: false)
        historyPos -= 1
        scheduleHistorySave()
        flash("Отменено: \(e.title)")
    }

    func redo() {
        guard canRedo else { flash("Нечего возвращать"); return }
        let e = history[historyPos]
        apply(e, forward: true)
        historyPos += 1
        scheduleHistorySave()
        flash("Возвращено: \(e.title)")
    }

    /// Перейти к состоянию «после шага n» (0 — исходное, до всех шагов журнала).
    func jumpHistory(to n: Int) {
        let target = min(max(n, 0), history.count)
        while historyPos > target { apply(history[historyPos - 1], forward: false); historyPos -= 1 }
        while historyPos < target { apply(history[historyPos], forward: true); historyPos += 1 }
        scheduleHistorySave()
    }

    private func apply(_ e: HistoryEntry, forward: Bool) {
        var touched: [URL] = []
        for (path, c) in e.changes {
            let id = URL(fileURLWithPath: path)
            guard let i = photos.firstIndex(where: { $0.id.path == path }) else { continue }
            let s = forward ? c.after : c.before
            let metaChanged = photos[i].rating != s.rating || photos[i].rejected != s.rejected || photos[i].label != s.label
            photos[i].adj = s.adj
            photos[i].rating = s.rating
            photos[i].rejected = s.rejected
            photos[i].label = s.label
            if metaChanged { try? Sidecar.write(.init(rating: s.rating, rejected: s.rejected, label: s.label), for: photos[i].url) }
            touched.append(id)
        }
        saveEditsSoon()
        // Показываем, что поменялось: если текущий кадр не затронут — встаём на затронутый.
        if let cur = currentID, !touched.contains(where: { $0.path == cur.path }), let first = touched.first {
            select(photos.first { $0.id.path == first.path } ?? photos[0])
        }
    }

    // MARK: - Подписи шагов

    /// «Экспозиция +0.35 EV», «Температура 5400 K»… — по первому изменённому параметру.
    func describeChange(_ a: Adjustments, _ b: Adjustments, url: URL) -> (title: String, key: String) {
        let k = ImageStore.shared.asShotK(url)
        let fields: [(String, KeyPath<Adjustments, Double>, (Double) -> String)] = [
            ("Экспозиция", \.exposure, { String(format: "%+.2f EV", $0) }),
            ("Температура", \.wbShift, { "\(Int(k + $0)) K" }),
            ("Оттенок", \.tint, { String(format: "%+.0f", $0) }),
            ("Контраст", \.contrast, { String(format: "%+.0f", $0) }),
            ("Света", \.highlights, { String(format: "%+.0f", $0) }),
            ("Тени", \.shadows, { String(format: "%+.0f", $0) }),
            ("Чёткость", \.clarity, { String(format: "%+.0f", $0) }),
            ("Матовость", \.fade, { String(format: "%.0f", $0) }),
            ("Красочность", \.vibrance, { String(format: "%+.0f", $0) }),
            ("Насыщенность", \.saturation, { String(format: "%+.0f", $0) }),
            ("Тонирование теней", \.shadowSat, { String(format: "%.0f", $0) }),
            ("Оттенок теней", \.shadowHue, { String(format: "%.0f°", $0) }),
            ("Тонирование светов", \.highlightSat, { String(format: "%.0f", $0) }),
            ("Оттенок светов", \.highlightHue, { String(format: "%.0f°", $0) }),
            ("Виньетка", \.vignette, { String(format: "%+.0f", $0) }),
            ("Зерно", \.grain, { String(format: "%.0f", $0) }),
            ("Сила LUT", \.lutAmount, { String(format: "%.0f%%", $0) }),
            ("Горизонт", \.angle, { String(format: "%+.1f°", $0) }),
        ]
        for (name, kp, fmt) in fields where a[keyPath: kp] != b[keyPath: kp] {
            return ("\(name) \(fmt(b[keyPath: kp]))", name)
        }
        if a.lut != b.lut { return ("LUT: " + (b.lut.map(LUTStore.displayName) ?? "убран"), "lut") }
        if a.profile != b.profile { return ("Профиль: " + (b.profile == .camera ? "как в камере" : "стандартный macOS"), "profile") }
        if a.cropRect != b.cropRect || a.cropAspect != b.cropAspect {
            return ("Кадрирование " + (CropFormat.byID(b.cropAspect)?.title ?? "свободное"), "crop")
        }
        return ("Обработка", "adj")
    }
}
