import AppKit
import Observation

/// A photo on a memory card.
struct CardFile: Sendable {
    let url: URL
    let size: Int64
    let date: Date      // capture time from EXIF, or the file's modification time if missing
    var key: String { "\(url.lastPathComponent)|\(size)|\(Int(date.timeIntervalSince1970))" }
}

/// Memory card import: DCIM scan, verified copying, tracking of already imported files.
@MainActor
@Observable
final class CardImporter {
    // Settings, remembered.
    var baseFolder: URL = {
        if let p = UserDefaults.standard.string(forKey: "import.base") { return URL(fileURLWithPath: p) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shoots = home.appendingPathComponent("Documents/Фотосессии")
        return FileManager.default.fileExists(atPath: shoots.path) ? shoots : home.appendingPathComponent("Pictures")
    }() { didSet { UserDefaults.standard.set(baseFolder.path, forKey: "import.base") } }
    var splitByDay = UserDefaults.standard.object(forKey: "import.split") as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitByDay, forKey: "import.split") }
    }
    var onlyNew = UserDefaults.standard.object(forKey: "import.onlyNew") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlyNew, forKey: "import.onlyNew") }
    }
    var ejectAfter = UserDefaults.standard.bool(forKey: "import.eject") {
        didSet { UserDefaults.standard.set(ejectAfter, forKey: "import.eject") }
    }
    var shootName = ""

    // State.
    var source: URL?
    var files: [CardFile] = []
    var scanning = false
    var copying = false
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var result: String?
    private var task: Task<Void, Never>?
    private var imported: Set<String> = CardImporter.loadRegistry()

    var newFiles: [CardFile] { files.filter { !imported.contains($0.key) } }
    var toCopy: [CardFile] { onlyNew ? newFiles : files }
    var days: [Date] { Array(Set(toCopy.map { Calendar.current.startOfDay(for: $0.date) })).sorted() }

    /// Shoot folder for a day: "2026-10-20 Wedding".
    func folderName(for day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let name = shootName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return name.isEmpty ? f.string(from: day) : "\(f.string(from: day)) \(name)"
    }

    func destination(for file: CardFile) -> URL {
        let day = Calendar.current.startOfDay(for: splitByDay ? file.date : (days.first ?? file.date))
        return baseFolder.appendingPathComponent(folderName(for: day), isDirectory: true)
    }

    // MARK: - Card

    /// Whether this looks like a camera card: there's a DCIM folder at the root.
    nonisolated static func isCameraCard(_ volume: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &dir) && dir.boolValue
    }

    func scan(_ url: URL) {
        task?.cancel()
        source = url
        files = []
        result = nil
        scanning = true
        let root = CardImporter.isCameraCard(url) ? url.appendingPathComponent("DCIM") : url
        task = Task {
            let found = await Task.detached(priority: .userInitiated) { CardImporter.listFiles(root) }.value
            guard !Task.isCancelled else { return }
            files = found
            scanning = false
        }
    }

    nonisolated static func listFiles(_ root: URL) -> [CardFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var found: [(URL, Int64, Date)] = []
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let u = en?.nextObject() as? URL {
            guard ImageStore.imageExtensions.contains(u.pathExtension.lowercased()),
                  let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            found.append((u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? Date()))
        }
        // Read EXIF in parallel: only the file header, a few ms per photo even from a card.
        var dates = [Date?](repeating: nil, count: found.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            let d = ImageStore.shared.exif(found[i].0).date
            lock.lock(); dates[i] = d; lock.unlock()
        }
        return found.enumerated()
            .map { CardFile(url: $1.0, size: $1.1, date: dates[$0] ?? $1.2) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Copying

    /// Copies, verifies size, marks as imported. When finished, calls done with the folder to open.
    func start(done: @escaping (URL) -> Void) {
        let list = toCopy
        guard !list.isEmpty, !copying else { return }
        let plan = list.map { ($0, destination(for: $0)) }
        let openFolder = Set(plan.map(\.1)).count == 1 ? plan[0].1 : baseFolder
        let eject = ejectAfter, volume = source
        copying = true
        result = nil
        bytesDone = 0
        bytesTotal = list.reduce(0) { $0 + $1.size }
        task = Task {
            var copied = 0, skipped = 0, failed = 0
            for (file, dir) in plan {
                if Task.isCancelled { break }
                let outcome = await Task.detached(priority: .userInitiated) { CardImporter.copy(file, to: dir) }.value
                switch outcome {
                case .copied: copied += 1; imported.insert(file.key)
                case .exists: skipped += 1; imported.insert(file.key)
                case .failed: failed += 1
                }
                bytesDone += file.size
            }
            CardImporter.saveRegistry(imported)
            copying = false
            var msg = tr("Импортировано: \(copied)")
            if skipped > 0 { msg += tr(", уже были: \(skipped)") }
            if failed > 0 { msg += tr(", ошибок: \(failed)") }
            if Task.isCancelled { msg = tr("Остановлено. ") + msg }
            result = msg
            if copied + skipped > 0 { done(openFolder) }
            if eject, failed == 0, !Task.isCancelled, let volume {
                try? await NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }
    }

    func cancel() { task?.cancel() }

    enum Outcome: Sendable { case copied, exists, failed }

    nonisolated static func copy(_ f: CardFile, to dir: URL) -> Outcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appendingPathComponent(f.url.lastPathComponent)
        if let s = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            if Int64(s) == f.size { return .exists }
            // Same frame number from another card/camera: don't overwrite.
            let base = f.url.deletingPathExtension().lastPathComponent, ext = f.url.pathExtension
            var n = 2
            repeat { target = dir.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1 } while fm.fileExists(atPath: target.path)
        }
        do {
            try fm.copyItem(at: f.url, to: target)
            let s = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard Int64(s) == f.size else { try? fm.removeItem(at: target); return .failed }
            return .copied
        } catch {
            return .failed
        }
    }

    // MARK: - Tracking imported files (by name, size and file time)

    private nonisolated static var registryURL: URL { AppFolders.support.appendingPathComponent("imported.json") }

    private nonisolated static func loadRegistry() -> Set<String> {
        guard let d = try? Data(contentsOf: registryURL), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }

    private nonisolated static func saveRegistry(_ s: Set<String>) {
        if let d = try? JSONEncoder().encode(Array(s)) { try? d.write(to: registryURL, options: .atomic) }
    }
}
