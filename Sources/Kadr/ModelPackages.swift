import AppKit
import CoreML
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

/// Steps every model install shares. Slow (unpacking and compiling take seconds to tens of seconds),
/// so installs run off the main thread.
enum ModelInstall {
    /// Unpacks a .zip into a new temporary folder (the caller removes it). Throws if ditto fails:
    /// a broken archive or a full disk would otherwise install half a model.
    static func unzip(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let t = fm.temporaryDirectory.appendingPathComponent("kadr-models-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: t, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, t.path]
        do { try p.run() } catch { try? fm.removeItem(at: t); throw error }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { try? fm.removeItem(at: t); throw CocoaError(.fileReadCorruptFile) }
        return t
    }

    /// Compiles `src` (an .mlmodelc is taken as is) and puts it at `dst`. The new model is copied next to the old
    /// one first and swapped in, so a failed copy leaves the installed model working.
    static func place(_ src: URL, at dst: URL) throws {
        let fm = FileManager.default
        let compiled = src.pathExtension == "mlmodelc" ? src : try MLModel.compileModel(at: src)
        defer { if compiled != src { try? fm.removeItem(at: compiled) } }
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(dst.lastPathComponent)")
        do {
            try fm.copyItem(at: compiled, to: tmp)
            if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: dst) }
        } catch { try? fm.removeItem(at: tmp); throw error }
    }
}

/// Compiled Core ML models in the models folder, loaded together on first use: the one way the face mesh,
/// face recognition, noise reduction and Remove Object load theirs.
/// `installed` has its own lock and is cached: view bodies ask it on every redraw and never wait for a load.
/// One load is in flight at a time (SAM + LaMa take up to ~10 s); other callers wait for it here, so the
/// owner's own locks stay free. `reset()` after an install or removal throws away a load that started before it.
final class ModelSet: @unchecked Sendable {
    let names: [String]
    let folder: URL
    private let units: MLComputeUnits
    private let lock = NSLock()
    private let loadLock = NSLock()
    private let installedLock = NSLock()
    private var models: [String: MLModel] = [:]
    private var tried = false
    private var generation = 0
    private var installedCache: Bool?

    init(_ names: [String], in folder: URL, computeUnits: MLComputeUnits = .all) {
        self.names = names
        self.folder = folder
        units = computeUnits
    }

    /// Where the compiled model of that name lives.
    func url(_ name: String) -> URL { folder.appendingPathComponent(name + ".mlmodelc") }

    /// Every model of the set is on disk (without loading).
    var installed: Bool {
        installedLock.withLock {
            if let installedCache { return installedCache }
            let v = names.allSatisfy { FileManager.default.fileExists(atPath: url($0).path) }
            installedCache = v
            return v
        }
    }

    /// The loaded model; nil when it isn't installed or fails to load (not retried until `reset()`).
    func model(_ name: String) -> MLModel? {
        loadLock.withLock {
            let (done, gen) = lock.withLock { (tried, generation) }
            if !done {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = units
                var loaded: [String: MLModel] = [:]
                for n in names { loaded[n] = try? MLModel(contentsOf: url(n), configuration: cfg) }
                lock.withLock { if generation == gen { models = loaded; tried = true } }
            }
            return lock.withLock { models[name] }
        }
    }

    /// The files changed (installed or removed): loaded models and the installed flag are stale.
    func reset() {
        lock.withLock { tried = false; models = [:]; generation += 1 }
        installedLock.withLock { installedCache = nil }
    }
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

    /// Installs from a .zip, a folder or a single .mlpackage; the unpacked copy is removed either way.
    /// Slow: call off the main thread.
    func install(fromArchive u: URL) throws {
        guard u.pathExtension.lowercased() == "zip" else { return try install(from: u) }
        let dir = try ModelInstall.unzip(u)
        defer { try? FileManager.default.removeItem(at: dir) }
        try install(from: dir)
    }

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

    /// Unpacks and compiles in the background (tens of seconds for the big packages), then reports here.
    private func install(_ m: ModelPackage, from u: URL, removing tmp: URL? = nil) async {
        let res = await Task.detached(priority: .userInitiated) {
            defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
            return Result { try m.install(fromArchive: u) }
        }.value
        switch res {
        case .success: error = nil; if m == .faceID { lib.aiModulesChanged() }
        case .failure(let e): error = tr("Не удалось установить: \(e.localizedDescription)")
        }
        busy = nil; refresh += 1
    }

    private func download(_ m: ModelPackage) {
        busy = m; error = nil
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: m.url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw URLError(.badServerResponse)
                }
                guard await ModelChecksum.matches(tmp, m.sha256) else {
                    try? FileManager.default.removeItem(at: tmp)
                    error = tr("Скачанный архив не совпал по контрольной сумме — не установлен. Попробуйте ещё раз позже.")
                    busy = nil; return
                }
                // The download has no extension: give it one, so it is unpacked as an archive (and removed after).
                let zip = tmp.deletingLastPathComponent().appendingPathComponent("kadr-\(m.rawValue)-\(UUID().uuidString).zip")
                do { try FileManager.default.moveItem(at: tmp, to: zip) } catch { try? FileManager.default.removeItem(at: tmp); throw error }
                await install(m, from: zip, removing: zip)
            } catch {
                self.error = tr("Не удалось скачать: \(error.localizedDescription)")
                busy = nil; refresh += 1
            }
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
            await install(m, from: u)
        }
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
