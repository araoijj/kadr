import AppKit
import CryptoKit
import SwiftUI

/// Where a model comes from: shown in Settings next to each package, and in the NOTICE inside its archive.
struct ModelSource: Identifiable {
    var id: String { name }
    let name: String
    let author: String
    let license: String
    let link: URL
    let change: String
}

/// SHA-256 of the published archives. A download that doesn't match is never installed (a swapped or broken
/// file); a file chosen by hand that doesn't match is installed only after an explicit confirmation —
/// e.g. models rebuilt from the originals with tools/convert.
enum ModelChecksum {
    static let facemesh = "3712b88b9634b2db4e28a99991024253e7abb9ca71059b3405ef8c93fb52a425"

    /// Streams the file, so a 270 MB archive doesn't land in memory.
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ url: URL, _ expected: String) async -> Bool {
        (try? await Task.detached(priority: .userInitiated) { try sha256(of: url) }.value) == expected
    }

    /// Asks before installing something that isn't the published archive (another zip, a folder or .mlpackage).
    @MainActor static func confirmUnverified(_ name: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = tr("Файл не совпадает с опубликованным архивом")
        a.informativeText = tr("Контрольная сумма не совпала с архивом «\(name)» из выпуска «Кадра». Устанавливайте, только если собрали модели сами (tools/convert) или знаете, откуда этот файл.")
        a.addButton(withTitle: tr("Отмена"))
        a.addButton(withTitle: tr("Установить всё равно"))
        return a.runModal() == .alertSecondButtonReturn
    }

    static func short(_ sha: String) -> String { String(sha.prefix(16)) + "…" }
}

extension FaceMesh {
    static let sources = [
        ModelSource(name: "MediaPipe Face Landmarker", author: "Google", license: "Apache 2.0",
                    link: URL(string: "https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker")!,
                    change: tr("переведена из TFLite в Core ML, веса не менялись")),
    ]
}

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

    /// Download size of the archive.
    var size: String {
        switch self {
        case .faceID: tr("18 МБ")
        case .denoise: tr("33 МБ")
        case .retouch: tr("269 МБ")
        }
    }

    /// SHA-256 of `url`'s archive (see ModelChecksum).
    var sha256: String {
        switch self {
        case .faceID: "37810d0f78963e3a86ae0ef7c9d7b13dc207a20bf20f180cb132fd906073c800"
        case .denoise: "bae2731570f07672ff79d6f002f74def4d7519310af54572a1fdf9c44bbcd315"
        case .retouch: "0223c1ab0d373e7d7f974878568066e4e7fd9741b6d863ca98b86e5ff3b61fe4"
        }
    }

    var sources: [ModelSource] {
        switch self {
        case .faceID: [
            ModelSource(name: "SFace", author: "Yaoyao Zhong et al., OpenCV Zoo", license: "Apache 2.0",
                        link: URL(string: "https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface")!,
                        change: tr("переведена из ONNX в Core ML, веса не менялись; ответы совпадают с оригиналом")),
        ]
        case .denoise: [
            ModelSource(name: "SCUNet", author: "Kai Zhang et al.", license: "Apache 2.0",
                        link: URL(string: "https://github.com/cszn/SCUNet")!,
                        change: tr("переведена из PyTorch в Core ML (плитка 512×512), веса не менялись; расхождение с оригиналом не больше 0,05%")),
        ]
        case .retouch: [
            ModelSource(name: "SAM 2.1 Small", author: tr("Meta; Core ML — Apple"), license: "Apache 2.0",
                        link: URL(string: "https://huggingface.co/apple/coreml-sam2.1-small")!,
                        change: tr("без изменений — файлы Apple как есть")),
            ModelSource(name: "LaMa", author: tr("Samsung AI (advimman/lama); Core ML — mlboydaisuke"), license: "Apache 2.0",
                        link: URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML")!,
                        change: tr("без изменений; обучена на датасете Places")),
        ]
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
                        ModelSourcesView(sources: m.sources, sha256: m.sha256)
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
            Text(tr("Тяжёлые модели ставятся по желанию и хранятся в папке данных «Кадра». Работают офлайн, на этом Mac. Скачанный архив сверяется по контрольной сумме: подменённый или битый файл не установится.")).font(.caption).foregroundStyle(.secondary)
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
                guard await ModelChecksum.matches(tmp, m.sha256) else {
                    try? FileManager.default.removeItem(at: tmp)
                    error = tr("Скачанный архив не совпал по контрольной сумме — не установлен. Попробуйте ещё раз позже.")
                    busy = nil; return
                }
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
        busy = m; error = nil
        Task {
            let isZip = u.pathExtension.lowercased() == "zip"
            let ok = isZip ? await ModelChecksum.matches(u, m.sha256) : false
            guard ok || ModelChecksum.confirmUnverified(m.title) else { busy = nil; return }
            install(m, from: u)
        }
    }

    private func install(_ m: ModelPackage, from u: URL) {
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

/// "Source and license": where each model comes from, what was changed, and the archive's checksum.
struct ModelSourcesView: View {
    let sources: [ModelSource]
    var sha256: String?
    @State var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sources) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(s.name).fontWeight(.medium)
                            Text("· \(s.author) · \(s.license)").foregroundStyle(.secondary)
                        }
                        Link(s.link.absoluteString, destination: s.link)
                        Text(s.change).foregroundStyle(.secondary)
                    }
                }
                if let sha256 {
                    Text(tr("SHA-256 архива: \(ModelChecksum.short(sha256))"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .help(sha256)
                }
                Link(tr("Как пересобрать модели из оригиналов"),
                     destination: URL(string: "https://github.com/araoijj/kadr/tree/main/tools/convert")!)
            }
            .font(.caption)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)   // otherwise centered under the label
        } label: {
            Text(tr("Источник и лицензия")).font(.caption)
        }
    }
}
