import CryptoKit
import Foundation

/// Folder analysis index: EXIF, similarity hash and sharpness for each file.
/// When a folder is reopened, only new and changed files are recomputed
/// (matched by size and modification time). Indexes live in ~/Library/Application Support/Kadr/Index;
/// nothing is written into photo folders, so it also works with read-only memory cards.
struct IndexEntry: Codable, Sendable {
    var size: Int64
    var mtime: Double
    var exif: ExifInfo
    var hash: UInt64?
    var sharpness: Double?
    var cull: CullData?
}

enum AnalysisIndex {
    static let version = 7   // 2: culling; 3: brightness; 4: face size, overexposed faces; 5: reliable-face threshold 180 px; 6: face mesh, head tilt; 7: JPEG from the image itself, not the 160 px EXIF thumbnail

    private struct File: Codable {
        var version: Int
        var folder: String
        var entries: [String: IndexEntry]
    }

    static var root: URL {
        let u = AppFolders.support.appendingPathComponent("Index", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func file(for dir: URL) -> URL {
        let digest = SHA256.hash(data: Data(dir.standardizedFileURL.path.utf8))
        return root.appendingPathComponent(digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".json")
    }

    static func load(_ dir: URL) -> [String: IndexEntry] {
        guard Prefs.indexEnabled else { return [:] }
        guard let d = try? Data(contentsOf: file(for: dir)),
              let f = try? JSONDecoder().decode(File.self, from: d), f.version == version else { return [:] }
        return f.entries
    }

    static func save(_ entries: [String: IndexEntry], for dir: URL) {
        guard Prefs.indexEnabled else { return }
        let f = File(version: version, folder: dir.standardizedFileURL.path, entries: entries)
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: file(for: dir), options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: root) }
}
