import AppKit
import Observation
import SwiftUI

enum PhotoFilter: Hashable {
    case all, unrated, picked, rejected, best
    case stars(Int)
    case label(ColorLabel)
    case duplicates

    var title: String {
        switch self {
        case .all: "Все снимки"
        case .unrated: "Без оценки"
        case .picked: "С оценкой"
        case .rejected: "Отклонённые"
        case .best: "Лучшие в сериях"
        case .stars(let n): String(repeating: "★", count: n) + (n < 5 ? " и выше" : "")
        case .label(let l): l.title
        case .duplicates: "Точные дубли"
        }
    }

    var icon: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .unrated: "circle.dashed"
        case .picked: "star"
        case .rejected: "xmark.circle"
        case .best: "sparkles"
        case .stars: "star.fill"
        case .label: "circle.fill"
        case .duplicates: "doc.on.doc"
        }
    }
}

@MainActor
@Observable
final class Library {
    var folder: URL?
    var photos: [Photo] = []
    var filter: PhotoFilter = .all
    var currentID: URL?
    var loupe = false
    var zoom100 = false
    var thumbSize: CGFloat = 220
    var autoAdvance = true
    var showInfo = true
    var columns = 4

    var loading = false
    var analyzed = 0
    var toast: String?

    private var index: [URL: Int] = [:]

    // MARK: - Обработка

    enum InspectorTab: Hashable { case info, edit }
    var inspectorTab: InspectorTab = .info
    var showOriginal = false           // «до» — клавиша \
    var styles: [Style] = Style.builtIns + StyleStore.load()
    var luts: [String] = LUTStore.shared.list()
    var copiedAdj: Adjustments?
    private var saveEditsTask: Task<Void, Never>?

    /// Ползунки двигают только текущий кадр (как основной вариант в Capture One).
    func setAdjustments(_ a: Adjustments) {
        guard let id = currentID, let i = index[id] else { return }
        photos[i].adj = a
        scheduleEditsSave()
    }

    /// Стиль, вставка и сброс — на все выделенные.
    private func setAdjustmentsForTargets(_ change: (inout Adjustments) -> Void) {
        for t in targets {
            guard let i = index[t.id] else { continue }
            change(&photos[i].adj)
        }
        scheduleEditsSave()
    }

    func applyStyle(_ st: Style) {
        setAdjustmentsForTargets { $0 = st.adj }
        flash("Стиль «\(st.name)»" + countSuffix)
    }

    func copyAdjustments() {
        guard let p = current else { return }
        copiedAdj = p.adj
        flash("Обработка скопирована")
    }

    func pasteAdjustments() {
        guard let a = copiedAdj else { flash("Сначала скопируйте обработку (⌘⇧C)"); return }
        setAdjustmentsForTargets { $0 = a }
        flash("Обработка вставлена" + countSuffix)
    }

    func resetAdjustments() {
        setAdjustmentsForTargets { $0 = .none }
        flash("Обработка сброшена" + countSuffix)
    }

