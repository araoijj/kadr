import AppKit
import Observation
import SwiftUI

enum PhotoFilter: Hashable {
    case all, unrated, picked, rejected, best
    case stars(Int)
    case label(ColorLabel)
    case duplicates
    // Culling
    case suspects, undecided, leaders, smiling, recommended
    case reason(CullReason)
    case scene(Int)

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
        case .suspects: tr("Возможный брак")
        case .undecided: tr("Без решения")
        case .leaders: tr("Быстрый проход")
        case .reason(let r): r.title
        case .scene(let id): tr("Сцена \(id)")
        case .smiling: tr("Улыбаются")
        case .recommended: tr("Лучшие кадры")
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
        case .suspects: "exclamationmark.triangle"
        case .undecided: "questionmark.circle"
        case .leaders: "hare"
        case .reason(let r): r.icon
        case .scene: "film.stack"
        case .smiling: "face.smiling"
        case .recommended: "star.circle"
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
    /// Loupe zoom: nil = fit to window, 1 = 100% (one image pixel = one screen pixel), 2 = 200%…
    var loupeZoom: CGFloat?
    var loupeZoomBase: CGFloat?                    // pinch start
    var loupeCenter = CGPoint(x: 0.5, y: 0.5)      // center of the visible area as fractions of the image (y top-down)
    var fitZoom: CGFloat = 0.25                    // zoom level of "Fit" mode (computed by the loupe view)
    var loupeDisplay: CGSize = .zero               // on-screen image size at the current zoom, in points
    var splitCompare = false                       // before/after split slider (Y)
    var splitPos: CGFloat = 0.5                    // split slider position, fraction of width
    static let zoomSteps: [CGFloat] = [0.25, 0.5, 1, 2, 4]

    var zoom100: Bool {
        get { loupeZoom != nil }
        set { setZoom(newValue ? 1 : nil) }
    }

    /// point: where to zoom in (fractions of the image); never zooms out below "Fit".
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

    /// Pinch and ⌘+scroll wheel: smooth zoom; going below "Fit" snaps back to it.
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

    /// Pans the visible area by dx, dy screen points (scrolling, dragging).
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

    // "Culling" mode (Cull.swift, CullView.swift).
    var culling = false {
        didSet { if culling { loupe = false; comparing = false; if let c = currentID { viewed.insert(c) } } }
    }
    var cullHints = Prefs.d.object(forKey: "pref.cullHints") as? Bool ?? true {
        didSet { Prefs.d.set(cullHints, forKey: "pref.cullHints") }
    }
    var cullStrictness = Prefs.d.object(forKey: "pref.cullStrictness") as? Double ?? 0.5 {
        didSet { Prefs.d.set(cullStrictness, forKey: "pref.cullStrictness") }
    }
    var viewed: Set<URL> = []
    var showCullSummary = false
    var showShortcuts = false

    // AI analysis (defect detection): started by a button; opening a folder only runs lightweight indexing.
    var aiRunning = false
    /// Modules turned on in Settings → AI; findings of the others are hidden even if computed earlier.
    var aiEnabled = Prefs.aiModules {
        didSet { Prefs.setAIModules(aiEnabled) }
    }
    var aiDone = 0
    var aiTotal = 0
    var aiCount = 0               // photos with finished AI analysis
    var aiReady: Bool { aiCount > 0 }
    /// AI findings are visible: analysis is done and hints are on (not during analysis: medians aren't computed yet,
    /// and recomputing the queues on every photo slows down the UI).
    var aiOn: Bool { aiReady && cullHints && !aiRunning }
    private var aiTask: Task<Void, Never>?
    var scenes: [SceneInfo] = []
    var tournamentAll: [URL] = []
    var tournamentQueue: [URL] = []
    var tournamentRound = 0
    static let cullFacePixels: CGFloat = 380   // face in the culling column: 190 pt on Retina
    var cullMedianSharpness = 0.0
    var cullMedianFaceSharpness = 0.0
    var seriesBestSharpness: [Int: Double] = [:]
    var seriesOpenEyes: [Int: Double] = [:]
    var seriesOpenPoses: [Int: [OpenPose]] = [:]
    var seriesBestPrint: [Int: Data] = [:]
    var sceneMedians: [Int: (face: Double?, other: Double?)] = [:]

