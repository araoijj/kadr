import AppKit
import Observation

/// A photo on a memory card.
struct CardFile: Sendable {
    let url: URL
    let size: Int64
    let date: Date      // capture time from EXIF, or the file's modification time if missing
    var sidecars: [URL] = []   // XMP files on the card with the same base name, copied along
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
        let date = DateFormatter.isoDay.string(from: day)
        let name = shootName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return name.isEmpty ? date : "\(date) \(name)"
    }

    /// File name without extension(s): "IMG_0001" for IMG_0001.CR3, IMG_0001.xmp and IMG_0001.CR3.xmp.
    nonisolated static func baseName(_ u: URL) -> String {
        var b = u.deletingPathExtension()
        if u.pathExtension.lowercased() == "xmp", ImageStore.imageExtensions.contains(b.pathExtension.lowercased()) {
            b = b.deletingPathExtension()
        }
        return b.lastPathComponent
    }

    /// Files of one frame (RAW, its JPEG, XMP) share a folder and a base name.
    nonisolated static func groupKey(_ u: URL) -> String {
        u.deletingLastPathComponent().path + "/" + baseName(u).lowercased()
    }

    /// The name with a suffix after the base: IMG_0001.CR3.xmp → IMG_0001-2.CR3.xmp.
    nonisolated static func name(_ u: URL, suffix: String) -> String {
        let base = baseName(u)
        return base + suffix + u.lastPathComponent.dropFirst(base.count)
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
        var xmps: [String: [URL]] = [:]
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let u = en?.nextObject() as? URL {
            let ext = u.pathExtension.lowercased()
            guard ext == "xmp" || ImageStore.imageExtensions.contains(ext),
                  let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            // Ratings set in the camera or another app live in XMP next to the photo.
            if ext == "xmp" { xmps[groupKey(u), default: []].append(u); continue }
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
            .map { CardFile(url: $1.0, size: $1.1, date: dates[$0] ?? $1.2, sidecars: xmps[groupKey($1.0)] ?? []) }
            .sorted { $0.date < $1.date }
    }

    /// How many photos on the card haven't been imported yet (the same check as "Only new").
    nonisolated static func newCount(on volume: URL) -> Int {
        let root = isCameraCard(volume) ? volume.appendingPathComponent("DCIM") : volume
        let done = loadRegistry()
        return listFiles(root).filter { !done.contains($0.key) }.count
    }

    // MARK: - Copying

    /// Copies, verifies, marks as imported. When finished, calls done with the folder to open.
    func start(done: @escaping (URL) -> Void) {
        let list = toCopy
        guard !list.isEmpty, !copying else { return }
        // Without "by days" everything goes into the first day's folder: computed once, not per file.
        let firstDay = days.first
        let base = baseFolder, split = splitByDay
        func dir(for date: Date) -> URL {
            let day = Calendar.current.startOfDay(for: split ? date : (firstDay ?? date))
            return base.appendingPathComponent(folderName(for: day), isDirectory: true)
        }
        // RAW + JPEG (+ XMP) of one frame are copied together so they get the same suffix.
        var groups: [String: [CardFile]] = [:], order: [String] = []
        for f in list {
            let k = CardImporter.groupKey(f.url)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(f)
        }
        let plan = order.map { k in (groups[k]!, dir(for: groups[k]!.map(\.date).min()!)) }
        let openFolder = Set(plan.map(\.1)).count == 1 ? plan[0].1 : baseFolder
        let eject = ejectAfter, volume = source
        copying = true
        result = nil
        bytesDone = 0
        bytesTotal = list.reduce(0) { $0 + $1.size }
        task = Task {
            var copied = 0, skipped = 0, failed = 0
            for (group, dir) in plan {
                if Task.isCancelled { break }
                let (photos, sidecarsOK) = await Task.detached(priority: .userInitiated) { CardImporter.copy(group, to: dir) }.value
                if !sidecarsOK { failed += 1 }
                for (file, outcome) in zip(group, photos) {
                    switch outcome {
                    case .copied: copied += 1
                    case .exists: skipped += 1
                    case .failed: failed += 1
                    }
                    // Only what is really in the shoot counts as imported; a lost XMP means retry the frame next time.
                    if outcome != .failed, sidecarsOK { imported.insert(file.key) }
                    bytesDone += file.size
                }
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

    /// Copies one frame's files under a single suffix. Never overwrites or deletes anything existing.
    /// Returns an outcome per photo and whether all its XMP files are in place.
    nonisolated static func copy(_ group: [CardFile], to dir: URL) -> ([Outcome], Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = baseName(group[0].url), date = group.map(\.date).min() ?? Date()
        // Kadr and Capture One read IMG.xmp: a card's IMG.CR3.xmp is stored under that name
        // (the RAW's one if there are several), unless the card has a plain IMG.xmp as well.
        let sidecars = Set(group.flatMap(\.sidecars)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let doubled = { (x: URL) in ImageStore.imageExtensions.contains(x.deletingPathExtension().pathExtension.lowercased()) }
        let renamed = sidecars.allSatisfy(doubled)
            ? sidecars.first { ImageStore.rawExtensions.contains($0.deletingPathExtension().pathExtension.lowercased()) } ?? sidecars.first
            : nil
        func xmpName(_ x: URL, _ suffix: String) -> String {
            x == renamed ? base + suffix + ".xmp" : name(x, suffix: suffix)
        }
        // The first suffix where every photo's name is free or already holds this very file.
        // Same frame number from another card/camera, or another DCIM folder: next suffix for the whole frame.
        // XMP files don't vote: the copy in the shoot may have been rated since.
        var suffix = "", n = 1, present: [Bool] = []
        while true {
            present = []
            for f in group {
                let t = dir.appendingPathComponent(name(f.url, suffix: suffix))
                if !fm.fileExists(atPath: t.path) { present.append(false) }
                else if sameContent(f.url, t, size: f.size) { present.append(true) }
                else { break }
            }
            // The frame's other photo is already here from an earlier import (its RAW, the JPEG not copied
            // then or deleted since), shot at the same moment: the XMP is that photo's, and this one joins it.
            func joinsSibling() -> Bool {
                let ours = Set(group.map { name($0.url, suffix: suffix).lowercased() })
                return ImageStore.imageExtensions.contains { e in
                    [e, e.uppercased()].contains { ext in
                        let u = dir.appendingPathComponent(base + suffix + "." + ext)
                        guard !ours.contains(u.lastPathComponent.lowercased()), fm.fileExists(atPath: u.path) else { return false }
                        return ImageStore.shared.exif(u).date.map { abs($0.timeIntervalSince(date)) <= 2 } ?? true
                    }
                }
            }
            // All of the frame's photos new here, yet an XMP of its name is there: an orphan whose photo was
            // deleted. Under this name the frame would get that stale XMP instead of the card's: next suffix.
            func orphanXMP() -> Bool {
                let fromCard = sidecars.contains { x in
                    let t = dir.appendingPathComponent(xmpName(x, suffix))
                    let size = Int64((try? x.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                    return fm.fileExists(atPath: t.path) && !sameContent(x, t, size: size)
                }
                let cardNames = Set(sidecars.map { xmpName($0, suffix).lowercased() })
                return fromCard || group.contains { f in
                    let x = Sidecar.url(for: dir.appendingPathComponent(name(f.url, suffix: suffix)))
                    return !cardNames.contains(x.lastPathComponent.lowercased()) && fm.fileExists(atPath: x.path)
                }
            }
            if present.count == group.count, present.contains(true) || joinsSibling() || !orphanXMP() { break }
            n += 1
            suffix = "-\(n)"
        }
        let photos = zip(group, present).map { f, there in
            there ? Outcome.exists : copyVerified(f.url, to: dir.appendingPathComponent(name(f.url, suffix: suffix)), size: f.size)
        }
        var sidecarsOK = true
        for x in sidecars {
            let t = dir.appendingPathComponent(xmpName(x, suffix))
            if fm.fileExists(atPath: t.path) { continue }
            let size = Int64((try? x.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            if copyVerified(x, to: t, size: size) == .failed { sidecarsOK = false }
        }
        return (photos, sidecarsOK)
    }

    private nonisolated static func copyVerified(_ src: URL, to target: URL, size: Int64) -> Outcome {
        do {
            try FileManager.default.copyItem(at: src, to: target)   // throws if the name got taken: no overwrite
            guard sameContent(src, target, size: size) else { try? FileManager.default.removeItem(at: target); return .failed }
            return .copied
        } catch {
            return .failed
        }
    }

    /// Same size and the same bytes at the start, middle and end (1 MB each). Tells apart different shots,
    /// even uncompressed RAWs of equal size (header with time and shot counter, sensor data),
    /// without reading whole files off the card.
    nonisolated static func sameContent(_ a: URL, _ b: URL, size: Int64) -> Bool {
        guard let v = try? b.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true,
              Int64(v.fileSize ?? -1) == size,
              let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        let chunk: Int64 = 1 << 20
        for offset in Set([0, max(0, size / 2 - chunk / 2), max(0, size - chunk)]) {
            do {
                try ha.seek(toOffset: UInt64(offset))
                try hb.seek(toOffset: UInt64(offset))
                guard try ha.read(upToCount: Int(chunk)) == hb.read(upToCount: Int(chunk)) else { return false }
            } catch {
                return false
            }
        }
        return true
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