    func saveStyle(named name: String) {
        guard let p = current, !p.adj.isIdentity else { flash("Нечего сохранять: кадр без обработки"); return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        styles.removeAll { !$0.builtIn && $0.name == n }
        styles.append(Style(name: n, adj: p.adj))
        StyleStore.save(styles)
        flash("Стиль «\(n)» сохранён")
    }

    func deleteStyle(_ st: Style) {
        guard !st.builtIn else { return }
        styles.removeAll { $0.id == st.id }
        StyleStore.save(styles)
    }

    func importLUTs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "cube")!]
        panel.message = "Выберите LUT-файлы .cube"
        guard panel.runModal() == .OK else { return }
        let ok = LUTStore.shared.importFiles(panel.urls)
        luts = LUTStore.shared.list()
        if let first = ok.first, var a = current?.adj {
            a.lut = first
            setAdjustments(a)
        }
        flash(ok.isEmpty ? "Не удалось прочитать LUT" : "Добавлено LUT: \(ok.count)")
    }

    func revealLUTFolder() { NSWorkspace.shared.open(AppFolders.luts) }

    private func scheduleEditsSave() {
        saveEditsTask?.cancel()
        guard let folder else { return }
        let edits = Dictionary(photos.map { ($0.name, $0.adj) }, uniquingKeysWith: { a, _ in a })
        saveEditsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Task.detached { EditStore.save(edits, in: folder) }.value
        }
    }
    private var analysisTask: Task<Void, Never>?

    // MARK: - Выборка

    var visible: [Photo] { photos.filter { Self.matches($0, filter) } }

    func count(_ f: PhotoFilter) -> Int { photos.reduce(0) { $0 + (Self.matches($1, f) ? 1 : 0) } }

    static func matches(_ p: Photo, _ f: PhotoFilter) -> Bool {
        switch f {
        case .all: true
        case .unrated: p.rating == 0 && !p.rejected
        case .picked: p.rating > 0 && !p.rejected
        case .rejected: p.rejected
        case .best: !p.rejected && (p.isBestInSeries || p.seriesID == nil)
        case .stars(let n): p.rating >= n && !p.rejected
        case .label(let l): p.label == l
        case .duplicates: p.duplicateOf != nil
        }
    }

    var current: Photo? {
        guard let id = currentID, let i = index[id] else { return nil }
        return photos[i]
    }

    var seriesCount: Int { Set(photos.compactMap(\.seriesID)).count }

    func series(of p: Photo) -> [Photo] {
        guard let s = p.seriesID else { return [] }
        return photos.filter { $0.seriesID == s }
    }

    // MARK: - Открытие папки

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Открыть"
        panel.message = "Выберите папку со съёмкой"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        analysisTask?.cancel()
        folder = url
        filter = .all
        loupe = false
        zoom100 = false
        loading = true
        analyzed = 0
        photos = []
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { ImageStore.imageExtensions.contains($0.pathExtension.lowercased()) }

        // Если рядом лежат RAW и JPEG с одним именем — показываем один RAW.
        let rawBases = Set(files.filter { ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent })
        let chosen = files.filter {
            ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) || !rawBases.contains($0.deletingPathExtension().lastPathComponent)
        }

        let edits = EditStore.load(url)
        photos = chosen.map { f in
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let s = Sidecar.read(for: f)
            var p = Photo(id: f, fileSize: size, rating: s.rating, rejected: s.rejected, label: s.label)
            p.adj = edits[f.lastPathComponent] ?? .none
            return p
        }
        photos.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        reindex()
        focus(photos.first?.id)
        loading = false
        startAnalysis()
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
    }

    /// Фоном: EXIF, превью, хэш и резкость, затем серии и дубли.
    private func startAnalysis() {
        let urls = photos.map(\.id)
        analysisTask = Task { [weak self] in
            let store = ImageStore.shared
            let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
            await withTaskGroup(of: (URL, ExifInfo, UInt64?, Double?).self) { group in
                var it = urls.makeIterator()
                func add() -> Bool {
                    guard let u = it.next() else { return false }
                    group.addTask {
                        let exif = store.exif(u)
                        guard let img = store.preview(u) else { return (u, exif, nil, nil) }
                        return (u, exif, store.dHash(img), store.sharpness(img))
                    }
                    return true
                }
                for _ in 0..<workers { _ = add() }
                while let (u, exif, h, s) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    await MainActor.run {
                        guard let self, let i = self.index[u] else { return }
                        self.photos[i].exif = exif
                        self.photos[i].hash = h
                        self.photos[i].sharpness = s
                        self.analyzed += 1
                    }
                    _ = add()
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finishAnalysis() }
        }
    }

    private func finishAnalysis() {
        // Порядок съёмки — по времени из EXIF.
        photos.sort {
            switch ($0.exif.date, $1.exif.date) {
            case let (a?, b?) where a != b: a < b
            default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        reindex()
        groupSeries()
        findDuplicates()
    }

    /// Серия = подряд идущие кадры с похожей картинкой (расстояние Хэмминга ≤ 12)
    /// и паузой не больше 30 секунд.
    private func groupSeries() {
        var next = 1
        var runStart = 0
        func close(_ end: Int) {
            if end - runStart >= 2 {
                for k in runStart..<end { photos[k].seriesID = next }
                let best = (runStart..<end).max { (photos[$0].sharpness ?? 0) < (photos[$1].sharpness ?? 0) }
                if let best { photos[best].isBestInSeries = true }
                next += 1
            }
        }
        for i in photos.indices {
            photos[i].seriesID = nil
            photos[i].isBestInSeries = false
        }
        guard photos.count > 1 else { return }
        for i in 1..<photos.count {
            let a = photos[i - 1], b = photos[i]
            var similar = false
            if let ha = a.hash, let hb = b.hash, (ha ^ hb).nonzeroBitCount <= 12 {
                if let da = a.exif.date, let db = b.exif.date { similar = abs(db.timeIntervalSince(da)) <= 30 } else { similar = true }
            }
            if !similar {
                close(i)
                runStart = i
            }
        }
        close(photos.count)
    }

    /// Точный дубль: тот же размер файла, то же время съёмки и та же картинка.
    private func findDuplicates() {
        var seen: [String: URL] = [:]
        for i in photos.indices {
            photos[i].duplicateOf = nil
            guard let h = photos[i].hash else { continue }
            let key = "\(photos[i].fileSize)-\(photos[i].exif.date?.timeIntervalSince1970 ?? 0)-\(h)"
            if let first = seen[key] { photos[i].duplicateOf = first } else { seen[key] = photos[i].id }
        }
    }

    // MARK: - Навигация и выделение

    /// Выделенные снимки. currentID — тот, что в фокусе (показан в просмотре и в инфо).
    var selection: Set<URL> = []
    private var anchorID: URL?

    /// С чем работают оценки, метки и сохранение: выделение, а если выделен один — текущий.
    var targets: [Photo] {
        let sel = selection.filter { index[$0] != nil }
        if sel.count > 1 { return photos.filter { sel.contains($0.id) } }
        return current.map { [$0] } ?? []
    }

    var multiSelected: Bool { selection.filter { index[$0] != nil }.count > 1 }

    func isSelected(_ p: Photo) -> Bool { p.id == currentID || selection.contains(p.id) }

    private func focus(_ id: URL?, extend: Bool = false) {
        currentID = id
        zoom100 = false
        guard let id else { selection = []; return }
        if extend, let anchor = anchorID { selectRange(from: anchor, to: id) } else {
            selection = [id]
            anchorID = id
        }
    }

    private func selectRange(from a: URL, to b: URL) {
        let list = visible.map(\.id)
        guard let i = list.firstIndex(of: a), let j = list.firstIndex(of: b) else { selection = [b]; return }
        selection = Set(list[min(i, j)...max(i, j)])
    }

    func move(_ delta: Int, extend: Bool = false) {
        let list = visible
        guard !list.isEmpty else { return }
        let pos = list.firstIndex { $0.id == currentID } ?? -1
        let n = min(max(pos + delta, 0), list.count - 1)
        focus(list[n].id, extend: extend)
    }

    /// Клик: обычный — один снимок, ⌘ — добавить/убрать, ⇧ — диапазон.
    func click(_ p: Photo) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(p.id) && selection.count > 1 {
                selection.remove(p.id)
                if currentID == p.id { currentID = targets.first?.id }
            } else {
                selection.insert(p.id)
                if let c = currentID { selection.insert(c) }
                currentID = p.id
            }
            anchorID = p.id
        } else if mods.contains(.shift) {
            focus(p.id, extend: true)
        } else {
            focus(p.id)
        }
    }

    func select(_ p: Photo) { focus(p.id) }

    /// Выделение рамкой: hit — задетые кадры в порядке сетки, adding — что было выделено до (с ⌘/⇧).
    func setMarquee(_ hit: [URL], adding base: Set<URL>) {
        selection = base.union(hit)
        guard let first = hit.first else {
            if base.isEmpty, let c = currentID { selection = [c] }
            return
        }
        if currentID == nil || !selection.contains(currentID!) { currentID = first }
        anchorID = first
    }

    func selectAll() {
        let ids = visible.map(\.id)
        selection = Set(ids)
        if currentID == nil || !selection.contains(currentID!) { currentID = ids.first }
        anchorID = ids.first
        flash("Выделено: \(ids.count)")
    }

    func clearSelection() { focus(currentID) }

    /// Выделить все кадры серии, в которой текущий.
    func selectSeries() {
        guard let p = current, p.seriesID != nil else { return }
        selection = Set(series(of: p).map(\.id))
    }

    // MARK: - Оценки (применяются ко всем выделенным)

    func setRating(_ r: Int) {
        let many = multiSelected
        update { $0.rating = r; $0.rejected = false }
        flash((r == 0 ? "Оценка снята" : String(repeating: "★", count: r)) + countSuffix)
        if !many { advanceIfNeeded() }
    }

    func toggleReject() {
        let many = multiSelected
        let reject = !targets.allSatisfy(\.rejected)
        update { $0.rejected = reject }
        flash((reject ? "Отклонено" : "Возвращено") + countSuffix)
        if reject && !many { advanceIfNeeded() }
    }

    func toggleLabel(_ l: ColorLabel) {
        let clear = targets.allSatisfy { $0.label == l }
        update { $0.label = clear ? nil : l }
        flash((clear ? "Метка снята" : l.title) + countSuffix)
    }

    private var countSuffix: String { multiSelected ? " · \(targets.count) шт." : "" }

    private func update(_ change: (inout Photo) -> Void) {
        var failed = 0
        for t in targets {
            guard let i = index[t.id] else { continue }
            change(&photos[i])
            let p = photos[i]
            if (try? Sidecar.write(.init(rating: p.rating, rejected: p.rejected, label: p.label), for: p.url)) == nil { failed += 1 }
        }
        if failed > 0 { flash("Не удалось записать XMP: \(failed) шт.") }
    }

    private func advanceIfNeeded() {
        guard autoAdvance, let cur = currentID else { return }
        let list = visible
        // Если кадр выпал из текущего фильтра — встаём на следующий за ним.
        if !list.contains(where: { $0.id == cur }) {
            let all = photos.map(\.id)
            if let i = all.firstIndex(of: cur) {
                focus(all[(i + 1)...].first { id in list.contains { $0.id == id } } ?? list.last?.id)
            }
        } else {
            move(1)
        }
    }

    func flash(_ text: String) {
        toast = text
        let shown = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if self.toast == shown { self.toast = nil }
        }
    }

    // MARK: - Файловые операции

    /// Переносит отклонённые в подпапку «_Отклонённые» (вместе с XMP и парным JPEG). Удаления нет.
    func moveRejected() {
        guard let folder else { return }
        let rejected = photos.filter(\.rejected)
        guard !rejected.isEmpty else { flash("Нет отклонённых"); return }
        let alert = NSAlert()
        alert.messageText = "Перенести \(rejected.count) отклонённых в папку «_Отклонённые»?"
        alert.informativeText = "Файлы не удаляются — их можно вернуть обратно вручную."
        alert.addButton(withTitle: "Перенести")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let dest = folder.appendingPathComponent("_Отклонённые", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var moved = 0
        for p in rejected {
            for f in Exporter.companions(of: p.url) where fm.fileExists(atPath: f.path) {
                try? fm.moveItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
            }
            if !fm.fileExists(atPath: p.url.path) { moved += 1 }
        }
        photos.removeAll { !fm.fileExists(atPath: $0.url.path) }
        reindex()
        if currentID.map({ index[$0] == nil }) ?? true { focus(visible.first?.id) }
        flash("Перенесено: \(moved)")
    }

    // MARK: - Сохранение в папку

    var export = ExportSettings.load()
    var showExport = false
    var exportDone = 0
    var exportTotal = 0
    var exporting: Bool { exportTotal > 0 }
    private var exportTask: Task<Void, Never>?

    func photos(for scope: ExportSettings.Scope) -> [Photo] {
        switch scope {
        case .visible: visible
        case .rated: photos.filter { !$0.rejected && ($0.rating > 0 || $0.label != nil) }
        case .selected: targets
        }
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка, куда сохранять отобранные снимки"
        if let d = export.destination { panel.directoryURL = d }
        if panel.runModal() == .OK, let u = panel.url { export.destination = u; export.save() }
    }

    func runExport() {
        let list = photos(for: export.scope)
        guard !list.isEmpty else { flash("Нечего сохранять"); return }
        guard let target = Exporter.targetFolder(export, shoot: folder) else { chooseExportFolder(); return }
        export.save()
        let settings = export
        let items = exportItems(list)
        let shoot = folder?.lastPathComponent
        exportDone = 0
        exportTotal = items.count
        exportTask = Task { [weak self] in
            var ok = 0
            // RAW → JPEG тяжёлый (~1–2 с на кадр 50 Мп), поэтому по 3 параллельно.
            let workers = settings.format == .jpeg ? 3 : 1
            await withTaskGroup(of: Bool.self) { group in
                var it = items.makeIterator()
                func add() {
                    guard let item = it.next() else { return }
                    group.addTask { Exporter.export(item, to: target, settings, shootName: shoot) }
                }
                for _ in 0..<workers { add() }
                while let r = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if r { ok += 1 }
                    await MainActor.run { self?.exportDone += 1 }
                    add()
                }
            }
            await MainActor.run { self?.finishExport(ok: ok, target: target, moved: settings.format == .original && settings.move) }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func exportItems(_ list: [Photo]) -> [ExportItem] {
        list.enumerated().map { ExportItem(url: $1.url, adj: $1.adj, date: $1.exif.date, index: $0 + 1) }
    }

    private func finishExport(ok: Int, target: URL, moved: Bool) {
        exportTotal = 0
        showExport = false
        if moved {
            let fm = FileManager.default
            photos.removeAll { !fm.fileExists(atPath: $0.url.path) }
            reindex()
            if currentID.map({ index[$0] == nil }) ?? true { focus(visible.first?.id) }
        }
        flash("Сохранено: \(ok) → \(target.lastPathComponent)")
    }

    /// Клавиша S: текущий кадр сразу в папку сохранения (копия оригинала + XMP).
    func quickSend() {
        let list = targets
        guard !list.isEmpty else { return }
        guard export.destination != nil else { showExport = true; return }
        var s = export
        s.format = .original
        s.move = false
        guard let target = Exporter.targetFolder(s, shoot: folder) else { return }
        let items = exportItems(list)
        let shoot = folder?.lastPathComponent
        Task {
            let ok = await Task.detached { items.filter { Exporter.export($0, to: target, s, shootName: shoot) }.count }.value
            flash(ok > 0 ? "→ \(target.lastPathComponent): \(ok) шт." : "Уже есть в \(target.lastPathComponent)")
        }
    }

    /// Выделенные, а если выделен один — всё, что показано в фильтре.
    func openVisibleInCaptureOne() {
        let urls = (multiSelected ? targets : visible).map(\.url)
        guard !urls.isEmpty else { return }
        let app = URL(fileURLWithPath: "/Applications/Capture One.app")
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealCurrent() {
        let urls = targets.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: - Контекстное меню

    /// Правый клик как в Finder: по выделенному — действие над всем выделением,
    /// по невыделенному — сначала выделяем только его.
    func contextTarget(_ p: Photo) {
        if !isSelected(p) { focus(p.id) }
    }

    /// Сколько снимков затронет действие из меню этого кадра.
    func contextCount(_ p: Photo) -> Int { isSelected(p) && multiSelected ? targets.count : 1 }

    func openTargetsInCaptureOne() {
        let urls = targets.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: "/Applications/Capture One.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func openTargetsInDefaultApp() {
        for u in targets.map(\.url) { NSWorkspace.shared.open(u) }
    }

    func copyTargetPaths() {
        let text = targets.map(\.url.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Путь скопирован" + countSuffix)
    }

    /// Окно сохранения с уже выбранными «Выделенные» и нужным форматом.
    func exportTargets(as format: ExportSettings.Format) {
        export.scope = .selected
        export.format = format
        showExport = true
    }
}
