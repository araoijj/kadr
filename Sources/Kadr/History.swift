import AppKit
import CryptoKit
import Foundation

/// Undoable photo state: edits, crop, rating, rejection, label.
/// Only parameters are stored (non-destructive editing): hundreds of bytes per photo, not pixels.
struct PhotoState: Codable, Equatable {
    var adj: Adjustments
    var rating: Int
    var rejected: Bool
    var label: ColorLabel?
    var otherLabel: String?

    init(_ p: Photo) {
        adj = p.adj; rating = p.rating; rejected = p.rejected; label = p.label; otherLabel = p.otherLabel
    }
}

/// A single history step. Photo changes are stored only for the photos the step touched.
struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var key: String?                       // for merging movements of the same slider
    var changes: [String: Change]          // file path → before/after

    struct Change: Codable {
        var before: PhotoState
        var after: PhotoState
    }

    var photoNames: [String] { changes.keys.map { ($0 as NSString).lastPathComponent }.sorted() }
}

/// The folder's history on disk: ~/Library/Application Support/Kadr/History/<folder>.json, survives relaunch.
enum HistoryStore {
    /// How many steps we keep. Measured (20.10): a single-photo step is ~1.1 KB, record/undo ~0.1 ms;
    /// a batch step over 1000 photos is ~0.7 MB, and 100 of those is already 70 MB and 2.5 s to save.
    /// Hence two limits: 100 steps and no more than 20,000 photo changes in total (~14 MB, ~0.5 s in the background).
    static var limit: Int { Prefs.historyLimit }
    static var maxPhotoChanges: Int { limit * 200 }   // 100 steps → 20,000 photo changes (~14 MB)

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
        guard Prefs.historyKeep else { return ([], 0) }
        guard let d = try? Data(contentsOf: url(for: folder)), let f = try? JSONDecoder().decode(File.self, from: d) else { return ([], 0) }
        return (f.entries, min(f.position, f.entries.count))
    }

    static func save(_ entries: [HistoryEntry], _ position: Int, for folder: URL) {
        guard Prefs.historyKeep else { return }
        if let d = try? JSONEncoder().encode(File(entries: entries, position: position)) { try? d.write(to: url(for: folder), options: .atomic) }
    }
}

extension Library {
    // MARK: - Recording

    /// Snapshot of photo states before a change.
    func snapshot(_ ids: [URL]) -> [URL: PhotoState] {
        var out: [URL: PhotoState] = [:]
        for id in ids { if let p = photo(id) { out[id] = PhotoState(p) } }
        return out
    }

