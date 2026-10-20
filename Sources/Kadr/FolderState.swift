import Foundation

/// Per-folder view state: the photo you stopped at, the filter and the mode (grid / loupe / Culling),
/// restored when the folder is opened again. Kept in UserDefaults, at most 200 folders.
struct FolderState: Codable {
    var current: String?
    var filter: String?
    var mode: String?          // "grid", "loupe", "cull"
    var date = Date()

    private static let key = "folderStates"

    static func load(_ folder: URL) -> FolderState? {
        all()[folder.standardizedFileURL.path]
    }

    static func save(_ s: FolderState, for folder: URL) {
        var a = all()
        a[folder.standardizedFileURL.path] = s
        if a.count > 200 {
            for k in a.sorted(by: { $0.value.date < $1.value.date }).prefix(a.count - 200).map(\.key) { a[k] = nil }
        }
        if let d = try? JSONEncoder().encode(a) { Prefs.d.set(d, forKey: key) }
    }

    private static func all() -> [String: FolderState] {
        guard let d = Prefs.d.data(forKey: key), let a = try? JSONDecoder().decode([String: FolderState].self, from: d) else { return [:] }
        return a
    }
}

extension PhotoFilter {
    /// Short code for storing; AI queues, scene and reason filters depend on the analysis and aren't restored.
    var code: String? {
        switch self {
        case .all: "all"
        case .unrated: "unrated"
        case .picked: "picked"
        case .rejected: "rejected"
        case .best: "best"
        case .duplicates: "duplicates"
        case .undecided: "undecided"
        case .stars(let n): "stars:\(n)"
        case .label(let l): "label:\(l.rawValue)"
        default: nil
        }
    }

    init?(code: String) {
        let p = code.split(separator: ":", maxSplits: 1).map(String.init)
        switch p[0] {
        case "all": self = .all
        case "unrated": self = .unrated
        case "picked": self = .picked
        case "rejected": self = .rejected
        case "best": self = .best
        case "duplicates": self = .duplicates
        case "undecided": self = .undecided
        case "suspects": self = .suspects
        case "leaders": self = .leaders
        case "stars": guard p.count > 1, let n = Int(p[1]) else { return nil }; self = .stars(n)
        case "label": guard p.count > 1, let l = ColorLabel(rawValue: p[1]) else { return nil }; self = .label(l)
        default: return nil
        }
    }
}

extension Library {
    /// Remembers where you stopped in the open folder.
    func saveFolderState() {
        guard let folder else { return }
        let mode = culling ? "cull" : loupe ? "loupe" : "grid"
        FolderState.save(FolderState(current: current?.url.lastPathComponent, filter: filter.code, mode: mode), for: folder)
    }

    /// Back to the photo, filter and mode you left the folder with.
    func restoreFolderState(_ url: URL) {
        guard let s = FolderState.load(url) else { return }
        if let c = s.filter, let f = PhotoFilter(code: c) { filter = f }
        switch s.mode {
        case "cull": culling = true
        case "loupe": loupe = true
        default: break
        }
        if let name = s.current, let p = visible.first(where: { $0.url.lastPathComponent == name }) ?? photos.first(where: { $0.url.lastPathComponent == name }) {
            if !visible.contains(where: { $0.id == p.id }) { filter = .all }
            select(p)
        }
    }
}
