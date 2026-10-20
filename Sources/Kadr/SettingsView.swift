import AppKit
import SwiftUI

/// Окно «Настройки» (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(tr("Общие"), systemImage: "gearshape") }
            StorageSettings().tabItem { Label(tr("Хранилище"), systemImage: "internaldrive") }
            PerformanceSettings().tabItem { Label(tr("Память и скорость"), systemImage: "speedometer") }
            ImportSettingsTab().tabItem { Label(tr("Импорт"), systemImage: "sdcard") }
            PresetsSettings().tabItem { Label(tr("Стили и LUT"), systemImage: "camera.filters") }
            BackupSettings().tabItem { Label(tr("Резервная копия"), systemImage: "externaldrive.badge.timemachine") }
        }
        .frame(width: 620, height: 470)
    }
}

// MARK: - Общие

struct GeneralSettings: View {
    @Environment(Library.self) private var lib
    @AppStorage("pref.language") private var language = "system"
    @AppStorage("pref.reopenLast") private var reopenLast = true
    @AppStorage("pref.cardBanner") private var cardBanner = true
    @AppStorage("pref.cullDefault") private var cullDefault = false
    @AppStorage("pref.aiAuto") private var aiAuto = false
    @AppStorage("pref.sceneGap") private var sceneGap = 10
    @State private var startLanguage = Prefs.language