    // Change history (History.swift).
    var history: [HistoryEntry] = []
    var historyPos = 0                  // number of steps applied; the rest are undone and can be redone
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

    // MARK: - Edit

    enum InspectorTab: Hashable { case info, edit, history }
    var inspectorTab: InspectorTab = .info {
        didSet {
            // Editing is easier on a large image, so switch from the grid to the loupe.
            if inspectorTab == .edit, oldValue != .edit, !loupe, !comparing, currentID != nil { loupe = true }
        }
    }
    var showOriginal = false           // "before" view, \ key
    var styles: [Style] = Style.builtIns + StyleStore.load()
    var luts: [String] = LUTStore.shared.list()
    var copiedAdj: Adjustments?
    /// With several photos selected, sliders change all of them.
    var syncEdits = Prefs.d.object(forKey: "pref.syncEdits") as? Bool ?? true {
        didSet { Prefs.d.set(syncEdits, forKey: "pref.syncEdits") }
    }
    private var copiedAsShotK: Double?   // as-shot white balance of the photo the settings were copied from
    let collections = CollectionDownloader()

    func downloadCollection(_ c: LUTCollection) {
        collections.download(c) { [weak self] in self?.luts = LUTStore.shared.list() }
    }

    /// Styles grouped by collection, in the configured order.
    var styleGroups: [(name: String, styles: [Style])] {
        let groups = Dictionary(grouping: styles, by: \.collection)
        let order = Style.collectionOrder + groups.keys.filter { !Style.collectionOrder.contains($0) }.sorted()
        return order.compactMap { k in groups[k].map { (k, $0) } }
    }
    private var saveEditsTask: Task<Void, Never>?

    /// Sliders change the current photo; with several photos selected and "Apply to all selected" on,
    /// the changed settings go to the whole selection (like Lightroom's Auto Sync). Crop stays per photo.
    func setAdjustments(_ a: Adjustments) {
        guard let id = currentID, let i = index[id] else { return }
        let old = photos[i].adj
        guard old != a else { return }
        let others = syncEdits && multiSelected && !cropMode ? selection.filter { $0 != id && index[$0] != nil } : []
        let before = snapshot([id] + others)
        photos[i].adj = a
        if !others.isEmpty {
            let srcK = old.wbShift != a.wbShift ? ImageStore.shared.asShotK(id) : nil
            for o in others {
                guard let j = index[o] else { continue }
                photos[j].adj = photos[j].adj.syncing(from: old, to: a, asShotK: srcK, target: o)
            }
        }
        scheduleEditsSave()
        // Don't record steps while cropping; one step is recorded on "Done".
        if !cropMode {
            let d = describeChange(old, a, url: id)
            record(d.title, before: before, key: "\(id.path)|\(d.key)")
        }
    }

    // MARK: - Crop

    var cropMode = false
    private var cropBackup: Adjustments?