    /// Record a step: compares "before" with the current state, skipping unchanged photos.
    /// key merges steps: consecutive movements of the same slider on the same photo (within 1.5 s) become one step.
    func record(_ title: String, before: [URL: PhotoState], key: String? = nil) {
        guard !historyPaused else { return }
        var changes: [String: HistoryEntry.Change] = [:]
        for (id, b) in before {
            guard let p = photo(id) else { continue }
            let a = PhotoState(p)
            if a != b { changes[id.path] = .init(before: b, after: a) }
        }
        guard !changes.isEmpty else { return }
        // Undone steps after the current position can no longer be redone, as in any editor.
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
            // The oldest batch steps go first if the history has grown too large.
            while history.count > 1, history.reduce(0, { $0 + $1.changes.count }) > HistoryStore.maxPhotoChanges { history.removeFirst() }
        }
        historyPos = history.count
        scheduleHistorySave()
    }

    /// Changes without recording to history (e.g. "Compare without LUT" while the button is held).
    func withoutHistory(_ f: () -> Void) {
        let was = historyPaused
        historyPaused = true
        f()
        historyPaused = was
    }

    // MARK: - Undo and redo

    var canUndo: Bool { historyPos > 0 }
    var canRedo: Bool { historyPos < history.count }
    var undoTitle: String? { canUndo ? history[historyPos - 1].title : nil }
    var redoTitle: String? { canRedo ? history[historyPos].title : nil }

    func undo() {
        // The open crop is closed (and recorded) first: closing it inside apply() would record mid-step.
        // ⌘Z in the editor takes back only the crop itself: an untouched editor or a review suggestion just closes.
        if cropMode {
            let recorded = cropEdited && autoCropQueue.isEmpty
            closeCrop()
            guard recorded else { return }
        }
        guard canUndo else { flash(tr("Нечего отменять")); return }
        let e = history[historyPos - 1]
        let failed = apply(e, forward: false)
        historyPos -= 1
        scheduleHistorySave()
        flashWritten(tr("Отменено: \(e.title)"), failed: failed)
    }

    func redo() {
        closeCrop()
        guard canRedo else { flash(tr("Нечего возвращать")); return }
        let e = history[historyPos]
        let failed = apply(e, forward: true)
        historyPos += 1
        scheduleHistorySave()
        flashWritten(tr("Возвращено: \(e.title)"), failed: failed)
    }

    /// Go to the state "after step n" (0 = original, before all history steps).
    func jumpHistory(to n: Int) {
        closeCrop()
        let target = min(max(n, 0), history.count)
        var failed = 0
        while historyPos > target { failed += apply(history[historyPos - 1], forward: false); historyPos -= 1 }
        while historyPos < target { failed += apply(history[historyPos], forward: true); historyPos += 1 }
        scheduleHistorySave()
        if failed > 0 { flash(tr("Не удалось записать XMP: \(failed) шт."), seconds: 4) }
    }

    /// Returns how many XMP files could not be written.
    @discardableResult
    private func apply(_ e: HistoryEntry, forward: Bool) -> Int {
        var touched: [URL] = []
        var failed = 0
        for (path, c) in e.changes {
            let id = URL(fileURLWithPath: path)
            guard let i = index[id] ?? photos.firstIndex(where: { $0.id.path == path }) else { continue }
            let s = forward ? c.after : c.before
            // The foreign label is restored only by steps that changed it: steps saved before it was
            // tracked carry nil there and must not wipe an Orange label read from the file.
            let otherStep = c.before.otherLabel != c.after.otherLabel
            var fields: Sidecar.Fields = []
            if photos[i].rating != s.rating || photos[i].rejected != s.rejected { fields.insert(.rating) }
            if photos[i].label != s.label || (otherStep && photos[i].otherLabel != s.otherLabel) { fields.insert(.label) }
            photos[i].adj = s.adj
            photos[i].rating = s.rating
            photos[i].rejected = s.rejected
            photos[i].label = s.label
            if otherStep { photos[i].otherLabel = s.otherLabel }
            if !fields.isEmpty && !writeSidecar(i, fields) { failed += 1 }
            touched.append(photos[i].id)
        }
        saveEditsSoon(touched)
        // Show what changed: if the current photo isn't affected, move to an affected one.
        if let cur = currentID, !touched.contains(where: { $0.path == cur.path }), let first = touched.first {
            select(photo(first) ?? photos.first { $0.id.path == first.path } ?? photos[0])
        }
        return failed
    }

    // MARK: - Step labels

    /// "Exposure +0.35 EV", "Temperature 5400 K"…, based on the first changed parameter.
    func describeChange(_ a: Adjustments, _ b: Adjustments, url: URL) -> (title: String, key: String) {
        let k = ImageStore.shared.asShotK(url)
        let fields: [(String, KeyPath<Adjustments, Double>, (Double) -> String)] = [
            (tr("Экспозиция"), \.exposure, { String(format: "%+.2f EV", $0) }),
            (tr("Температура"), \.wbShift, { "\(Int(k + $0)) K" }),
            (tr("Оттенок"), \.tint, { String(format: "%+.0f", $0) }),
            (tr("Контраст"), \.contrast, { String(format: "%+.0f", $0) }),
            (tr("Света"), \.highlights, { String(format: "%+.0f", $0) }),
            (tr("Тени"), \.shadows, { String(format: "%+.0f", $0) }),
            (tr("Чёткость"), \.clarity, { String(format: "%+.0f", $0) }),
            (tr("Матовость"), \.fade, { String(format: "%.0f", $0) }),
            (tr("Красочность"), \.vibrance, { String(format: "%+.0f", $0) }),
            (tr("Насыщенность"), \.saturation, { String(format: "%+.0f", $0) }),
            (tr("Тонирование теней"), \.shadowSat, { String(format: "%.0f", $0) }),
            (tr("Оттенок теней"), \.shadowHue, { String(format: "%.0f°", $0) }),
            (tr("Тонирование светов"), \.highlightSat, { String(format: "%.0f", $0) }),
            (tr("Оттенок светов"), \.highlightHue, { String(format: "%.0f°", $0) }),
            (tr("Виньетка"), \.vignette, { String(format: "%+.0f", $0) }),
            (tr("Зерно"), \.grain, { String(format: "%.0f", $0) }),
            (tr("Сила LUT"), \.lutAmount, { String(format: "%.0f%%", $0) }),
            (tr("Горизонт"), \.angle, { String(format: "%+.1f°", $0) }),
        ]
        for (name, kp, fmt) in fields where a[keyPath: kp] != b[keyPath: kp] {
            return ("\(name) \(fmt(b[keyPath: kp]))", name)
        }
        if a.lut != b.lut { return ("LUT: " + (b.lut.map(LUTStore.displayName) ?? tr("убран")), "lut") }
        if a.profile != b.profile { return (tr("Профиль: ") + (b.profile == .camera ? tr("как в камере") : tr("стандартный macOS")), "profile") }
        if a.cropRect != b.cropRect || a.cropAspect != b.cropAspect {
            return (tr("Кадрирование ") + (CropFormat.byID(b.cropAspect)?.title ?? tr("свободное")), "crop")
        }
        return (tr("Обработка"), "adj")
    }
}
