import AppKit
import SwiftUI

/// Optional heavy AI models, downloaded on demand (not bundled, to keep the app small).
enum ModelPackage: String, CaseIterable, Identifiable {
    case faceID, denoise, retouch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .faceID: tr("Люди: распознавание лиц")
        case .denoise: tr("AI-шумоподавление")
        case .retouch: tr("Убрать объект")
        }
    }

    var detail: String {
        switch self {
        case .faceID: tr("SFace (OpenCV Zoo, Apache 2.0) — фильтр «Люди»")
        case .denoise: tr("SCUNet (Apache 2.0) — ~1 минута на кадр 24 Мп, на видеокарте")
        case .retouch: tr("SAM 2.1 (Meta, Apache 2.0; Core ML — Apple) + LaMa (Apache 2.0)")
        }
    }

    var size: String {
        switch self {
        case .faceID: tr("18 МБ")
        case .denoise: tr("77 МБ")
        case .retouch: tr("300 МБ")
        }
    }

    var installed: Bool {
        switch self {
        case .faceID: FaceID.shared.installed
        case .denoise: Denoiser.shared.installed
        case .retouch: Retouch.shared.installed
        }
    }

    /// Archive in the Kadr repository releases (models with their licenses).
    var url: URL { URL(string: "https://github.com/araoijj/kadr/releases/download/models-2/kadr-\(rawValue)-1.zip")! }

    /// Installs from an unpacked folder (or a single .mlpackage).
    func install(from dir: URL) throws {
        switch self {
        case .faceID:
            guard let p = Self.find(in: dir, named: FaceID.modelName) ?? Self.find(in: dir, named: "sface") else { throw CocoaError(.fileNoSuchFile) }
            try FaceID.shared.install(from: p)
        case .denoise:
            guard let p = Self.find(in: dir, prefix: "scunet") else { throw CocoaError(.fileNoSuchFile) }
            try Denoiser.shared.install(from: p)
        case .retouch:
            try Retouch.shared.install(from: dir)
        }
    }

    private static func find(in dir: URL, named n: String) -> URL? { find(in: dir) { $0 == n } }
    private static func find(in dir: URL, prefix: String) -> URL? { find(in: dir) { $0.hasPrefix(prefix) } }
    private static func find(in dir: URL, _ match: (String) -> Bool) -> URL? {
        if dir.pathExtension == "mlpackage" { return dir }
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = en?.nextObject() as? URL {
            if u.pathExtension == "mlpackage", match(u.deletingPathExtension().lastPathComponent) { return u }
        }
        return nil
    }
}

struct ModelPackagesSection: View {
    @Environment(Library.self) private var lib
    @State private var busy: ModelPackage?
    @State private var error: String?
    @State private var refresh = 0

    var body: some View {
        Section {
            ForEach(ModelPackage.allCases) { m in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title)
                        Text(m.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy == m { ProgressView().controlSize(.small) }
                    else if m.installed { Label(tr("установлен"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                    else {
                        Button(tr("Скачать · \(m.size)")) { download(m) }.disabled(busy != nil)
                        Button(tr("Из файла…")) { pick(m) }.disabled(busy != nil)
                    }
                }
                .id("\(m.id)-\(refresh)")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text(tr("Пакеты моделей"))
        } footer: {
            Text(tr("Тяжёлые модели ставятся по желанию и хранятся в папке данных «Кадра». Работают офлайн, на этом Mac.")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func finish(_ m: ModelPackage, _ dir: URL?, _ err: Error?) {
        if let dir {
            do { try m.install(from: dir); error = nil; if m == .faceID { lib.aiModulesChanged() } }
            catch { self.error = tr("Не удалось установить: \(error.localizedDescription)") }
        } else if let err { error = tr("Не удалось скачать: \(err.localizedDescription)") }
        busy = nil; refresh += 1
    }

    private func download(_ m: ModelPackage) {
        busy = m; error = nil
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: m.url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kadr-\(m.rawValue)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", tmp.path, dir.path]
                try p.run(); p.waitUntilExit()
                finish(m, dir, nil)
                try? FileManager.default.removeItem(at: dir)
            } catch { finish(m, nil, error) }
        }
    }

    private func pick(_ m: ModelPackage) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowedContentTypes = [.zip, .package, .folder]
        p.message = tr("Папка или .zip с моделями пакета «\(m.title)»")
        guard p.runModal() == .OK, let u = p.url else { return }
        busy = m
        if u.pathExtension.lowercased() == "zip" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kadr-\(m.rawValue)-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); pr.arguments = ["-x", "-k", u.path, dir.path]
            try? pr.run(); pr.waitUntilExit()
            finish(m, dir, nil)
            try? FileManager.default.removeItem(at: dir)
        } else { finish(m, u, nil) }
    }
}