    // Auto crop review (AutoCrop.swift): suggestions open one by one in the crop editor.
    var autoCropQueue: [URL] = []
    var autoCropPos = 0
    var autoCropAccepted = 0
    var autoCropRatio: Double?          // nil — keep each photo's own proportions
    var autoCropBusy = false

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
        autoCropAdvance(accepted: true)
    }

    func cancelCrop() {
        if let b = cropBackup { withoutHistory { setAdjustments(b) } }
        cropMode = false
        cropBackup = nil
        autoCropAdvance(accepted: false)
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

    /// For bulk edits from other files (cropping a series).
    func setAdjustmentsRaw(_ i: Int, _ a: Adjustments) {
        photos[i].adj = a
        scheduleEditsSave()
    }

    /// Style, paste and reset apply to all selected photos.
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

    /// New style from the current photo: only the chosen sections.
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

    /// Overwrite a user style with the current photo's settings (the style's sections are kept).
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

    /// User styles to a .kadrstyles file, to move them to another Mac or share them.
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
        copiedAsShotK = ImageStore.shared.asShotK(p.url)
        flash(tr("Обработка скопирована"))
    }

    func pasteAdjustments() {
        guard let a = copiedAdj else { flash(tr("Сначала скопируйте обработку (⌘⇧C)")); return }
        let srcK = copiedAsShotK
        let before = snapshot(targets.map(\.id))
        for t in targets {
            guard let i = index[t.id] else { continue }
            photos[i].adj = Self.withAbsoluteWB(a, fromAsShot: srcK, to: t.url)
        }
        scheduleEditsSave()
        record(tr("Вставка обработки") + countSuffix, before: before)
        flash(tr("Обработка вставлена") + countSuffix)
    }

    /// White balance is stored as a shift from "as shot". Copied to a photo with a different as-shot value,
    /// the same shift gives a different temperature — so, like Lightroom, carry over the absolute kelvin.
    nonisolated static func withAbsoluteWB(_ a: Adjustments, fromAsShot src: Double?, to url: URL) -> Adjustments {
        guard a.wbShift != 0, let src else { return a }
        let dst = ImageStore.shared.asShotK(url)
        var b = a
        b.wbShift = ((src + a.wbShift - dst) / 10).rounded() * 10
        return b
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
        pendingEdits = byFolder
        saveEditsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            pendingEdits = nil
            await Task.detached { for (dir, e) in byFolder { EditStore.save(e, in: dir) } }.value
        }
    }
    private var pendingEdits: [URL: [String: Adjustments]]?

    /// Writes edits that are still waiting for the debounce — before opening another folder and on quit,
    /// otherwise a paste right before switching folders or quitting would be lost.
    func flushEdits() {
        guard let p = pendingEdits else { return }
        saveEditsTask?.cancel()
        pendingEdits = nil
        for (dir, e) in p { EditStore.save(e, in: dir) }
    }
    private var analysisTask: Task<Void, Never>?

    // MARK: - Filtering

    var visible: [Photo] {
        photos.filter { p in
            matches(p, filter)
                && (lensFilter == nil || p.lensName == lensFilter)
                && (dayFilter == nil || p.day == dayFilter)
                && (tagFilter == nil || !aiEnabled.contains(.tags) || (p.cull?.tags?.contains(tagFilter!) ?? false))
        }
        .sorted(by: inOrder)
    }

    // MARK: - Sorting, grouping, extra filters

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

    // MARK: - Compare

    var comparing = false
    var compareIDs: [URL] = []
    var compareZoom: CGFloat = 1
    var compareZoomBase: CGFloat = 1
    var compareZoom100: CGFloat = 4
    var compareCenter = CGPoint(x: 0.5, y: 0.5)
    var compareKeep: Set<URL> = []                 // frames marked to keep (checkmark, P, space)

    var comparePhotos: [Photo] { compareIDs.compactMap { index[$0].map { photos[$0] } } }

    /// Whether comparison is possible: 2+ photos selected, or the current one belongs to a series.
    var canCompare: Bool { multiSelected || (current.map { series(of: $0).count > 1 } ?? false) }

    /// The selection (up to 4), or, if only one is selected, up to 4 photos of its series starting from it.
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
        compareKeep = []
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

    /// Mark or unmark a compared frame to keep; nil means the focused one.
    func toggleCompareKeep(_ id: URL? = nil) {
        guard let id = id ?? currentID, compareIDs.contains(id) else { return }
        if compareKeep.contains(id) { compareKeep.remove(id) } else { compareKeep.insert(id) }
    }

    /// The frames that "Keep" applies to: the marked ones, or the focused one when nothing is marked.
    var compareKeeping: [URL] {
        let marked = compareIDs.filter { compareKeep.contains($0) }
        if !marked.isEmpty { return marked }
        return currentID.map { [$0] } ?? []
    }

    /// Keep the marked frames (★ if unrated) and reject the other compared ones. One undo step.
    func rejectOthersInCompare() {
        let keep = Set(compareKeeping)
        guard !keep.isEmpty else { return }
        let before = snapshot(compareIDs)
        var n = 0
        for id in compareIDs {
            guard let i = index[id] else { continue }
            if keep.contains(id) {
                photos[i].rejected = false
                if photos[i].rating == 0 { photos[i].rating = 1 }
            } else {
                photos[i].rejected = true
                n += 1
            }
            writeSidecar(i)
        }
        let what = keep.count == 1 ? keep.first!.lastPathComponent : tr("\(keep.count) кадра")
        record(tr("Оставлено: \(what)"), before: before)
        compareKeep = []
        stopCompare()
        flash(tr("Оставлено: \(what), отклонено: \(n)"))
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
    var tagFilter: String?          // Vision tag after AI analysis

    /// Lenses and shooting days with photo counts, for the sidebar.
    var lenses: [(name: String, count: Int)] {
        Dictionary(grouping: photos, by: \.lensName).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    var days: [(day: Date, count: Int)] {
        Dictionary(grouping: photos.filter { $0.day != nil }, by: { $0.day! }).map { ($0.key, $0.value.count) }.sorted { $0.day > $1.day }
    }

    /// Grid sections: consecutive photos sharing the same group key.
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
        case .scene: return scenes.first { $0.id == p.sceneID }.map { "\($0.title) · " + tr("\($0.count) кадров") } ?? tr("Без даты")
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

    /// Root folder first, subfolders alphabetically by path.
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
        case .scene: return cmp(a.sceneID ?? 0, b.sceneID ?? 0)
        case .folder: return folderSortKey(a).localizedStandardCompare(folderSortKey(b))
        case .lens: return a.lensName.localizedStandardCompare(b.lensName)
        case .rating: return cmp(b.rejected ? -1 : b.rating, a.rejected ? -1 : a.rating)   // highest first
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

    func count(_ f: PhotoFilter) -> Int { photos.reduce(0) { $0 + (matches($1, f) ? 1 : 0) } }

    func matches(_ p: Photo, _ f: PhotoFilter) -> Bool {
        switch f {
        case .all: true
        case .unrated: p.rating == 0 && !p.rejected
        case .picked: p.rating > 0 && !p.rejected
        case .rejected: p.rejected
        case .best: !p.rejected && (p.isBestInSeries || p.seriesID == nil)
        case .stars(let n): p.rating >= n && !p.rejected
        case .label(let l): p.label == l
        case .duplicates: p.duplicateOf != nil
        case .suspects: !p.rejected && verdict(p).suspect
        case .undecided: p.rating == 0 && !p.rejected
        case .leaders: !p.rejected && (p.seriesID == nil || p.isBestInSeries) && p.duplicateOf == nil
        case .reason(let r): verdict(p).reasons.contains(r)
        case .scene(let id): p.sceneID == id
        case .recommended: isRecommended(p)
        case .smiling: aiEnabled.contains(.faces) && !p.rejected && (p.cull?.faces.contains { $0.meshUsable && ($0.smile ?? 0) >= 0.6 } ?? false)
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

    // MARK: - Opening a folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = tr("Открыть")
        panel.message = tr("Выберите папку со съёмкой")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        flushEdits()
        analysisTask?.cancel()
        aiTask?.cancel(); aiRunning = false; aiCount = 0
        saveFolderState()
        folder = url
        browser.addRecent(url)
        filter = .all
        lensFilter = nil
        tagFilter = nil
        dayFilter = nil
        loupe = false
        loupeZoom = nil
        viewed = []
        culling = Prefs.cullByDefault
        loading = true
        analyzed = 0
        photos = []
        let files = Self.imageFiles(in: url, recursive: includeSubfolders)

        // If a RAW and a JPEG with the same name sit side by side, show only the RAW.
        let rawBases = Set(files.filter { ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().path })
        let chosen = files.filter {
            ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) || !rawBases.contains($0.deletingPathExtension().path)
        }

        // Each folder keeps its own edits.
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
            // Already analyzed and the file hasn't changed: take it from the index instead of recomputing.
            if let c = indexes[f.deletingLastPathComponent()]?[f.lastPathComponent], c.size == size, c.mtime == p.mtime {
                p.exif = c.exif; p.hash = c.hash; p.sharpness = c.sharpness; p.cull = c.cull; p.indexed = true
            }
            return p
        }
        photos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        reindex()
        focus(visible.first?.id)
        restoreFolderState(url)
        (history, historyPos) = HistoryStore.load(url)
        loading = false
        startAnalysis()
    }

    func reload() { if let folder { saveFolderState(); open(folder) } }

    /// Forget the index of the open folder (and its subfolders) and recompute it.
    func reanalyze() {
        for dir in Set(photos.map { $0.url.deletingLastPathComponent() }) {
            try? FileManager.default.removeItem(at: AnalysisIndex.file(for: dir))
        }
        reload()
    }

    /// Photos in the folder; with recursive, also in all subfolders except hidden ones and `_Отклонённые`.
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

    /// In the background: EXIF, preview, hash and sharpness, then series and duplicates.
    /// Background and gentle: only new/changed files, 2 low-priority threads,
    /// the index is saved as it goes (every 50 photos), so an interrupted analysis isn't lost.
    private func startAnalysis() {
        analyzed = photos.filter(\.indexed).count
        let urls = photos.filter { !$0.indexed }.map(\.id)
        guard !urls.isEmpty else { finishAnalysis(); return }
        analysisTask = Task { [weak self] in
            let store = ImageStore.shared
            let workers = min(max(1, Prefs.analysisThreads), 4)
            var sinceSave = 0
            await withTaskGroup(of: (URL, ExifInfo, UInt64?, Double?, CullData?).self) { group in
                var it = urls.makeIterator()
                func add() -> Bool {
                    guard let u = it.next() else { return false }
                    group.addTask(priority: .utility) {
                        // As-shot white balance (~40 ms, CIRAWFilter) is not computed here: only editing needs it, so it's computed on demand.
                        let exif = store.exif(u)
                        guard let img = store.preview(u) else { return (u, exif, nil, nil, nil) }
                        // Lightweight indexing only (~5 ms): EXIF, hash for series and duplicates, overall sharpness.
                        // Faces, eyes and the rest of the AI analysis run on a button press (startAI); it loads the Mac heavily.
                        return (u, exif, store.dHash(img), store.sharpness(img), nil)
                    }
                    return true
                }
                for _ in 0..<workers { _ = add() }
                // Push results to the UI in batches: every change to photos redraws the counters for the whole folder.
                var batch: [(URL, ExifInfo, UInt64?, Double?)] = []
                func flush() async {
                    let b = batch; batch = []
                    sinceSave += b.count
                    let save = sinceSave >= 50
                    if save { sinceSave = 0 }
                    await MainActor.run {
                        guard let self else { return }
                        for (u, exif, h, s) in b {
                            guard let i = self.index[u] else { continue }
                            self.photos[i].exif = exif
                            self.photos[i].hash = h
                            self.photos[i].sharpness = s
                            self.photos[i].indexed = true
                        }
                        self.analyzed += b.count
                        if save { self.saveIndex() }
                    }
                }
                while let (u, exif, h, s, _) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    batch.append((u, exif, h, s))
                    if batch.count >= 16 { await flush() }
                    _ = add()
                }
                if !batch.isEmpty, !Task.isCancelled { await flush() }
            }
            await MainActor.run {
                self?.saveIndex()
                if !Task.isCancelled {
                    self?.finishAnalysis()
                    if Prefs.aiAuto { self?.startAI() }
                }
            }
        }
    }

    /// The photo needs AI analysis: it hasn't had one yet, or its face eyes were measured the old way before the MediaPipe face mesh was installed.
    /// Modules this photo still lacks: never computed, or (faces) measured before the face mesh or smiles existed.
    func missingAI(_ p: Photo, enabled: Set<AIModule>? = nil, mesh: Bool = FaceMesh.shared.installed) -> Set<AIModule> {
        let enabled = enabled ?? aiEnabled
        guard let c = p.cull else { return enabled }
        var miss = enabled.subtracting(c.computed)
        if enabled.contains(.faces), mesh, !c.faces.isEmpty,
           c.mesh != true || c.faces.contains(where: { $0.blink != nil && $0.smile == nil }) { miss.insert(.faces) }
        return miss
    }

    func needsAI(_ p: Photo, mesh: Bool = FaceMesh.shared.installed) -> Bool { !missingAI(p, mesh: mesh).isEmpty }

    var aiPending: Int {
        if aiRunning { return 0 }
        let mesh = FaceMesh.shared.installed
        return photos.reduce(0) { $0 + (needsAI($1, mesh: mesh) ? 1 : 0) }
    }

    /// AI analysis of the open folder: faces and eyes (Apple Vision, MediaPipe), blur on the face or subject,
    /// overexposed faces, horizon, aesthetics. In the background with progress; already computed results come from the index.
    func startAI() {
        guard !aiRunning, analyzed >= photos.count else { return }
        FaceMesh.shared.installBundledIfNeeded()   // in case launch got ahead of the install at startup
        let mesh = FaceMesh.shared.installed, enabled = aiEnabled
        let jobs = photos.compactMap { p -> (URL, Set<AIModule>, CullData?)? in
            let miss = missingAI(p, enabled: enabled, mesh: mesh)
            return miss.isEmpty ? nil : (p.id, miss, p.cull)
        }
        let urls = jobs.map(\.0)
        guard !urls.isEmpty else { return }
        aiRunning = true; aiDone = 0; aiTotal = urls.count
        aiTask = Task { [weak self] in
            let store = ImageStore.shared
            let workers = min(max(1, Prefs.analysisThreads), 4)
            var sinceSave = 0
            await withTaskGroup(of: (URL, CullData?).self) { group in
                var it = jobs.makeIterator()
                func add() -> Bool {
                    guard let (u, mods, base) = it.next() else { return false }
                    group.addTask(priority: .utility) {
                        guard let img = store.preview(u) else { return (u, nil) }
                        return (u, await CullAnalyzer.analyze(img, modules: mods, into: base))
                    }
                    return true
                }
                for _ in 0..<workers { _ = add() }
                var batch: [(URL, CullData?)] = []
                func flush() async {
                    let b = batch; batch = []
                    sinceSave += b.count
                    let save = sinceSave >= 50
                    if save { sinceSave = 0 }
                    await MainActor.run {
                        guard let self else { return }
                        for (u, cull) in b {
                            guard let i = self.index[u], let cull else { continue }
                            if self.photos[i].cull == nil { self.aiCount += 1 }
                            self.photos[i].cull = cull
                        }
                        self.aiDone += b.count
                        if save { self.saveIndex() }
                    }
                }
                while let r = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    batch.append(r)
                    if batch.count >= 16 { await flush() }
                    _ = add()
                }
                if !batch.isEmpty, !Task.isCancelled { await flush() }
            }
            await MainActor.run {
                guard let self else { return }
                self.saveIndex()
                self.aiRunning = false
                self.finishAnalysis()   // best in series and medians, now taking faces and eyes into account
            }
        }
    }

    func stopAI() { aiTask?.cancel() }

    /// After modules are turned on or off: regroup bursts and recount (findings of off modules disappear).
    func aiModulesChanged() { if !photos.isEmpty, !aiRunning, analyzed >= photos.count { finishAnalysis() } }

    /// Per-folder index: only analyzed files; deleted ones drop out on their own.
    private func saveIndex() {
        var byDir: [URL: [String: IndexEntry]] = [:]
        for p in photos where p.indexed {
            byDir[p.url.deletingLastPathComponent(), default: [:]][p.name] =
                IndexEntry(size: p.fileSize, mtime: p.mtime, exif: p.exif, hash: p.hash, sharpness: p.sharpness, cull: p.cull)
        }
        Task.detached(priority: .utility) { for (dir, e) in byDir { AnalysisIndex.save(e, for: dir) } }
    }

    private func finishAnalysis() {
        // Shooting order, by EXIF time.
        photos.sort {
            switch ($0.exif.date, $1.exif.date) {
            case let (a?, b?) where a != b: a < b
            default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        reindex()
        aiCount = photos.filter { $0.cull != nil }.count
        groupSeries()
        findDuplicates()
        computeScenes()       // scenes before statistics: sharpness is compared within a scene
        updateCullStats()
    }

    /// Series = consecutive photos with similar images (Hamming distance ≤ 12)
    /// and no more than 30 seconds apart.
    private func groupSeries() {
        var next = 1
        var runStart = 0
        func close(_ end: Int) {
            if end - runStart >= 2 {
                for k in runStart..<end { photos[k].seriesID = next }
                let maxSharp = (runStart..<end).compactMap { photos[$0].cull?.subjectSharpness ?? photos[$0].sharpness }.max() ?? 1
                let best = (runStart..<end).max { seriesRank(photos[$0], maxSharp: maxSharp) < seriesRank(photos[$1], maxSharp: maxSharp) }
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
            // Similar: the quick picture hash, or (after AI analysis) Vision feature prints — they also catch
            // the same moment with a slightly moved camera. Calibrated on 2032 frames: prints under 0.45
            // within 30 s are the same burst; the hash still helps where prints disagree (dark frames).
            var looksSame = false
            if let ha = a.hash, let hb = b.hash, (ha ^ hb).nonzeroBitCount <= 12 { looksSame = true }
            if !looksSame, aiEnabled.contains(.similarity), let pa = a.cull?.print, let pb = b.cull?.print, let d = printDistance(pa, pb), d < 0.45 { looksSame = true }
            var similar = false
            if looksSame {
                if let da = a.exif.date, let db = b.exif.date { similar = abs(db.timeIntervalSince(da)) <= 30 } else { similar = true }
            }
            if !similar {
                close(i)
                runStart = i
            }
        }
        close(photos.count)
    }

    /// Exact duplicate: same file size, same capture time and same image.
    private func findDuplicates() {
        var seen: [String: URL] = [:]
        for i in photos.indices {
            photos[i].duplicateOf = nil
            guard let h = photos[i].hash else { continue }
            let key = "\(photos[i].fileSize)-\(photos[i].exif.date?.timeIntervalSince1970 ?? 0)-\(h)"
            if let first = seen[key] { photos[i].duplicateOf = first } else { seen[key] = photos[i].id }
        }
    }

    // MARK: - Navigation and selection

    /// Selected photos. currentID is the focused one (shown in the loupe and in Info).
    var selection: Set<URL> = []
    private var anchorID: URL?

    /// What ratings, labels and saving act on: the selection, or the current photo if only one is selected.
    var targets: [Photo] {
        let sel = selection.filter { index[$0] != nil }
        if sel.count > 1 { return photos.filter { sel.contains($0.id) } }
        return current.map { [$0] } ?? []
    }

    var multiSelected: Bool { selection.filter { index[$0] != nil }.count > 1 }

    func isSelected(_ p: Photo) -> Bool { p.id == currentID || selection.contains(p.id) }

    private func focus(_ id: URL?, extend: Bool = false) {
        currentID = id   // zoom is kept: handy for flipping through a series and comparing sharpness at 100%
        if culling, let id { viewed.insert(id) }
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

    /// Click: plain selects one photo, ⌘ adds/removes, ⇧ selects a range.
    /// Modifiers at mouse-down time. A SwiftUI single click fires with a delay
    /// (it waits for a possible double click), and by then ⌘ is often already released, so we capture them on mouse-down.
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

    /// Marquee selection: hit = photos touched, in grid order; adding = what was selected before (with ⌘/⇧).
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

    /// Select all photos of the current photo's series.
    func selectSeries() {
        guard let p = current, p.seriesID != nil else { return }
        selection = Set(series(of: p).map(\.id))
    }

    // MARK: - Ratings (applied to all selected)

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

    var countSuffix: String { multiSelected ? tr(" · \(targets.count) шт.") : "" }

    func update(_ title: String? = nil, _ change: (inout Photo) -> Void) {
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

    func advanceAfterDecision() { advanceIfNeeded() }

    private func advanceIfNeeded() {
        guard autoAdvance, !comparing, let cur = currentID else { return }
        let list = visible
        // If the photo dropped out of the current filter, move to the next one after it.
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

    // MARK: - File operations

    /// Moves rejected photos into the `_Отклонённые` subfolder (along with XMP and the paired JPEG). Nothing is deleted.
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

    // MARK: - Save to Folder

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
            // RAW → JPEG is heavy (~1–2 s per 50 MP photo), so run 3 in parallel.
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

    /// S key: save the current photo straight to the save folder (copy of the original + XMP).
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

    /// The selection, or, if only one is selected, everything shown in the filter.
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

    // MARK: - Context menu

    /// Right-click as in Finder: on a selected photo, the action applies to the whole selection;
    /// on an unselected one, select only it first.
    func contextTarget(_ p: Photo) {
        if !isSelected(p) { focus(p.id) }
    }

    /// How many photos an action from this photo's menu will affect.
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

    /// Save dialog with "Selected" and the right format already chosen.
    func exportTargets(as format: ExportSettings.Format) {
        export.scope = .selected
        export.format = format
        showExport = true
    }
}