    var body: some View {
        Form {
            Section {
                Picker(tr("Язык интерфейса"), selection: $language) {
                    Text(tr("Как в системе")).tag("system")
                    Text(tr("Русский")).tag("ru")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Italiano").tag("it")
                }
                if language != startLanguage {
                    HStack {
                        Text(tr("Язык сменится после перезапуска.")).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Перезапустить")) { AppControl.relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            Section(tr("Работа")) {
                Toggle(tr("Открывать последнюю папку при запуске"), isOn: $reopenLast)
                Toggle(tr("Открывать папку сразу в режиме «Отбор»"), isOn: $cullDefault)
                Toggle(tr("Запускать AI-анализ автоматически после индексации"), isOn: $aiAuto)
                    .help(tr("Лица, глаза, смаз, пересвет. Нагружает Mac: ~1 минута на 1000 кадров. Выключено — запуск кнопкой «Запустить AI-анализ» в режиме «Отбор» (⌥⌘A)."))
                Picker(tr("Новая сцена после паузы"), selection: $sceneGap) {
                    ForEach([5, 10, 20, 30, 60], id: \.self) { Text(tr("\($0) мин")).tag($0) }
                }
                Toggle(tr("Переходить к следующему кадру после оценки"), isOn: Binding(get: { lib.autoAdvance }, set: { lib.autoAdvance = $0 }))
                Toggle(tr("Предлагать импорт при подключении карты памяти"), isOn: $cardBanner)
            }
            Section {
                Button(tr("Сбросить все настройки…"), role: .destructive) { AppControl.resetAll() }
                Text(tr("Стили, LUT, журналы и обработка снимков не удаляются — только настройки окон и экспорта."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Хранилище

struct StorageSettings: View {
    @State private var stats = StorageStats()
    @State private var refresh = 0

    var body: some View {
        Form {
            Section(tr("Папка данных «Кадра»")) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(AppFolders.support.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button(tr("Показать")) { NSWorkspace.shared.open(AppFolders.support) }
                }
                HStack {
                    Button(tr("Перенести в другую папку…")) { AppControl.moveDataFolder() }
                    if Prefs.dataFolder != nil {
                        Button(tr("Вернуть стандартную")) { AppControl.resetDataFolder() }
                    }
                }
                Text(tr("Здесь индексы, журналы, стили и LUT. Обработка снимков и оценки хранятся рядом со снимками (.kadr и XMP) — они переезжают вместе с папкой съёмки."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("Что занимает место")) {
                row(tr("Индекс анализа"), tr("\(stats.indexFolders) папок"), stats.indexBytes) {
                    AnalysisIndex.clear(); reload()
                }
                row(tr("Журналы изменений"), tr("\(stats.historyFolders) папок"), stats.historyBytes) {
                    try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("History")); reload()
                }
                row("LUT", tr("\(stats.lutCount) файлов"), stats.lutBytes, clear: nil)
                row(tr("Свои стили"), tr("\(stats.styleCount) шт."), stats.styleBytes, clear: nil)
                Text(tr("Временных файлов на диске «Кадр» не создаёт: превью и проявленные кадры держатся в памяти и освобождаются сами. Индекс пересоздаётся при следующем открытии папки."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: refresh) { stats = await Task.detached { StorageStats.compute() }.value }
    }

    private func reload() { refresh += 1 }

    private func row(_ title: String, _ detail: String, _ bytes: Int64, clear: (() -> Void)?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(detail) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").foregroundStyle(.secondary).monospacedDigit()
            if let clear {
                Button(tr("Очистить")) { clear() }.controlSize(.small)
            }
        }
    }
}

struct StorageStats: Sendable {
    var indexFolders = 0, indexBytes: Int64 = 0
    var historyFolders = 0, historyBytes: Int64 = 0
    var lutCount = 0, lutBytes: Int64 = 0
    var styleCount = 0, styleBytes: Int64 = 0

    static func compute() -> StorageStats {
        var s = StorageStats()
        let root = AppFolders.support
        (s.indexFolders, s.indexBytes) = dir(root.appendingPathComponent("Index"), ext: "json")
        (s.historyFolders, s.historyBytes) = dir(root.appendingPathComponent("History"), ext: "json")
        (_, s.lutBytes) = dir(root.appendingPathComponent("LUTs"), ext: nil)
        s.lutCount = LUTStore.shared.list().count
        s.styleCount = StyleStore.load().count
        s.styleBytes = Int64((try? StyleStore.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return s
    }

    private static func dir(_ u: URL, ext: String?) -> (Int, Int64) {
        guard let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        var n = 0, b: Int64 = 0
        for case let f as URL in en {
            guard let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            if ext == nil || f.pathExtension == ext { n += 1 }
            b += Int64(size)
        }
        return (n, b)
    }
}

// MARK: - Память и скорость

struct PerformanceSettings: View {
    @AppStorage("pref.threads") private var threads = 2
    @AppStorage("pref.thumbCache") private var thumbCache = 4000
    @AppStorage("pref.renderCache") private var renderCache = 4
    @AppStorage("pref.historyLimit") private var historyLimit = 100
    @AppStorage("pref.historyKeep") private var historyKeep = true
    @AppStorage("pref.indexEnabled") private var indexEnabled = true
    @State private var memory = AppControl.memoryUsage()

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("Сейчас «Кадр» использует")) {
                    Text(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)).monospacedDigit()
                }
                LabeledContent(tr("Ядер процессора")) { Text("\(ProcessInfo.processInfo.activeProcessorCount)") }
            }
            Section(tr("Анализ папки")) {
                Picker(tr("Потоков анализа"), selection: $threads) {
                    Text(tr("1 — тише всего")).tag(1)
                    Text(tr("2 — щадяще (по умолчанию)")).tag(2)
                    Text("3").tag(3)
                    Text(tr("4 — быстрее всего")).tag(4)
                }
                Toggle(tr("Хранить индекс анализа (повторное открытие папки — мгновенно)"), isOn: $indexEnabled)
            }
            FaceMeshSection()
            Section(tr("Память")) {
                Picker(tr("Превью в памяти"), selection: $thumbCache) {
                    Text(tr("1000 — экономно")).tag(1000)
                    Text("2000").tag(2000)
                    Text(tr("4000 — по умолчанию")).tag(4000)
                    Text(tr("8000 — большие съёмки")).tag(8000)
                }
                Picker(tr("Проявленных кадров в памяти"), selection: $renderCache) {
                    Text(tr("2 — экономно")).tag(2)
                    Text(tr("4 — по умолчанию")).tag(4)
                    Text(tr("6 — быстрее листать")).tag(6)
                }
                Text(tr("Превью ~0,3–1 МБ каждое, проявленный кадр ~60–80 МБ. Меньше — экономнее память, больше — быстрее листать назад. Применяется после перезапуска."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("Журнал изменений")) {
                Picker(tr("Шагов на папку"), selection: $historyLimit) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text(tr("100 — по умолчанию")).tag(100)
                    Text("200").tag(200)
                }
                Toggle(tr("Сохранять журнал между запусками"), isOn: $historyKeep)
                Text(tr("Шаг для одного кадра ~1 КБ, запись и отмена ~0,1 мс. Предел по объёму — \(historyLimit * 200) изменений кадров (~\(historyLimit * 200 * 7 / 10_000) МБ)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { while !Task.isCancelled { memory = AppControl.memoryUsage(); try? await Task.sleep(for: .seconds(2)) } }
    }
}

// MARK: - Импорт

struct ImportSettingsTab: View {
    @Environment(Library.self) private var lib

    var body: some View {
        @Bindable var imp = lib.importer
        Form {
            Section(tr("Куда импортировать")) {
                HStack {
                    Text(imp.baseFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(tr("Выбрать…")) {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        p.directoryURL = imp.baseFolder
                        if p.runModal() == .OK, let u = p.url { imp.baseFolder = u }
                    }
                }
                Toggle(tr("Раскладывать по дням съёмки"), isOn: $imp.splitByDay)
            }
            Section(tr("Карта памяти")) {
                Toggle(tr("Только новые — пропускать уже импортированные"), isOn: $imp.onlyNew)
                Toggle(tr("Извлекать карту после импорта"), isOn: $imp.ejectAfter)
                Button(tr("Забыть, что уже импортировано")) {
                    try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("imported.json"))
                }
                Text(tr("После этого следующий импорт той же карты скопирует все снимки заново (уже существующие файлы не перезапишутся)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Стили и LUT

struct PresetsSettings: View {
    @Environment(Library.self) private var lib

    var body: some View {
        Form {
            Section(tr("Свои стили")) {
                LabeledContent(tr("Сохранено")) { Text("\(lib.styles.filter { !$0.builtIn }.count)") }
                HStack {
                    Button(tr("Экспорт стилей…")) { lib.exportStyles() }
                    Button(tr("Импорт стилей…")) { lib.importStyles() }
                }
                Text(tr("Файл .kadrstyles переносит стили на другой Mac или к коллеге.")).font(.caption).foregroundStyle(.secondary)
            }
            Section("LUT") {
                LabeledContent(tr("Установлено")) { Text("\(lib.luts.count)") }
                HStack {
                    Button(tr("Загрузить .cube / HaldCLUT…")) { lib.importLUTs() }
                    Button(tr("Открыть папку LUT")) { lib.revealLUTFolder() }
                }
                ForEach(LUTCollection.all, id: \.folder) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.title)
                            Text("\(c.author) · \(c.license)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.installedCount > 0 {
                            Text(tr("Установлено: \(c.installedCount)")).foregroundStyle(.secondary)
                        } else if lib.collections.busy {
                            ProgressView(value: Double(lib.collections.done), total: Double(max(lib.collections.total, 1))).frame(width: 120)
                        } else {
                            Button(tr("Скачать")) { lib.downloadCollection(c) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Резервная копия

struct BackupSettings: View {
    @AppStorage("pref.lastBackup") private var lastBackup = 0.0
    @State private var message: String?

    var body: some View {
        Form {
            Section(tr("Резервная копия «Кадра»")) {
                Text(tr("Один файл .zip: свои стили, LUT, настройки (экспорт, импорт, избранные папки) и журналы изменений. Индекс в копию не входит — он пересчитывается сам."))
                    .font(.callout)
                LabeledContent(tr("Последняя копия")) {
                    Text(lastBackup == 0 ? tr("ещё не делали") : Date(timeIntervalSince1970: lastBackup).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(I18n.locale)))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(tr("Создать копию…")) {
                        if let m = AppControl.backup() { message = m; lastBackup = Date().timeIntervalSince1970 }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(tr("Восстановить из копии…")) { message = AppControl.restore() }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section(tr("Что ещё стоит беречь")) {
                Text(tr("Обработка и оценки хранятся рядом со снимками: папка .kadr и файлы .xmp в каждой съёмке. Делайте копию самих папок со съёмками (Time Machine, внешний диск) — тогда сохранится и обработка."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Действия приложения

@MainActor
enum AppControl {
    /// Перезапуск «Кадра» (для смены языка и папки данных).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func resetAll() {
        let a = NSAlert()
        a.messageText = tr("Сбросить все настройки «Кадра»?")
        a.informativeText = tr("Вернутся язык, кэши, параметры экспорта и импорта по умолчанию. Стили, LUT, журналы и обработка снимков останутся.")
        a.addButton(withTitle: tr("Сбросить"))
        a.addButton(withTitle: tr("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn, let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
        relaunch()
    }

    static func moveDataFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = tr("Куда перенести данные «Кадра» (индексы, журналы, стили, LUT)")
        guard p.runModal() == .OK, let base = p.url else { return }
        let dest = base.appendingPathComponent("Kadr", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(at: AppFolders.support, includingPropertiesForKeys: nil)) ?? [] {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item, to: target) }
        }
        UserDefaults.standard.set(dest.path, forKey: "pref.dataFolder")
        relaunch()
    }

    static func resetDataFolder() {
        UserDefaults.standard.removeObject(forKey: "pref.dataFolder")
        relaunch()
    }

    /// Ключи настроек, которые входят в резервную копию.
    private static let backupKeys = ["exportSettings", "favoriteFolders", "recentFolders", "sortKey", "sortDescending", "groupKey",
                                     "includeSubfolders", "import.base", "import.split", "import.onlyNew", "import.eject"]

    static func backup() -> String? {
        let p = NSSavePanel()
        p.nameFieldStringValue = tr("Кадр-копия-\(Date().formatted(.iso8601.year().month().day())).zip")
        guard p.runModal() == .OK, let dest = p.url else { return nil }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kadr-backup-\(UUID().uuidString)/Kadr", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp.deletingLastPathComponent()) }
        for name in ["styles.json", "LUTs", "History", "imported.json"] {
            let src = AppFolders.support.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: tmp.appendingPathComponent(name)) }
        }
        let d = UserDefaults.standard
        var prefs: [String: Any] = [:]
        for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("pref.") || k.hasPrefix("sb.") || k.hasPrefix("ep.") || backupKeys.contains(k) {
            if k != "pref.dataFolder" { prefs[k] = v }
        }
        (prefs as NSDictionary).write(to: tmp.appendingPathComponent("settings.plist"), atomically: true)
        try? fm.removeItem(at: dest)
        let z = Process()
        z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        z.arguments = ["-c", "-k", "--keepParent", tmp.path, dest.path]
        try? z.run(); z.waitUntilExit()
        guard z.terminationStatus == 0 else { return tr("Не удалось создать копию") }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        return tr("Копия сохранена: \(dest.lastPathComponent) (\(size))")
    }

    static func restore() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.zip]
        p.message = tr("Файл резервной копии «Кадра» (.zip)")
        guard p.runModal() == .OK, let src = p.url else { return nil }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("kadr-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let z = Process()
        z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        z.arguments = ["-x", "-k", src.path, tmp.path]
        try? z.run(); z.waitUntilExit()
        let root = tmp.appendingPathComponent("Kadr")
        guard z.terminationStatus == 0, fm.fileExists(atPath: root.path) else { return tr("Это не копия «Кадра»") }
        // Стили и LUT дополняют существующие, журналы — тоже; ничего не удаляется.
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent != "settings.plist" {
            let dest = AppFolders.support.appendingPathComponent(item.lastPathComponent)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for f in (try? fm.subpathsOfDirectory(atPath: item.path)) ?? [] {
                    let s = item.appendingPathComponent(f), t = dest.appendingPathComponent(f)
                    if (try? s.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        try? fm.createDirectory(at: t, withIntermediateDirectories: true)
                    } else if !fm.fileExists(atPath: t.path) { try? fm.copyItem(at: s, to: t) }
                }
            } else {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: item, to: dest)
            }
        }
        if let prefs = NSDictionary(contentsOf: root.appendingPathComponent("settings.plist")) as? [String: Any] {
            for (k, v) in prefs { UserDefaults.standard.set(v, forKey: k) }
        }
        let a = NSAlert()
        a.messageText = tr("Копия восстановлена")
        a.informativeText = tr("Перезапустить «Кадр», чтобы применить настройки?")
        a.addButton(withTitle: tr("Перезапустить"))
        a.addButton(withTitle: tr("Позже"))
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
        return tr("Восстановлено из \(src.lastPathComponent)")
    }

    /// Сколько памяти занимает процесс (резидентно).
    static func memoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

/// Модели сетки лица MediaPipe: точнее различают моргание, прищур и взгляд вниз.
struct FaceMeshSection: View {
    @Environment(Library.self) private var lib
    @State private var installed = FaceMesh.shared.installed
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section(tr("Сетка лица MediaPipe")) {
            LabeledContent(tr("Модели (~7 МБ)")) {
                if busy { ProgressView().controlSize(.small) }
                else { Text(installed ? tr("установлены") : tr("не установлены")).foregroundStyle(installed ? .green : .secondary) }
            }
            HStack {
                if !installed {
                    Button(tr("Скачать")) { download() }.disabled(busy)
                    Button(tr("Установить из файла…")) { pick() }.disabled(busy)
                } else {
                    Button(tr("Удалить модели")) { FaceMesh.shared.uninstall(); installed = false }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text(tr("В «Отборе» отличает моргание от прищура и взгляда вниз (~12 мс на лицо, на нейроядре). Без моделей глаза меряются по контуру от macOS — грубее. После установки кадры с лицами в открытых папках пересчитаются. Модели — Google MediaPipe Face Landmarker, лицензия Apache 2.0."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func finish(_ url: URL?, _ err: Error?) {
        if let url {
            do { try FaceMesh.shared.install(from: url); installed = true; error = nil; lib.reload() }
            catch { self.error = tr("Не удалось установить: \(error.localizedDescription)") }
        } else if let err {
            error = tr("Не удалось скачать: \(err.localizedDescription)")
        }
        busy = false
    }

    private func download() {
        busy = true; error = nil
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: FaceMesh.downloadURL)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let zip = tmp.deletingLastPathComponent().appendingPathComponent("kadr-facemesh.zip")
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: tmp, to: zip)
                finish(zip, nil)
                try? FileManager.default.removeItem(at: zip)
            } catch { finish(nil, error) }
        }
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowedContentTypes = [.zip, .package, .folder]
        p.message = tr("Архив .zip или папка с face_landmarks_detector и face_blendshapes (.mlpackage)")
        if p.runModal() == .OK, let u = p.url { busy = true; finish(u, nil) }
    }
}
