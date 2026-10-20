import CryptoKit
import Foundation

/// Индекс анализа папки: EXIF, хэш похожести и резкость для каждого файла.
/// При повторном открытии папки пересчитываются только новые и изменённые файлы
/// (сверка по размеру и времени изменения). Индексы лежат в ~/Library/Application Support/Kadr/Index —
/// в папки со снимками ничего не пишется, работает и с карт памяти «только для чтения».
struct IndexEntry: Codable, Sendable {
    var size: Int64
    var mtime: Double
    var exif: ExifInfo
    var hash: UInt64?
    var sharpness: Double?
    var cull: CullData?
}

enum AnalysisIndex {
    static let version = 7   // 2 — отбор; 3 — яркость; 4 — размер лиц, пересвет на лице; 5 — порог надёжного лица 180 px; 6 — сетка лица, наклон головы; 7 — JPEG по самой картинке, а не по миниатюре EXIF 160 px

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

    /// Сколько места занимают индексы и сколько папок в них.
    static func usage() -> (folders: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return (files.count, files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }

    static func clear() { try? FileManager.default.removeItem(at: root) }
}
