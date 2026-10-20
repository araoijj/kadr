import Foundation
import Observation

/// A free LUT collection that can be downloaded right from Kadr.
struct LUTCollection: Sendable {
    let folder: String
    let title: String
    let author: String
    let license: String
    let page: URL
    let listAPI: URL        // GitHub API: contents of the HaldCLUT folder
    let licenseRaw: URL
    let filePrefix: String

    /// 51 film emulations by João Almeida, MIT. https://github.com/t3mujin/t3mujinpack
    static let t3mujin = LUTCollection(
        folder: "t3mujinpack",
        title: tr("Плёнка: t3mujinpack"),
        author: "João Almeida",
        license: "MIT",
        page: URL(string: "https://github.com/t3mujin/t3mujinpack")!,
        listAPI: URL(string: "https://api.github.com/repos/t3mujin/t3mujinpack/contents/haldcluts")!,
        licenseRaw: URL(string: "https://raw.githubusercontent.com/t3mujin/t3mujinpack/master/LICENSE.txt")!,
        filePrefix: "t3mujinpack - "
    )

    static let all = [t3mujin]

    var localFolder: URL { AppFolders.luts.appendingPathComponent(folder, isDirectory: true) }

    var installedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: localFolder.path)) ?? []).filter { $0.hasSuffix(".png") }.count
    }
}

@MainActor
@Observable
final class CollectionDownloader {
    var busy = false
    var done = 0
    var total = 0
    var message: String?
    private var task: Task<Void, Never>?

    func download(_ c: LUTCollection, then finish: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        done = 0
        total = 0
        task = Task {
            do {
                try FileManager.default.createDirectory(at: c.localFolder, withIntermediateDirectories: true)
                let (listData, _) = try await URLSession.shared.data(from: c.listAPI)
                struct Item: Decodable { let name: String; let download_url: String? }
                let items = try JSONDecoder().decode([Item].self, from: listData)
                    .filter { $0.name.hasPrefix(c.filePrefix) && $0.name.hasSuffix(".png") }
                total = items.count
                var failed = 0
                for it in items {
                    if Task.isCancelled { break }
                    let dest = c.localFolder.appendingPathComponent(it.name)
                    if !FileManager.default.fileExists(atPath: dest.path), let s = it.download_url, let u = URL(string: s) {
                        do {
                            let (tmp, resp) = try await URLSession.shared.download(from: u)
                            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                            try FileManager.default.moveItem(at: tmp, to: dest)
                        } catch { failed += 1 }
                    }
                    done += 1
                }
                // License and attribution go next to the files.
                if let (lic, _) = try? await URLSession.shared.data(from: c.licenseRaw) {
                    try? lic.write(to: c.localFolder.appendingPathComponent("LICENSE.txt"))
                }
                let about = tr("\(c.title)\nАвтор: \(c.author)\nЛицензия: \(c.license)\nИсточник: \(c.page.absoluteString)\n")
                try? about.write(to: c.localFolder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
                message = failed == 0 ? tr("Скачано: \(done) LUT") : tr("Скачано \(done - failed), ошибок: \(failed)")
            } catch {
                message = tr("Не удалось скачать: \(error.localizedDescription)")
            }
            busy = false
            finish()
        }
    }

    func cancel() { task?.cancel() }
}
