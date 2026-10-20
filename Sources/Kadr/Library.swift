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
        case .all: tr("Все снимки")
        case .unrated: tr("Без оценки")
        case .picked: tr("С оценкой")
        case .rejected: tr("Отклонённые")
        case .best: tr("Лучшие в сериях")
        case .stars(let n): String(repeating: "★", count: n) + (n < 5 ? tr(" и выше") : "")
        case .label(let l): l.title
        case .duplicates: tr("Точные дубли")
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
    /// Масштаб просмотра: nil — вписать в окно, 1 — 100% (пиксель кадра = пиксель экрана), 2 — 200%…
    var loupeZoom: CGFloat?
    var loupeZoomBase: CGFloat?                    // начало щипка
    var loupeCenter = CGPoint(x: 0.5, y: 0.5)      // центр видимой области в долях кадра (y — сверху вниз)
    var fitZoom: CGFloat = 0.25                    // масштаб режима «Вписать» (его считает просмотр)
    var loupeDisplay: CGSize = .zero               // размер кадра на экране при текущем масштабе, точки
    var splitCompare = false                       // шторка «до / после» (Y)
    var splitPos: CGFloat = 0.5                    // положение шторки, доля ширины
    static let zoomSteps: [CGFloat] = [0.25, 0.5, 1, 2, 4]

    var zoom100: Bool {
        get { loupeZoom != nil }
        set { setZoom(newValue ? 1 : nil) }
    }

    /// point — куда приблизить (доли кадра); меньше «вписать» не уменьшаем.
    func setZoom(_ z: CGFloat?, at point: CGPoint? = nil) {
        if let z, z > fitZoom * 1.01 {
            loupeZoom = min(z, 8)
            if let point { loupeCenter = point }
        } else {
            loupeZoom = nil
            loupeCenter = CGPoint(x: 0.5, y: 0.5)
        }
        loupeZoomBase = loupeZoom
    }

    /// Щипок и ⌘+колёсико: плавный масштаб, ниже «вписать» — возврат к нему.
    func setZoomKeepingBase(_ z: CGFloat) {
        let base = loupeZoomBase
        if z > fitZoom * 1.01 { loupeZoom = min(z, 8) } else { loupeZoom = nil; loupeCenter = CGPoint(x: 0.5, y: 0.5) }
        loupeZoomBase = base
    }

    func zoomIn() {
        loupe = true
        let cur = loupeZoom ?? fitZoom
        setZoom(Self.zoomSteps.first { $0 > cur * 1.01 } ?? min(cur * 2, 8), at: loupeCenter)
    }

    func zoomOut() {
        guard let cur = loupeZoom else { return }
        setZoom(Self.zoomSteps.last { $0 < cur * 0.99 }, at: loupeCenter)
    }

    /// Сдвиг видимой области на dx, dy точек экрана (прокрутка, перетаскивание).
    func pan(dx: CGFloat, dy: CGFloat) {
        guard loupeZoom != nil, loupeDisplay.width > 0 else { return }
        loupeCenter = CGPoint(x: loupeCenter.x - dx / loupeDisplay.width, y: loupeCenter.y - dy / loupeDisplay.height)
    }
    var thumbSize: CGFloat = 220
    var autoAdvance = Prefs.autoAdvance {
        didSet { Prefs.d.set(autoAdvance, forKey: "pref.autoAdvance") }
    }
    var showInfo = true
    var columns = 4

    var loading = false
    var analyzed = 0
    var toast: String?

    private var index: [URL: Int] = [:]

    // Журнал изменений (History.swift).
    var history: [HistoryEntry] = []
    var historyPos = 0                  // сколько шагов применено; дальше — отменённые, их можно вернуть
    var historyPaused = false
    private var historySaveTask: Task<Void, Never>?

    func photo(_ id: URL) -> Photo? { index[id].map { photos[$0] } }

    func scheduleHistorySave() {
        historySaveTask?.cancel()
        guard let folder else { return }
        let h = history, pos = historyPos
        historySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { HistoryStore.save(h, pos, for: folder) }.value
        }
    }

    func saveEditsSoon() { scheduleEditsSave() }

    // MARK: - Обработка

    enum InspectorTab: Hashable { case info, edit, history }
    var inspectorTab: InspectorTab = .info {
        didSet {
            // Обрабатывать удобнее на большом кадре — из сетки переходим в просмотр.
            if inspectorTab == .edit, oldValue != .edit, !loupe, !comparing, currentID != nil { loupe = true }
        }
    }
    var showOriginal = false           // «до» — клавиша \
    var styles: [Style] = Style.builtIns + StyleStore.load()
    var luts: [String] = LUTStore.shared.list()
    var copiedAdj: Adjustments?
    let collections = CollectionDownloader()

    func downloadCollection(_ c: LUTCollection) {
        collections.download(c) { [weak self] in self?.luts = LUTStore.shared.list() }
    }

    /// Стили по коллекциям в заданном порядке.
    var styleGroups: [(name: String, styles: [Style])] {
        let groups = Dictionary(grouping: styles, by: \.collection)
        let order = Style.collectionOrder + groups.keys.filter { !Style.collectionOrder.contains($0) }.sorted()
        return order.compactMap { k in groups[k].map { (k, $0) } }
    }
    private var saveEditsTask: Task<Void, Never>?

    /// Ползунки двигают только текущий кадр (как основной вариант в Capture One).
    func setAdjustments(_ a: Adjustments) {
        guard let id = currentID, let i = index[id] else { return }
        let old = photos[i].adj
        guard old != a else { return }
        let before = snapshot([id])
        photos[i].adj = a
        scheduleEditsSave()
        // Во время кадрирования шаги не пишем — один шаг при «Готово».
        if !cropMode {
            let d = describeChange(old, a, url: id)
            record(d.title, before: before, key: "\(id.path)|\(d.key)")
        }
    }

    // MARK: - Кадрирование

    var cropMode = false
    private var cropBackup: Adjustments?

    func startCrop() {
        guard current != nil else { return }
        cropBackup = current?.adj
        comparing = false
        loupe = true
        setZoom(nil)
        inspectorTab = .edit
        cropMode = true
    }

    func finishCrop() {
        if let b = cropBackup, let id = currentID, let p = photo(id) {
            var s = PhotoState(p); s.adj = b
            cropMode = false
            let d = describeChange(b, p.adj, url: id)
            record(d.key == "angle" || d.key == tr("Горизонт") ? d.title : tr("Кадрирование ") + (CropFormat.byID(p.adj.cropAspect)?.title ?? tr("свободное")),
                   before: [id: s])
        }
        cropMode = false
        cropBackup = nil
    }

    func cancelCrop() {
        if let b = cropBackup { withoutHistory { setAdjustments(b) } }
        cropMode = false
        cropBackup = nil
    }

    func resetCrop() {
        guard var a = current?.adj else { return }
        let wasCrop = cropMode
        cropMode = false
        defer { cropMode = wasCrop }
        a.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        a.angle = 0
        a.cropAspect = nil
        setAdjustments(a)
    }

    /// Для массовых правок из других файлов (кадрирование серии).
    func setAdjustmentsRaw(_ i: Int, _ a: Adjustments) {
        photos[i].adj = a
        scheduleEditsSave()
    }

    /// Стиль, вставка и сброс — на все выделенные.
    private func setAdjustmentsForTargets(_ title: String, _ change: (inout Adjustments) -> Void) {
        let before = snapshot(targets.map(\.id))
        for t in targets {
            guard let i = index[t.id] else { continue }
            change(&photos[i].adj)
        }
        scheduleEditsSave()
        record(title + countSuffix, before: before)
    }

    func applyStyle(_ st: Style) {
        setAdjustmentsForTargets(tr("Стиль «\(st.name)»")) { $0.merge(st.adj, groups: st.groups) }
        flash(tr("Стиль «\(st.name)»") + countSuffix)
    }

    /// Новый стиль из текущего кадра: только выбранные разделы.
    func createStyle(name: String, groups: Set<StyleGroup>, collection: String) {
        guard let p = current else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !groups.isEmpty else { return }
        let col = collection.trimmingCharacters(in: .whitespaces).isEmpty ? "Мои стили" : collection
        styles.removeAll { !$0.builtIn && $0.name == n && $0.collection == col }
        styles.append(Style(name: n, adj: p.adj, groups: groups, collection: col))
        StyleStore.save(styles)
        flash(tr("Стиль «\(n)» сохранён"))
    }

    /// Перезаписать свой стиль текущими настройками кадра (разделы стиля сохраняются).
    func updateStyle(_ st: Style) {
        guard let p = current, let i = styles.firstIndex(where: { $0.id == st.id }), !st.builtIn else { return }
        styles[i].adj = p.adj
        StyleStore.save(styles)
        flash(tr("Стиль «\(st.name)» обновлён"))
    }

    func renameStyle(_ st: Style, to name: String) {
        guard let i = styles.firstIndex(where: { $0.id == st.id }), !st.builtIn else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        styles[i].name = n
        StyleStore.save(styles)
    }

    var userCollections: [String] {
        Array(Set(styles.filter { !$0.builtIn }.map(\.collection) + ["Мои стили"])).sorted()
    }

    /// Свои стили в файл .kadrstyles — чтобы перенести на другой Mac или поделиться.
    func exportStyles() {
        let mine = styles.filter { !$0.builtIn }
        guard !mine.isEmpty else { flash(tr("Своих стилей пока нет")); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("Мои стили.kadrstyles")
        panel.message = tr("Экспорт своих стилей (\(mine.count))")
        guard panel.runModal() == .OK, let u = panel.url, let d = try? JSONEncoder().encode(mine) else { return }
        try? d.write(to: u, options: .atomic)
        flash(tr("Экспортировано стилей: \(mine.count)"))
    }

    func importStyles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "kadrstyles") ?? .json, .json]
        panel.message = tr("Файл со стилями .kadrstyles")
        guard panel.runModal() == .OK, let u = panel.url, let d = try? Data(contentsOf: u),
              let list = try? JSONDecoder().decode([Style].self, from: d) else { return }
        var added = 0
        for var st in list {
            st.id = UUID()
            styles.removeAll { !$0.builtIn && $0.name == st.name && $0.collection == st.collection }
            styles.append(st)
            added += 1
        }
        StyleStore.save(styles)
        flash(tr("Импортировано стилей: \(added)"))
    }

    func copyAdjustments() {
        guard let p = current else { return }
        copiedAdj = p.adj
        flash(tr("Обработка скопирована"))
    }

    func pasteAdjustments() {
        guard let a = copiedAdj else { flash(tr("Сначала скопируйте обработку (⌘⇧C)")); return }
        setAdjustmentsForTargets(tr("Вставка обработки")) { $0 = a }
        flash(tr("Обработка вставлена") + countSuffix)
    }

    func resetAdjustments() {
        setAdjustmentsForTargets(tr("Сброс к исходнику")) { $0 = .none }
        flash(tr("Обработка сброшена") + countSuffix)
    }

    func saveStyle(named name: String) {
        guard let p = current, !p.adj.isIdentity else { flash(tr("Нечего сохранять: кадр без обработки")); return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        styles.removeAll { !$0.builtIn && $0.name == n }
        styles.append(Style(name: n, adj: p.adj))
        StyleStore.save(styles)
        flash(tr("Стиль «\(n)» сохранён"))
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
        panel.message = tr("Выберите LUT-файлы .cube")
        guard panel.runModal() == .OK else { return }
        let ok = LUTStore.shared.importFiles(panel.urls)
        luts = LUTStore.shared.list()
        if let first = ok.first, var a = current?.adj {
            a.lut = first
            setAdjustments(a)
        }
        flash(ok.isEmpty ? tr("Не удалось прочитать LUT") : tr("Добавлено LUT: \(ok.count)"))
    }

    func revealLUTFolder() { NSWorkspace.shared.open(AppFolders.luts) }

    private func scheduleEditsSave() {
        saveEditsTask?.cancel()
        guard folder != nil else { return }
        var byFolder: [URL: [String: Adjustments]] = [:]
        for p in photos { byFolder[p.url.deletingLastPathComponent(), default: [:]][p.name] = p.adj }
        saveEditsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Task.detached { for (dir, e) in byFolder { EditStore.save(e, in: dir) } }.value
        }
    }
    private var analysisTask: Task<Void, Never>?

    // MARK: - Выборка

    var visible: [Photo] {
        photos.filter { p in
            Self.matches(p, filter)
                && (lensFilter == nil || p.lensName == lensFilter)
                && (dayFilter == nil || p.day == dayFilter)
        }
        .sorted(by: inOrder)
    }

    // MARK: - Сортировка, группировка, доп. фильтры

    let browser = FolderBrowser()
    let importer = CardImporter()
    var showImport = false
    var cardBanner: URL?

    init() {
        browser.onCardMounted = { [weak self] card in
            guard let self, !self.showImport, Prefs.cardBanner else { return }
            self.cardBanner = card
        }
    }

    // MARK: - Сравнение

    var comparing = false
    var compareIDs: [URL] = []
    var compareZoom: CGFloat = 1
    var compareZoomBase: CGFloat = 1
    var compareZoom100: CGFloat = 4
    var compareCenter = CGPoint(x: 0.5, y: 0.5)

    var comparePhotos: [Photo] { compareIDs.compactMap { index[$0].map { photos[$0] } } }

    /// Можно ли сравнить: выделено 2+ кадра или текущий входит в серию.
    var canCompare: Bool { multiSelected || (current.map { series(of: $0).count > 1 } ?? false) }

    /// Выделенные (до 4), а если выделен один — до 4 кадров его серии начиная с него.
    func startCompare() {
        var ids: [URL]
        if multiSelected {
            ids = targets.map(\.id)
            if ids.count > 4 { flash(tr("Сравниваю первые 4 из \(ids.count)")) }
        } else if let p = current, p.seriesID != nil {
            let s = series(of: p).map(\.id)
            let i = s.firstIndex(of: p.id) ?? 0
            ids = Array(s[max(0, min(i, s.count - 4))...])
        } else {
            flash(tr("Выделите 2–4 кадра: ⌘-клик или рамкой"))
            return
        }
        ids = Array(ids.prefix(4))
        guard ids.count >= 2 else { flash(tr("Выделите 2–4 кадра: ⌘-клик или рамкой")); return }
        compareIDs = ids
        let focusID = ids.contains(currentID ?? ids[0]) ? (currentID ?? ids[0]) : ids[0]
        focus(focusID)
        compareZoom = 1
        compareZoomBase = 1
        compareCenter = CGPoint(x: 0.5, y: 0.5)
        loupe = false
        comparing = true
    }

    func stopCompare() {
        comparing = false
        compareZoom = 1
        compareZoomBase = 1
    }

    func compareMove(_ delta: Int) {
        guard let i = compareIDs.firstIndex(where: { $0 == currentID }) else { focus(compareIDs.first); return }
        focus(compareIDs[(i + delta + compareIDs.count) % compareIDs.count])
    }

    func toggleCompareZoom() {
        if compareZoom > 1 {
            compareZoom = 1
            compareCenter = CGPoint(x: 0.5, y: 0.5)
        } else {
            compareZoom = max(compareZoom100, 1.5)
        }
        compareZoomBase = compareZoom
    }

    /// Оставить кадр в фокусе, остальные сравниваемые — отклонить.
    func rejectOthersInCompare() {
        guard let keep = currentID else { return }
        let before = snapshot(compareIDs)
        defer { record(tr("Оставлен \(keep.lastPathComponent)"), before: before) }
        var n = 0
        for id in compareIDs {
            guard let i = index[id] else { continue }
            photos[i].rejected = id != keep
            if id != keep { n += 1 }
            let p = photos[i]
            try? Sidecar.write(.init(rating: p.rating, rejected: p.rejected, label: p.label), for: p.url)
        }
        stopCompare()
        flash(tr("Оставлен \(keep.lastPathComponent), отклонено: \(n)"))
    }

    var sortKey: SortKey = SortKey(rawValue: UserDefaults.standard.string(forKey: "sortKey") ?? "") ?? .date {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    var sortDescending = UserDefaults.standard.bool(forKey: "sortDescending") {
        didSet { UserDefaults.standard.set(sortDescending, forKey: "sortDescending") }
    }
    var groupKey: GroupKey = GroupKey(rawValue: UserDefaults.standard.string(forKey: "groupKey") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(groupKey.rawValue, forKey: "groupKey") }
    }
    var includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders") {
        didSet {
            UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders")
            reload()
        }
    }
    var lensFilter: String?
    var dayFilter: Date?

    /// Объективы и дни съёмки с количеством кадров — для боковой панели.
    var lenses: [(name: String, count: Int)] {
        Dictionary(grouping: photos, by: \.lensName).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    var days: [(day: Date, count: Int)] {
        Dictionary(grouping: photos.filter { $0.day != nil }, by: { $0.day! }).map { ($0.key, $0.value.count) }.sorted { $0.day > $1.day }
    }

    /// Разделы сетки: подряд идущие кадры с одним ключом группы.
    var sections: [(title: String, photos: [Photo])] {
        let list = visible
        guard groupKey != .none else { return [("", list)] }
        var out: [(String, [Photo])] = []
        for p in list {
            let t = groupTitle(p)
            if out.last?.0 == t { out[out.count - 1].1.append(p) } else { out.append((t, [p])) }
        }
        return out
    }

    func groupTitle(_ p: Photo) -> String {
        switch groupKey {
        case .none: return ""
        case .day:
            guard let d = p.day else { return tr("Без даты") }
            let t = d.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(I18n.locale))
            return t.prefix(1).uppercased() + t.dropFirst()
        case .folder: return relativeFolder(p)
        case .lens: return p.lensName
        case .rating: return p.rejected ? tr("Отклонённые") : p.rating == 0 ? tr("Без оценки") : String(repeating: "★", count: p.rating)
        }
    }

    func relativeFolder(_ p: Photo) -> String {
        guard let root = folder?.standardizedFileURL.path else { return "" }
        let dir = p.url.deletingLastPathComponent().standardizedFileURL.path
        if dir == root { return folder?.lastPathComponent ?? "" }
        return dir.hasPrefix(root + "/") ? String(dir.dropFirst(root.count + 1)) : dir
    }

    /// Корневая папка — первой, вложенные — по алфавиту пути.
    private func folderSortKey(_ p: Photo) -> String {
        p.url.deletingLastPathComponent().standardizedFileURL == folder?.standardizedFileURL ? "" : relativeFolder(p)
    }

    private func inOrder(_ a: Photo, _ b: Photo) -> Bool {
        if groupKey != .none {
            let g = compareGroup(a, b)
            if g != .orderedSame { return g == .orderedAscending }
        }
        var r = compareSort(a, b)
        if sortDescending { r = r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : r }
        if r != .orderedSame { return r == .orderedAscending }
        return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
    }

    private func compareGroup(_ a: Photo, _ b: Photo) -> ComparisonResult {
        switch groupKey {
        case .none: return .orderedSame
        case .day:
            let r = cmp(a.day ?? .distantPast, b.day ?? .distantPast)
            return sortDescending ? flip(r) : r
        case .folder: return folderSortKey(a).localizedStandardCompare(folderSortKey(b))
        case .lens: return a.lensName.localizedStandardCompare(b.lensName)
        case .rating: return cmp(b.rejected ? -1 : b.rating, a.rejected ? -1 : a.rating)   // высокие сверху
        }
    }

    private func compareSort(_ a: Photo, _ b: Photo) -> ComparisonResult {
        switch sortKey {
        case .date:
            if let da = a.exif.date, let db = b.exif.date, da != db { return cmp(da, db) }
            return a.name.localizedStandardCompare(b.name)
        case .name: return a.name.localizedStandardCompare(b.name)
        case .rating: return cmp(b.rejected ? -1 : b.rating, a.rejected ? -1 : a.rating)
        case .lens: return a.lensName.localizedStandardCompare(b.lensName)
        case .folder: return folderSortKey(a).localizedStandardCompare(folderSortKey(b))
        case .size: return cmp(b.fileSize, a.fileSize)
        }
    }

    private func cmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
    private func flip(_ r: ComparisonResult) -> ComparisonResult { r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : r }

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
        panel.prompt = tr("Открыть")
        panel.message = tr("Выберите папку со съёмкой")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        analysisTask?.cancel()
        folder = url
        browser.addRecent(url)
        filter = .all
        lensFilter = nil
        dayFilter = nil
        loupe = false
        loupeZoom = nil
        loading = true
        analyzed = 0
        photos = []
        let files = Self.imageFiles(in: url, recursive: includeSubfolders)

        // Если рядом лежат RAW и JPEG с одним именем — показываем один RAW.
        let rawBases = Set(files.filter { ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().path })
        let chosen = files.filter {
            ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) || !rawBases.contains($0.deletingPathExtension().path)
        }

        // Обработка хранится в каждой папке своя.
        var edits: [URL: [String: Adjustments]] = [:]
        var indexes: [URL: [String: IndexEntry]] = [:]
        for dir in Set(chosen.map { $0.deletingLastPathComponent() }) {
            edits[dir] = EditStore.load(dir)
            indexes[dir] = AnalysisIndex.load(dir)
        }
        photos = chosen.map { f in
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            let s = Sidecar.read(for: f)
            var p = Photo(id: f, fileSize: size, rating: s.rating, rejected: s.rejected, label: s.label)
            p.mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
            p.adj = edits[f.deletingLastPathComponent()]?[f.lastPathComponent] ?? .none
            // Уже анализировали и файл не менялся — берём из индекса, не пересчитываем.
            if let c = indexes[f.deletingLastPathComponent()]?[f.lastPathComponent], c.size == size, c.mtime == p.mtime {
                p.exif = c.exif; p.hash = c.hash; p.sharpness = c.sharpness; p.indexed = true
            }
            return p
        }
        photos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        reindex()
        focus(visible.first?.id)
        (history, historyPos) = HistoryStore.load(url)
        loading = false
        startAnalysis()
    }

    func reload() { if let folder { open(folder) } }

    /// Забыть индекс открытой папки (и вложенных) и посчитать заново.
    func reanalyze() {
        for dir in Set(photos.map { $0.url.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: AnalysisIndex.file(for: dir))
        }
        reload()
    }

    /// Снимки папки; с recursive — и всех вложенных, кроме скрытых и «_Отклонённые».
    nonisolated static func imageFiles(in url: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        func isImage(_ u: URL) -> Bool { ImageStore.imageExtensions.contains(u.pathExtension.lowercased()) }
        guard recursive else {
            return ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []).filter(isImage)
        }
        var out: [URL] = []
        let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let u = en?.nextObject() as? URL {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if u.lastPathComponent == "_Отклонённые" { en?.skipDescendants() }
                continue
            }
            if isImage(u) { out.append(u) }
        }
        return out
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
    }

    /// Фоном: EXIF, превью, хэш и резкость, затем серии и дубли.
    /// Фоном и бережно: только новые/изменённые файлы, 2 потока с низким приоритетом,
    /// индекс сохраняется по ходу (каждые 50 кадров) — прерванный анализ не пропадает.
    private func startAnalysis() {
        analyzed = photos.filter(\.indexed).count
        let urls = photos.filter { !$0.indexed }.map(\.id)
        guard !urls.isEmpty else { finishAnalysis(); return }
        analysisTask = Task { [weak self] in
            let store = ImageStore.shared
            let workers = min(max(1, Prefs.analysisThreads), 4)
            var sinceSave = 0
            await withTaskGroup(of: (URL, ExifInfo, UInt64?, Double?).self) { group in
                var it = urls.makeIterator()
                func add() -> Bool {
                    guard let u = it.next() else { return false }
                    group.addTask(priority: .utility) {
                        _ = store.asShotK(u)
                        let exif = store.exif(u)
                        guard let img = store.preview(u) else { return (u, exif, nil, nil) }
                        return (u, exif, store.dHash(img), store.sharpness(img))
                    }
                    return true
                }
                for _ in 0..<workers { _ = add() }
                while let (u, exif, h, s) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    sinceSave += 1
                    let save = sinceSave >= 50
                    if save { sinceSave = 0 }
                    await MainActor.run {
                        guard let self, let i = self.index[u] else { return }
                        self.photos[i].exif = exif
                        self.photos[i].hash = h
                        self.photos[i].sharpness = s
                        self.photos[i].indexed = true
                        self.analyzed += 1
                        if save { self.saveIndex() }
                    }
                    _ = add()
                }
            }
            await MainActor.run {
                self?.saveIndex()
                if !Task.isCancelled { self?.finishAnalysis() }
            }
        }
    }

    /// Индекс по папкам: только проанализированные файлы, удалённые выпадают сами.
    private func saveIndex() {
        var byDir: [URL: [String: IndexEntry]] = [:]
        for p in photos where p.indexed {
            byDir[p.url.deletingLastPathComponent(), default: [:]][p.name] =
                IndexEntry(size: p.fileSize, mtime: p.mtime, exif: p.exif, hash: p.hash, sharpness: p.sharpness)
        }
        Task.detached(priority: .utility) { for (dir, e) in byDir { AnalysisIndex.save(e, for: dir) } }
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
        currentID = id   // масштаб сохраняется: удобно листать серию и сравнивать резкость в 100%
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
    /// Модификаторы в момент нажатия кнопки мыши. Одиночный клик SwiftUI срабатывает с задержкой
    /// (ждёт возможный двойной), и к этому времени ⌘ часто уже отпущен — поэтому запоминаем при нажатии.
    var clickModifiers: NSEvent.ModifierFlags = []

    func click(_ p: Photo) {
        let mods = clickModifiers.isEmpty ? NSEvent.modifierFlags : clickModifiers
        clickModifiers = []
        if mods.contains(.command) || mods.contains(.control) {
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
        flash(tr("Выделено: \(ids.count)"))
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
        update(r == 0 ? tr("Оценка снята") : String(repeating: "★", count: r)) { $0.rating = r; $0.rejected = false }
        flash((r == 0 ? tr("Оценка снята") : String(repeating: "★", count: r)) + countSuffix)
        if !many { advanceIfNeeded() }
    }

    func toggleReject() {
        let many = multiSelected
        let reject = !targets.allSatisfy(\.rejected)
        update(reject ? tr("Отклонено") : tr("Возвращено")) { $0.rejected = reject }
        flash((reject ? tr("Отклонено") : tr("Возвращено")) + countSuffix)
        if reject && !many { advanceIfNeeded() }
    }

    func toggleLabel(_ l: ColorLabel) {
        let clear = targets.allSatisfy { $0.label == l }
        update(clear ? tr("Метка снята") : tr("Метка: \(l.title)")) { $0.label = clear ? nil : l }
        flash((clear ? tr("Метка снята") : l.title) + countSuffix)
    }

    private var countSuffix: String { multiSelected ? tr(" · \(targets.count) шт.") : "" }

    private func update(_ title: String? = nil, _ change: (inout Photo) -> Void) {
        let before = snapshot(targets.map(\.id))
        defer { if let title { record(title + countSuffix, before: before) } }
        var failed = 0
        for t in targets {
            guard let i = index[t.id] else { continue }
            change(&photos[i])
            let p = photos[i]
            if (try? Sidecar.write(.init(rating: p.rating, rejected: p.rejected, label: p.label), for: p.url)) == nil { failed += 1 }
        }
        if failed > 0 { flash(tr("Не удалось записать XMP: \(failed) шт.")) }
    }

    private func advanceIfNeeded() {
        guard autoAdvance, !comparing, let cur = currentID else { return }
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
        let rejected = photos.filter(\.rejected)
        guard !rejected.isEmpty else { flash(tr("Нет отклонённых")); return }
        let alert = NSAlert()
        alert.messageText = tr("Перенести \(rejected.count) отклонённых в папку «_Отклонённые»?")
        alert.informativeText = tr("Файлы не удаляются — их можно вернуть обратно вручную.")
        alert.addButton(withTitle: tr("Перенести"))
        alert.addButton(withTitle: tr("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        var moved = 0
        for p in rejected {
            let dest = p.url.deletingLastPathComponent().appendingPathComponent("_Отклонённые", isDirectory: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for f in Exporter.companions(of: p.url) where fm.fileExists(atPath: f.path) {
                try? fm.moveItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
            }
            if !fm.fileExists(atPath: p.url.path) { moved += 1 }
        }
        photos.removeAll { !fm.fileExists(atPath: $0.url.path) }
        reindex()
        if currentID.map({ index[$0] == nil }) ?? true { focus(visible.first?.id) }
        flash(tr("Перенесено: \(moved)"))
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
        panel.prompt = tr("Выбрать")
        panel.message = tr("Папка, куда сохранять отобранные снимки")
        if let d = export.destination { panel.directoryURL = d }
        if panel.runModal() == .OK, let u = panel.url { export.destination = u; export.save() }
    }

    func runExport() {
        let list = photos(for: export.scope)
        guard !list.isEmpty else { flash(tr("Нечего сохранять")); return }
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
        flash(tr("Сохранено: \(ok) → \(target.lastPathComponent)"))
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
            flash(ok > 0 ? tr("→ \(target.lastPathComponent): \(ok) шт.") : tr("Уже есть в \(target.lastPathComponent)"))
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
        flash(tr("Путь скопирован") + countSuffix)
    }

    /// Окно сохранения с уже выбранными «Выделенные» и нужным форматом.
    func exportTargets(as format: ExportSettings.Format) {
        export.scope = .selected
        export.format = format
        showExport = true
    }
}
