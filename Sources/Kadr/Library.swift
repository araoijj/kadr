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
    case series(Int)      // one burst, from the badge on a photo

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
        case .series: tr("Одна серия")
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
        case .series: "square.stack.3d.up"
        }
    }
}

@MainActor
@Observable
final class Library {
    var folder: URL?
    /// Hand-written accessors (what the macro generates, plus one counter): every change — a new list or one
    /// field of one photo — bumps `photosRev`, which the cached derived lists (visible, counts…) compare against.
    @ObservationIgnored private var photoStore: [Photo] = []
    @ObservationIgnored private var photosRev = 0
    var photos: [Photo] {
        get { access(keyPath: \.photos); return photoStore }
        set { withMutation(keyPath: \.photos) { photoStore = newValue; photosRev &+= 1 } }
        _modify {
            access(keyPath: \.photos)
            _$observationRegistrar.willSet(self, keyPath: \.photos)
            defer { photosRev &+= 1; _$observationRegistrar.didSet(self, keyPath: \.photos) }
            yield &photoStore
        }
    }
    var filter: PhotoFilter = .all
    var currentID: URL? {
        // "Remove Object" belongs to one photo: moving on closes it, so clicks on the next photo don't select.
        didSet {
            if removeMode, currentID != removeFor { finishRemove() }
            // So does the crop editor: a manual crop is kept as done; an unaccepted suggestion of the review is dropped.
            if cropMode, currentID != cropFor { closeCrop() }
        }
    }
    var loupe = false
    /// Loupe zoom: nil = fit to window, 1 = 100% (one image pixel = one screen pixel), 2 = 200%…
    var loupeZoom: CGFloat?
    var loupeZoomBase: CGFloat?                    // pinch start
    var loupeCenter = CGPoint(x: 0.5, y: 0.5)      // center of the visible area as fractions of the image (y top-down)
    var fitZoom: CGFloat = 0.25                    // zoom level of "Fit" mode (computed by the loupe view)
    var loupeDisplay: CGSize = .zero               // on-screen image size at the current zoom, in points
    var splitCompare = false                       // before/after split slider (Y)
    var fullscreen = false                         // full-screen viewing window is up (F)
    var photosKey = true                           // the photos are the key window, no sheet over them (KeyHandler.trackKeyWindow)
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
    @ObservationIgnored private var errorToastUntil = Date.distantPast
    @ObservationIgnored private var toastSeq = 0

    private(set) var index: [URL: Int] = [:]

    // The "Culling" layer (Cull.swift, CullView.swift): AI verdicts on the frames, faces at 100%, progress of
    // the pass. A layer over the grid and the loupe, not a view of its own: the view stays as it is.
    var culling = false {
        didSet { if culling, let c = currentID { viewed.insert(c) } }
    }

    /// O / the toolbar toggle: switch the layer and say what it changed, because without an AI analysis
    /// the difference on screen is small (progress, the summary, the decision tag).
    func toggleCullingLayer() {
        culling.toggle()
        guard folder != nil else { return }
        if !culling { flash(tr("Слой «Отбор» выключен")); return }
        if aiOn { flash(tr("Слой «Отбор»: ярлыки AI на кадрах, лица на 100%, прогресс просмотра"), seconds: 2.5) }
        else if aiRunning { flash(tr("Слой «Отбор» включён — ярлыки появятся, когда AI-анализ закончится"), seconds: 2.5) }
        else if aiReady { flash(tr("Слой «Отбор» включён — подсказки AI выключены, включите их в панели «Фильтры»"), seconds: 3) }
        else { flash(tr("Слой «Отбор» включён — запустите AI-анализ, чтобы увидеть ярлыки брака и лица"), seconds: 3) }
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
    // AI noise reduction batch (Denoise.swift).
    var denoiseRunning = false
    var denoiseDone = 0
    var denoiseTotal = 0
    var denoiseFraction = 0.0
    var denoiseTask: Task<Void, Never>?
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
    /// Bumped on every folder open: a background task finishing for an older folder leaves the current one alone.
    private var folderGen = 0
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
    private var pendingHistory: (folder: URL, entries: [HistoryEntry], pos: Int)?

    func photo(_ id: URL) -> Photo? { index[id].map { photos[$0] } }

    func scheduleHistorySave() {
        historySaveTask?.cancel()
        guard let folder else { return }
        pendingHistory = (folder, history, historyPos)
        historySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.submitHistory()
        }
    }

    /// Hands the debounced history snapshot to the writer.
    private func submitHistory() {
        guard let p = pendingHistory else { return }
        historySaveTask?.cancel()
        pendingHistory = nil
        StoreWriter.shared.save("history:" + p.folder.path) { HistoryStore.save(p.entries, p.pos, for: p.folder) }
    }

    func saveEditsSoon(_ ids: [URL]) { scheduleEditsSave(ids) }

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
        scheduleEditsSave([id] + others)
        // Don't record steps while cropping; one step is recorded on "Done".
        if !cropMode {
            let d = describeChange(old, a, url: id)
            record(d.title, before: before, key: "\(id.path)|\(d.key)")
        }
    }

    // MARK: - Crop

    var cropMode = false
    // Remove Object mode (Retouch.swift).
    var removeMode = false
    var removePoints: [CGPoint] = []
    var removeMask: CGImage?
    var removeBusy = false
    var removeBusyText: String?        // what AI is doing right now, shown under the spinner
    var removeStatus: RemoveStatus?    // feedback on the current selection (Retouch.swift)
    var removeArea = 0.0               // share of the frame selected
    var removeFor: URL?
    private var cropBackup: Adjustments?
    private var cropFor: URL?          // the photo the crop editor was opened for; the current one may already be another

    // Auto crop review (AutoCrop.swift): suggestions open one by one in the crop editor.
    var autoCropQueue: [URL] = []
    var autoCropPos = 0
    var autoCropAccepted = 0
    var autoCropRatio: Double?          // nil — keep each photo's own proportions
    var autoCropBusy = false

    func startCrop() {
        guard current != nil else { return }
        cropBackup = current?.adj
        cropFor = currentID
        comparing = false
        loupe = true
        setZoom(nil)
        inspectorTab = .edit
        cropMode = true
    }

    func finishCrop() {
        if let b = cropBackup, let id = cropFor, let p = photo(id) {
            var s = PhotoState(p); s.adj = b
            cropMode = false
            let d = describeChange(b, p.adj, url: id)
            record(d.key == "angle" || d.key == tr("Горизонт") ? d.title : tr("Кадрирование ") + (CropFormat.byID(p.adj.cropAspect)?.title ?? tr("свободное")),
                   before: [id: s])
        }
        cropMode = false
        cropBackup = nil
        cropFor = nil
        autoCropAdvance(accepted: true)
    }

    /// The crop editor's photo differs from how it was when the editor opened.
    var cropEdited: Bool { cropFor.flatMap { photo($0)?.adj } != cropBackup }

    /// The editor closing because the photographer went elsewhere (another photo, undo):
    /// a manual crop is kept as done; an unaccepted suggestion ends the review.
    func closeCrop() {
        guard cropMode else { return }
        if autoCropQueue.isEmpty { finishCrop() } else { stopAutoCropReview() }
    }

    func cancelCrop() {
        // Restored by cropFor, not currentID: the editor may be closing because another photo was opened.
        if let b = cropBackup, let id = cropFor, let i = index[id], photos[i].adj != b { setAdjustmentsRaw(i, b) }
        cropMode = false
        cropBackup = nil
        cropFor = nil
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
        scheduleEditsSave([photos[i].id])
    }

    /// Style, paste and reset apply to all selected photos.
    private func setAdjustmentsForTargets(_ title: String, _ change: (inout Adjustments) -> Void) {
        let before = snapshot(targets.map(\.id))
        for t in targets {
            guard let i = index[t.id] else { continue }
            change(&photos[i].adj)
        }
        scheduleEditsSave(targets.map(\.id))
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
            var b = Self.withAbsoluteWB(a, fromAsShot: srcK, to: t.url)
            // Removed objects and AI denoise are computed from this photo's own pixels: never carried over.
            b.removals = photos[i].adj.removals
            b.aiDenoise = photos[i].adj.aiDenoise
            photos[i].adj = b
        }
        scheduleEditsSave(targets.map(\.id))
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

    /// `ids`: the photos whose settings changed — only their folders are written. A slider tick only marks
    /// them; the folders' snapshots are taken once, when the debounce ends (or a flush asks for them).
    private func scheduleEditsSave(_ ids: [URL]) {
        saveEditsTask?.cancel()
        guard folder != nil else { return }
        for id in ids { editsDirty.insert(id.deletingLastPathComponent()) }
        saveEditsTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.submitEdits()
        }
    }
    @ObservationIgnored private var editsDirty: Set<URL> = []

    /// Every photo of each dirty folder goes into its snapshot: the store drops our fields of a frame missing
    /// from it. Runs before anything replaces or removes photos (folder switch, moves), so they're still here.
    private func submitEdits() {
        saveEditsTask?.cancel()
        guard !editsDirty.isEmpty else { return }
        let dirty = editsDirty
        editsDirty = []
        var byFolder: [URL: [String: Adjustments]] = [:]
        for p in photos {
            let dir = p.url.deletingLastPathComponent()
            if dirty.contains(dir) { byFolder[dir, default: [:]][p.name] = p.adj }
        }
        for (dir, e) in byFolder { StoreWriter.shared.save("edits:" + dir.path) { EditStore.save(e, in: dir) } }
    }

    /// Writes edits that are still waiting for the debounce — before opening another folder and on quit,
    /// otherwise a paste right before switching folders or quitting would be lost. Returns once they're on disk.
    func flushEdits() {
        submitEdits()
        StoreWriter.shared.flush()
    }

    /// Moved files' edits follow them — through the store writer, after the snapshots already waiting, so a
    /// save of the old folder's edits can't race the move and put the moved entries back.
    private func moveEdits(_ pairs: [(from: URL, to: URL)]) {
        guard !pairs.isEmpty else { return }
        submitEdits()
        StoreWriter.shared.save("edits-move:", barrier: true) { EditStore.move(pairs) }
    }

    /// Everything the open folder still has waiting — index, history, edits — handed to the writer now:
    /// on a folder switch, where a debounced or every-50-photos save would otherwise be lost.
    private func submitStores() {
        if folder != nil, !photos.isEmpty { saveIndex() }
        submitHistory()
        submitEdits()
    }

    /// The same, waited for: on quit.
    func flushStores() {
        submitStores()
        StoreWriter.shared.flush()
    }
    private var analysisTask: Task<Void, Never>?

    // MARK: - Filtering

    /// Rejected photos are hidden in every view except the "Rejected" one (H).
    var hideRejected = UserDefaults.standard.bool(forKey: "hideRejected") {
        didSet { UserDefaults.standard.set(hideRejected, forKey: "hideRejected") }
    }

    var visible: [Photo] { visible(listKey()) }

    // MARK: - Cached derived lists
    // visible, sections, the filter counts, verdicts and the top sharpness used to be recomputed (filter, sort,
    // a verdict per photo) by every call — dozens per render, on every arrow press. Each is kept until one of
    // its inputs changes. Building a key reads every input, so a view reading a cached value still observes
    // all of them and updates on any change, as before.

    /// Verdict inputs besides the photo itself. The folder statistics change only in updateCullStats.
    struct VerdictKey: Equatable { var strictness: Double; var ai: Set<AIModule>; var stats: Int }
    @ObservationIgnored var cullStatsRev = 0
    @ObservationIgnored var verdictCache: (key: VerdictKey, byID: [URL: (sig: VerdictSig, v: CullVerdict)])?

    /// The fields of a photo its verdict reads.
    struct VerdictSig: Equatable {
        var duplicate: Bool, scene: Int?, series: Int?, best: Bool, cull: CullData?
        init(_ p: Photo) { duplicate = p.duplicateOf != nil; scene = p.sceneID; series = p.seriesID; best = p.isBestInSeries; cull = p.cull }
    }

    func verdictKey() -> VerdictKey {
        access(keyPath: \.sceneMedians); access(keyPath: \.cullMedianSharpness); access(keyPath: \.cullMedianFaceSharpness)
        access(keyPath: \.seriesBestSharpness); access(keyPath: \.seriesOpenEyes); access(keyPath: \.seriesOpenPoses)
        access(keyPath: \.seriesBestPrint)
        return VerdictKey(strictness: cullStrictness, ai: aiEnabled, stats: cullStatsRev)
    }

    private struct ListKey: Equatable {
        var photos: Int, filter: PhotoFilter, hideRejected: Bool, lens: String?, day: Date?, tags: Set<String>
        var persons: Set<Int>, people: [Person], aiReady: Bool, verdicts: VerdictKey
        var sort: SortKey, descending: Bool, group: GroupKey, folder: URL?
    }
    @ObservationIgnored private var visibleCache: (key: ListKey, pos: [URL: Int], list: [Photo])?
    @ObservationIgnored private var sectionsCache: (key: ListKey, scenes: [SceneInfo], value: [(title: String, photos: [Photo])])?
    private struct CountKey: Equatable { var photos: Int, verdicts: VerdictKey, aiReady: Bool }
    @ObservationIgnored private var countCache: (key: CountKey, counts: [PhotoFilter: Int])?
    @ObservationIgnored private var maxSharpnessCache: (rev: Int, value: Double?)?

    private func listKey() -> ListKey {
        access(keyPath: \.photos)
        return ListKey(photos: photosRev, filter: filter, hideRejected: hideRejected, lens: lensFilter, day: dayFilter, tags: tagFilters,
                       persons: personFilters, people: personFilters.isEmpty ? [] : people, aiReady: aiReady, verdicts: verdictKey(),
                       sort: sortKey, descending: sortDescending, group: groupKey, folder: folder)
    }

    private func visible(_ key: ListKey) -> [Photo] {
        if let c = visibleCache, c.key == key { return c.list }
        let found = photos.filter { p in
            matches(p, filter)
                && (!hideRejected || !p.rejected || filter == .rejected)
                && (lensFilter == nil || p.lensName == lensFilter)
                && (dayFilter == nil || p.day == dayFilter)
                && (tagFilters.isEmpty || !aiEnabled.contains(.tags) || (p.cull?.tags?.contains(where: tagFilters.contains) ?? false))
                && (personFilters.isEmpty || personFilters.contains { person($0)?.photos.contains(p.id) ?? false })
        }
        // A slider tick or a mark rarely moves a photo: if the same photos pass, put them in the last order
        // and check it still holds — n comparisons instead of a sort.
        var list: [Photo] = []
        if let c = visibleCache, c.pos.count == found.count {
            var placed = [Photo?](repeating: nil, count: found.count)
            for p in found { guard let i = c.pos[p.id] else { break }; placed[i] = p }
            let reused = placed.compactMap { $0 }
            if reused.count == found.count, zip(reused, reused.dropFirst()).allSatisfy({ !inOrder($1, $0) }) { list = reused }
        }
        if list.count != found.count { list = found.sorted(by: inOrder) }
        visibleCache = (key, Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) }), list)
        return list
    }

    /// The folder's top sharpness, for the sharpness bars: once per change of the photos, not per pane and frame.
    var maxSharpness: Double? {
        access(keyPath: \.photos)
        if let c = maxSharpnessCache, c.rev == photosRev { return c.value }
        let m = photos.compactMap(\.sharpness).max()
        maxSharpnessCache = (photosRev, m)
        return m
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
    static let compareMax = 200
    /// Width of a compared frame in points; 0 means automatic (fill the window, scroll when crowded).
    var compareTile: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "compareTile")) {
        didSet { UserDefaults.standard.set(Double(compareTile), forKey: "compareTile") }
    }
    static let compareTileRange: ClosedRange<CGFloat> = 160...1200

    /// + and − in Compare: bigger or smaller frames; from automatic, the first step starts at a medium size.
    func compareTileStep(_ direction: Int) {
        let base = compareTile > 0 ? compareTile : 400
        compareTile = min(max(base * (direction > 0 ? 1.25 : 0.8), Self.compareTileRange.lowerBound), Self.compareTileRange.upperBound)
    }
    var compareKeep: Set<URL> = []                 // frames marked to keep (checkmark, P, space)
    var compareReject: Set<URL> = []               // frames marked as rejects (cross, X)

    var comparePhotos: [Photo] { compareIDs.compactMap { index[$0].map { photos[$0] } } }

    /// Whether comparison is possible: 2+ photos selected, or the current one belongs to a series.
    var canCompare: Bool { multiSelected || (current.map { series(of: $0).count > 1 } ?? false) }

    /// The selection (up to 4), or, if only one is selected, up to 4 photos of its series starting from it.
    func startCompare() {
        var ids: [URL]
        if multiSelected {
            ids = targets.map(\.id)
            if ids.count > Self.compareMax { flash(tr("Сравниваю первые \(Self.compareMax) из \(ids.count)")) }
        } else if let p = current, p.seriesID != nil {
            let s = series(of: p).map(\.id)
            let i = s.firstIndex(of: p.id) ?? 0
            ids = Array(s[max(0, min(i, s.count - Self.compareMax))...])
            if s.count > Self.compareMax { flash(tr("В серии \(s.count) кадров — показаны \(Self.compareMax), начиная с текущего")) }
        } else {
            flash(tr("Выделите хотя бы 2 кадра: ⌘-клик или рамкой"))
            return
        }
        ids = Array(ids.prefix(Self.compareMax))
        guard ids.count >= 2 else { flash(tr("Выделите хотя бы 2 кадра: ⌘-клик или рамкой")); return }
        compareIDs = ids
        compareKeep = []
        compareReject = []
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
        compareKeep = []
        compareReject = []
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

    /// Mark or unmark a compared frame to keep; nil means the focused one. A keep mark clears a reject mark.
    func toggleCompareKeep(_ id: URL? = nil) {
        guard let id = id ?? currentID, compareIDs.contains(id) else { return }
        if compareKeep.contains(id) { compareKeep.remove(id) } else { compareKeep.insert(id); compareReject.remove(id) }
    }

    /// Mark or unmark a compared frame as a reject (the explicit "no"); clears a keep mark.
    func toggleCompareReject(_ id: URL? = nil) {
        guard let id = id ?? currentID, compareIDs.contains(id) else { return }
        if compareReject.contains(id) { compareReject.remove(id) } else { compareReject.insert(id); compareKeep.remove(id) }
    }

    /// The frames that "Keep" applies to: the marked ones, or the focused one when nothing is marked.
    var compareKeeping: [URL] {
        let marked = compareIDs.filter { compareKeep.contains($0) }
        if !marked.isEmpty { return marked }
        return currentID.map { [$0] } ?? []
    }

    /// With ✗ marks the unmarked frames are left alone; with ✓ marks only, everything unmarked is a reject.
    var compareHasExplicitRejects: Bool { compareIDs.contains { compareReject.contains($0) } }

    /// Apply the marks. ✓ → ★ (if unrated) and not rejected. ✗ → rejected. Unmarked: rejected when the
    /// marks are ✓ only (the quick "keep these, drop the rest"), untouched when there are ✗ marks.
    /// Nothing marked: the focused frame is kept, the rest rejected. One undo step.
    func rejectOthersInCompare() {
        let explicit = compareHasExplicitRejects
        let keep = Set(explicit ? compareIDs.filter { compareKeep.contains($0) } : compareKeeping)
        let drop = Set(explicit ? compareIDs.filter { compareReject.contains($0) } : compareIDs.filter { !keep.contains($0) })
        guard !keep.isEmpty || !drop.isEmpty else { return }
        let before = snapshot(compareIDs)
        var failed = 0
        for id in compareIDs {
            guard let i = index[id] else { continue }
            if keep.contains(id) {
                photos[i].rejected = false
                if photos[i].rating == 0 { photos[i].rating = 1 }
            } else if drop.contains(id) {
                photos[i].rejected = true
            } else {
                continue
            }
            if !writeSidecar(i) { failed += 1 }
        }
        let what = keep.count == 1 ? keep.first!.lastPathComponent : tr("\(keep.count) кадра")
        record(keep.isEmpty ? tr("Отклонено в сравнении: \(drop.count)") : tr("Оставлено: \(what)"), before: before)
        compareKeep = []
        compareReject = []
        stopCompare()
        flashWritten(keep.isEmpty ? tr("Отклонено: \(drop.count)") : tr("Оставлено: \(what), отклонено: \(drop.count)"), failed: failed)
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
    /// Whether the open shoot was gathered with its subfolders. A property of the shoot, remembered
    /// per folder (FolderState), chosen when scanning; flipping it here re-reads the open folder.
    private var recursiveStorage = false
    private var recursiveKnown = true
    var includeSubfolders: Bool {
        get { recursiveStorage }
        set {
            guard newValue != recursiveStorage, recursiveKnown else { return }
            recursiveStorage = newValue
            // Passed on: while the folder is still being read there's no state saved to take it from.
            if let folder { saveFolderState(); open(folder, recursive: newValue) }
        }
    }
    var lensFilter: String?
    var dayFilter: Date?
    /// Vision tags after AI analysis; several tags = any of them ("or").
    var tagFilters: Set<String> = []
    /// People after AI analysis (People.swift); several people = any of them ("or").
    var personFilters: Set<Int> = []

    /// Anything narrowing the folder besides the main filter: lens, day, tags, people, hidden rejects.
    var extraFiltersActive: Bool {
        lensFilter != nil || dayFilter != nil || !tagFilters.isEmpty || !personFilters.isEmpty || (hideRejected && filter != .rejected)
    }

    /// "Reset all": back to every photo of the folder.
    func resetFilters() {
        filter = .all
        lensFilter = nil; dayFilter = nil; tagFilters = []; personFilters = []
        hideRejected = false
        move(0)
    }

    /// One click on a person: the only one selected, or none if it was the only one already;
    /// ⌘-click (`add`) toggles it in the set, so several people are "any of them".
    func togglePerson(_ id: Int, add: Bool) {
        if add { if personFilters.remove(id) == nil { personFilters.insert(id) } }
        else { personFilters = personFilters == [id] ? [] : [id] }
        move(0)
    }

    func toggleTag(_ id: String, add: Bool) {
        if add { if tagFilters.remove(id) == nil { tagFilters.insert(id) } }
        else { tagFilters = tagFilters == [id] ? [] : [id] }
        move(0)
    }
    var people: [Person] = []

    /// Lenses and shooting days with photo counts, for the sidebar.
    var lenses: [(name: String, count: Int)] {
        Dictionary(grouping: photos, by: \.lensName).map { ($0.key, $0.value.count) }.sorted { $0.name < $1.name }
    }

    var days: [(day: Date, count: Int)] {
        Dictionary(grouping: photos.filter { $0.day != nil }, by: { $0.day! }).map { ($0.key, $0.value.count) }.sorted { $0.day > $1.day }
    }

    /// Grid sections: consecutive photos sharing the same group key.
    var sections: [(title: String, photos: [Photo])] {
        let key = listKey()
        let list = visible(key)
        let sc = groupKey == .scene ? scenes : []
        if let c = sectionsCache, c.key == key, c.scenes == sc { return c.value }
        var out: [(title: String, photos: [Photo])] = []
        if groupKey == .none {
            out = [("", list)]
        } else {
            // Day and scene titles are formatted or looked up once per group, not per photo.
            var memo: [AnyHashable: String] = [:]
            for p in list {
                let k: AnyHashable? = groupKey == .day ? AnyHashable(p.day) : groupKey == .scene ? AnyHashable(p.sceneID) : nil
                let t = k.flatMap { memo[$0] } ?? groupTitle(p)
                if let k { memo[k] = t }
                if out.last?.title == t { out[out.count - 1].photos.append(p) } else { out.append((t, [p])) }
            }
        }
        sectionsCache = (key, sc, out)
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
            let r = cmp(a.takenAt, b.takenAt)
            return r == .orderedSame ? a.name.localizedStandardCompare(b.name) : r
        case .name: return a.name.localizedStandardCompare(b.name)
        case .rating: return cmp(b.rejected ? -1 : b.rating, a.rejected ? -1 : a.rating)
        case .lens: return a.lensName.localizedStandardCompare(b.lensName)
        case .folder: return folderSortKey(a).localizedStandardCompare(folderSortKey(b))
        case .size: return cmp(b.fileSize, a.fileSize)
        }
    }

    private func cmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
    private func flip(_ r: ComparisonResult) -> ComparisonResult { r == .orderedAscending ? .orderedDescending : r == .orderedDescending ? .orderedAscending : r }

    /// Photos of the folder matching a filter; the counts are kept until the photos or the verdicts change.
    func count(_ f: PhotoFilter) -> Int {
        access(keyPath: \.photos)
        let key = CountKey(photos: photosRev, verdicts: verdictKey(), aiReady: aiReady)
        if countCache?.key != key { countCache = (key, [:]) }
        if let n = countCache?.counts[f] { return n }
        let n = photos.reduce(0) { $0 + (matches($1, f) ? 1 : 0) }
        countCache?.counts[f] = n
        return n
    }

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
        case .series(let id): p.seriesID == id
        case .recommended: isRecommended(p)
        case .smiling: aiEnabled.contains(.faces) && !p.rejected && (p.cull?.faces.contains { $0.meshUsable && ($0.smile ?? 0) >= 0.6 } ?? false)
        }
    }

    var current: Photo? {
        guard let id = currentID, let i = index[id] else { return nil }
        return photos[i]
    }

    func series(of p: Photo) -> [Photo] {
        guard let s = p.seriesID else { return [] }
        return photos.filter { $0.seriesID == s }
    }

    // MARK: - Opening a folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = tr("Сканировать")
        panel.message = tr("Выберите папку со съёмкой")
        if panel.runModal() == .OK, let url = panel.url { scan(url) }
    }

    /// "Scan": the folder becomes a shoot (top of the sidebar) and opens. The only way in.
    /// `recursive` nil = what the folder was scanned with before, else a guess: a folder with no photos
    /// of its own but photos inside its subfolders is gathered whole.
    func scan(_ url: URL, recursive: Bool? = nil) {
        browser.addShoot(url)
        open(url, recursive: recursive)
    }

    /// Reads the folder and shows it. Doesn't touch the shoots list: that's `scan`.
    /// The reading (tree walk, every XMP, indexes, edits, history) runs off the main thread: on a few thousand
    /// RAW on a HDD, NAS or card it takes seconds. A quicker second switch wins: an older read is dropped (folderGen).
    func open(_ url: URL, recursive: Bool? = nil) {
        analysisTask?.cancel()
        openTask?.cancel()
        aiTask?.cancel(); aiRunning = false; aiCount = 0
        // The old folder's latest index (the analysis saves only every 50 photos), history and edits are
        // queued for the disk; the cancelled tasks finish later and must not touch the new folder (folderGen).
        submitStores()
        folderGen += 1
        let gen = folderGen
        saveFolderState()
        folder = url
        let state = FolderState.load(url) ?? FolderState()
        // Known already unless the folder is new: the toggle shows it while the folder is read.
        if let m = recursive ?? state.recursive { recursiveStorage = m }
        // A new folder's mode is only guessed once it is read: until then the toggle can't flip it.
        recursiveKnown = (recursive ?? state.recursive) != nil
        filter = .all
        lensFilter = nil
        tagFilters = []
        personFilters = []
        people = []
        dayFilter = nil
        loupe = false
        loupeZoom = nil
        viewed = []
        culling = Prefs.cullByDefault
        restoreFolderView(state)
        loading = true
        analyzed = 0
        // Nothing of the old folder stays reachable while the new one is read.
        photos = []
        reindex()
        focus(nil)
        (history, historyPos) = ([], 0)
        openTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let r = Self.read(url, recursive: recursive ?? state.recursive) else { return }
            await self?.finishOpen(r, gen: gen)
        }
    }
    private var openTask: Task<Void, Never>?

    /// What `read` found in a folder.
    private struct FolderRead: Sendable {
        var recursive: Bool
        var photos: [Photo]
        var indexDirty: Bool
        var history: ([HistoryEntry], Int)
    }

    /// Off the main thread. `recursive` nil = a freshly scanned folder: guessed from what's inside.
    /// Nil when cancelled by a newer open.
    nonisolated private static func read(_ url: URL, recursive: Bool?) -> FolderRead? {
        let mode = recursive ?? FolderBrowser.suggestRecursive(url)
        let files = imageFiles(in: url, recursive: mode)
        guard !Task.isCancelled else { return nil }

        // If a RAW and a JPEG with the same name sit side by side, show only the RAW.
        let rawBases = Set(files.filter { ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().path })
        let chosen = files.filter {
            ImageStore.rawExtensions.contains($0.pathExtension.lowercased()) || !rawBases.contains($0.deletingPathExtension().path)
        }

        // Each folder keeps its own edits.
        var edits: [URL: [String: Adjustments]] = [:]
        var indexes: [URL: [String: IndexEntry]] = [:]
        let dirs = Set(chosen.map { $0.deletingLastPathComponent() })
        // Only a write still pending for these very folders (the same folder again, a subfolder) is waited for.
        // Waited for here, not on the main thread; the writer stays the only one writing the stores.
        StoreWriter.shared.flush(touching: Set(dirs.map(\.path)).union([url.path]))
        for dir in dirs {
            edits[dir] = EditStore.load(dir)
            indexes[dir] = AnalysisIndex.load(dir)
        }
        var photos: [Photo] = []
        photos.reserveCapacity(chosen.count)
        for f in chosen {
            if Task.isCancelled { return nil }
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            let s = Sidecar.read(for: f)
            var p = Photo(id: f, fileSize: size, rating: s.rating, rejected: s.rejected, label: s.label, otherLabel: s.otherLabel)
            p.mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
            p.adj = edits[f.deletingLastPathComponent()]?[f.lastPathComponent] ?? .none
            // Already analyzed and the file hasn't changed: take it from the index instead of recomputing.
            if let c = indexes[f.deletingLastPathComponent()]?[f.lastPathComponent], c.size == size, c.mtime == p.mtime {
                p.exif = c.exif; p.hash = c.hash; p.sharpness = c.sharpness; p.cull = c.cull; p.indexed = true
            }
            photos.append(p)
        }
        photos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        // Rewritten only when something changed: entries of files that are gone count too.
        let dirty = indexes.values.reduce(0) { $0 + $1.count } != photos.filter(\.indexed).count
        return FolderRead(recursive: mode, photos: photos, indexDirty: dirty, history: HistoryStore.load(url))
    }

    /// Back on the main thread: shows what was read, unless another folder was opened meanwhile.
    private func finishOpen(_ r: FolderRead, gen: Int) {
        guard gen == folderGen, let url = folder else { return }
        var state = FolderState.load(url) ?? FolderState()
        if state.recursive != r.recursive { state.recursive = r.recursive; FolderState.save(state, for: url) }
        recursiveStorage = r.recursive
        recursiveKnown = true
        photos = r.photos
        indexDirty = r.indexDirty
        reindex()
        focus(visible.first?.id)
        restoreCurrent(url)
        (history, historyPos) = r.history
        loading = false
        startAnalysis()
    }

    func reload() { if let folder { saveFolderState(); open(folder) } }

    /// Forget the index of the open folder (and its subfolders) and recompute it.
    func reanalyze() {
        guard let folder else { return }
        saveFolderState()
        let dirs = Set(photos.map { $0.url.deletingLastPathComponent() })
        // Nothing of the old index may be written back over the deletion: it takes the index's place in the
        // writer's queue, after any save already running, and open waits for it. The photos are dropped
        // so the folder switch has no index to save.
        analysisTask?.cancel(); aiTask?.cancel()
        submitEdits()   // its snapshot is built from photos: an edit still in the debounce would be lost below
        folderGen += 1
        photos = []
        reindex()
        for dir in dirs {
            StoreWriter.shared.save("index:" + dir.path) { try? FileManager.default.removeItem(at: AnalysisIndex.file(for: dir)) }
        }
        open(folder)
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
        // Frames that left (moved, deleted, another folder) leave the pass and the verdict cache too:
        // the culling bar then counts `viewed` as is, without filtering every photo per render.
        let gone = viewed.filter { index[$0] == nil }
        if !gone.isEmpty { viewed.subtract(gone) }
        if let byID = verdictCache?.byID, byID.keys.contains(where: { index[$0] == nil }) {
            verdictCache?.byID = byID.filter { index[$0.key] != nil }
        }
    }

    /// In the background: EXIF, preview, hash and sharpness, then series and duplicates.
    /// Background and gentle: only new/changed files, 2 low-priority threads,
    /// the index is saved as it goes (every 50 photos), so an interrupted analysis isn't lost.
    private func startAnalysis() {
        analyzed = photos.filter(\.indexed).count
        let urls = photos.filter { !$0.indexed }.map(\.id)
        guard !urls.isEmpty else {
            finishAnalysis()
            // Indexed on an earlier visit: the "after indexing" auto start still applies.
            if Prefs.aiAuto { startAI() }
            return
        }
        analysisTask = runPass(urls, work: { u in
            let store = ImageStore.shared
            // As-shot white balance (~40 ms, CIRAWFilter) is not computed here: only editing needs it, so it's computed on demand.
            let exif = store.exif(u)
            guard let img = store.preview(u) else { return (u, exif, nil as UInt64?, nil as Double?) }
            // Lightweight indexing only (~5 ms): EXIF, hash for series and duplicates, overall sharpness.
            // Faces, eyes and the rest of the AI analysis run on a button press (startAI); it loads the Mac heavily.
            return (u, exif, store.dHash(img), store.sharpness(img))
        }, apply: { lib, b in
            for (u, exif, h, s) in b {
                guard let i = lib.index[u] else { continue }
                lib.photos[i].exif = exif
                lib.photos[i].hash = h
                lib.photos[i].sharpness = s
                lib.photos[i].indexed = true
            }
            lib.analyzed += b.count
        }, done: { lib, cancelled in
            guard !cancelled else { return }
            lib.finishAnalysis()
            if Prefs.aiAuto { lib.startAI() }
        })
    }

    /// The folder's background passes (indexing, AI): `work` on a few low-priority threads, results handed to
    /// `apply` on the main thread in batches (every change to photos redraws the counters for the whole folder),
    /// the index saved as it goes (every 50 photos) and at the end. Results that arrive after another folder was
    /// opened (or a reload) are dropped: open() already saved that folder's index. `done` runs last, for the same folder only.
    private func runPass<Job: Sendable, Result: Sendable>(
        _ jobs: [Job], work: @escaping @Sendable (Job) async -> Result,
        apply: @escaping @MainActor (Library, [Result]) -> Void,
        done: @escaping @MainActor (Library, _ cancelled: Bool) -> Void
    ) -> Task<Void, Never> {
        let gen = folderGen
        return Task { [weak self] in
            let workers = min(max(1, Prefs.analysisThreads), 4)
            var sinceSave = 0
            await withTaskGroup(of: Result.self) { group in
                var it = jobs.makeIterator()
                func add() -> Bool {
                    guard let job = it.next() else { return false }
                    group.addTask(priority: .utility) { await work(job) }
                    return true
                }
                for _ in 0..<workers { _ = add() }
                var batch: [Result] = []
                func flush() async {
                    let b = batch; batch = []
                    sinceSave += b.count
                    let save = sinceSave >= 50
                    if save { sinceSave = 0 }
                    await MainActor.run {
                        guard let self, self.folderGen == gen else { return }
                        apply(self, b)
                        self.indexDirty = true
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
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, self.folderGen == gen else { return }
                self.saveIndex()
                done(self, cancelled)
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
        aiTask = runPass(jobs, work: { job in
            let (u, mods, base) = job
            guard let img = ImageStore.shared.preview(u) else { return (u, nil as CullData?) }
            return (u, await CullAnalyzer.analyze(img, modules: mods, into: base))
        }, apply: { lib, b in
            for (u, cull) in b {
                guard let i = lib.index[u], let cull else { continue }
                if lib.photos[i].cull == nil { lib.aiCount += 1 }
                lib.photos[i].cull = cull
            }
            lib.aiDone += b.count
        }, done: { lib, cancelled in
            // After a folder switch aiRunning belongs to the new folder's analysis, if any (runPass drops it then).
            lib.aiRunning = false
            lib.finishAnalysis()   // best in series and medians, now taking faces and eyes into account
            if Prefs.tagsToXMP, !cancelled { lib.writeTagKeywords(ask: false) }
        })
    }

    func stopAI() { aiTask?.cancel() }

    /// After modules are turned on or off: regroup bursts and recount (findings of off modules disappear).
    func aiModulesChanged() { if !photos.isEmpty, !aiRunning, analyzed >= photos.count { finishAnalysis() } }

    /// Per-folder index: only analyzed files; deleted ones drop out on their own.
    /// Written only when it changed since the last save: a folder switch alone costs no SSD write.
    private var indexDirty = false
    private func saveIndex() {
        guard indexDirty else { return }
        indexDirty = false
        var byDir: [URL: [String: IndexEntry]] = [:]
        for p in photos where p.indexed {
            byDir[p.url.deletingLastPathComponent(), default: [:]][p.name] =
                IndexEntry(size: p.fileSize, mtime: p.mtime, exif: p.exif, hash: p.hash, sharpness: p.sharpness, cull: p.cull)
        }
        for (dir, e) in byDir { StoreWriter.shared.save("index:" + dir.path) { AnalysisIndex.save(e, for: dir) } }
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
        computePeople()
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

    /// ↑/↓ in the grid: one row up or down. Every section starts a new row, so the row and column are counted
    /// within the section, not over the flat list (an incomplete last row would shift the column).
    func moveRow(_ dir: Int, extend: Bool = false) {
        let secs = sections.map(\.photos).filter { !$0.isEmpty }
        let c = max(1, columns)
        guard let id = currentID, let s = secs.firstIndex(where: { $0.contains { $0.id == id } }),
              let i = secs[s].firstIndex(where: { $0.id == id }) else { return move(dir, extend: extend) }
        let col = i % c, row = i / c
        let target: Photo
        if dir > 0 {
            if (row + 1) * c < secs[s].count { target = secs[s][min((row + 1) * c + col, secs[s].count - 1)] }
            else if s + 1 < secs.count { target = secs[s + 1][min(col, secs[s + 1].count - 1)] }
            else { target = secs[s][secs[s].count - 1] }
        } else {
            if row > 0 { target = secs[s][(row - 1) * c + col] }
            else if s > 0 {
                let prev = secs[s - 1]
                target = prev[min((prev.count - 1) / c * c + col, prev.count - 1)]
            } else { target = secs[s][0] }
        }
        focus(target.id, extend: extend)
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

    /// The filter that was on before a burst was opened: Esc goes back to it.
    var filterBeforeSeries: PhotoFilter?

    /// Only this burst in the grid and the filmstrip; the filter bar shows "Одна серия" with a way back.
    func showSeries(of p: Photo) {
        guard let id = p.seriesID else { return }
        if case .series = filter {} else { filterBeforeSeries = filter }
        filter = .series(id)
        lensFilter = nil; dayFilter = nil; tagFilters = []
        select(p)
    }

    var inSeries: Bool { if case .series = filter { true } else { false } }

    /// Back from a burst to the photos you came from (Esc, the button in the filter bar). The photo you are
    /// on stays current if that view still has it, otherwise the nearest one is taken.
    func leaveSeries() {
        guard inSeries else { return }
        filter = filterBeforeSeries ?? .all
        filterBeforeSeries = nil
        if let c = currentID, !visible.contains(where: { $0.id == c }) { focus(visible.first?.id) }
    }

    /// The current view has no photos left (everything rejected and hidden, moved away…): show everything.
    func showAllPhotos() {
        filter = .all
        filterBeforeSeries = nil
        hideRejected = false
        lensFilter = nil; dayFilter = nil; tagFilters = []
        if current == nil || !visible.contains(where: { $0.id == currentID }) { focus(visible.first?.id) }
    }

    // MARK: - Ratings (applied to all selected)

    func setRating(_ r: Int) {
        let many = multiSelected
        let order = shownOrder
        update(r == 0 ? tr("Оценка снята") : String(repeating: "★", count: r)) { $0.rating = r; $0.rejected = false }
        if r == 0 { flash(tr("Оценка снята") + countSuffix) } else { flashDecision(String(repeating: "★", count: r), undo: tr("U — снять")) }
        if many { settleSelection(after: order) } else { advanceIfNeeded(after: order) }
    }

    func toggleReject() {
        let many = multiSelected
        let reject = !targets.allSatisfy(\.rejected)
        // X on the cropped photo that the rejection would hide ("Hide rejects"): the editor is closed first, as
        // done, so it never stays on a hidden photo and the crop is its own step before the rejection.
        if reject, cropMode, autoCropQueue.isEmpty, let id = currentID, let i = index[id] {
            let was = photos[i].rejected
            photos[i].rejected = true
            let hides = !visible.contains { $0.id == id }
            photos[i].rejected = was
            if hides { closeCrop() }
        }
        let order = shownOrder
        update(reject ? tr("Отклонено") : tr("Возвращено")) { $0.rejected = reject }
        if reject { flashDecision(tr("Брак"), undo: tr("⌘Z или U — вернуть")) } else { flash(tr("Возвращено") + countSuffix) }
        if many { settleSelection(after: order) } else if reject { advanceIfNeeded(after: order) }
    }

    func toggleLabel(_ l: ColorLabel) {
        let clear = targets.allSatisfy { $0.label == l }
        let order = shownOrder
        update(clear ? tr("Метка снята") : tr("Метка: \(l.title)")) { $0.label = clear ? nil : l; $0.otherLabel = nil }
        flash((clear ? tr("Метка снята") : l.title) + countSuffix)
        if multiSelected { settleSelection(after: order) }
    }

    /// After a decision on several photos: if some of them left the current view (rejected in "Undecided",
    /// hidden by "Hide rejects"), the selection would point at photos no longer on screen and the grid
    /// would jump. Continue from the photo after the last selected one, as the list was shown; at the end
    /// of the list, the one before the first. Photos that stay visible keep their selection.
    private func settleSelection(after order: [URL]) {
        let shown = Set(visible.map(\.id))
        guard selection.contains(where: { !shown.contains($0) }) else { return }
        let positions = selection.compactMap { order.firstIndex(of: $0) }
        if let last = positions.max(), let next = order[(last + 1)...].first(where: { shown.contains($0) }) { focus(next); return }
        if let first = positions.min(), let prev = order[..<first].last(where: { shown.contains($0) }) { focus(prev); return }
        focus(visible.first?.id)
    }

    var countSuffix: String { multiSelected ? tr(" · \(targets.count) шт.") : "" }

    func update(_ title: String? = nil, _ change: (inout Photo) -> Void) {
        let before = snapshot(targets.map(\.id))
        defer { if let title { record(title + countSuffix, before: before) } }
        var failed = 0
        for t in targets {
            guard let i = index[t.id] else { continue }
            let old = photos[i]
            change(&photos[i])
            // Only the fields that changed: a rating write leaves the label (maybe one Kadr can't show) alone.
            let p = photos[i]
            var fields: Sidecar.Fields = p.label != old.label || p.otherLabel != old.otherLabel ? .label : []
            if p.rating != old.rating || p.rejected != old.rejected || fields.isEmpty { fields.insert(.rating) }
            if !writeSidecar(i, fields) { failed += 1 }
        }
        if failed > 0 { flash(tr("Не удалось записать XMP: \(failed) шт."), seconds: 4, error: true) }
    }

    /// The order the photos are shown in right now (filter, sort, grouping): captured before a decision,
    /// because the decision itself may remove the photo from the view or change its place in it.
    var shownOrder: [URL] { visible.map(\.id) }

    func advanceAfterDecision(after order: [URL]) { advanceIfNeeded(after: order) }

    /// After a decision on one photo: the next one as the list was shown. If the photo just left the
    /// current view (rejected in "Undecided", hidden by "Hide rejects"), continue from the same place:
    /// the next still-shown photo after it, or the previous one at the end of the list.
    private func advanceIfNeeded(after order: [URL]) {
        guard !comparing, let cur = currentID else { return }
        let list = visible
        let stays = list.contains { $0.id == cur }
        if cropMode {
            // The crop editor stays on its photo, as with the arrows, while the photo is shown. One that left
            // the view (X with "Hide rejects") skips to the review's next suggestion or, like moving on, closes the editor.
            guard !stays else { return }
            if !autoCropQueue.isEmpty { cancelCrop(); return }
        }
        guard autoAdvance, !list.isEmpty else { return }
        if stays { move(1); return }
        let shown = Set(list.map(\.id))
        if let i = order.firstIndex(of: cur) {
            if let next = order[(i + 1)...].first(where: { shown.contains($0) }) { focus(next); return }
            if let prev = order[..<i].last(where: { shown.contains($0) }) { focus(prev); return }
        }
        focus(list.first?.id)
    }

    /// `error`: a failure the user must see (XMP not written). It stays its time on screen: the decision
    /// toast that follows it in the same action would otherwise replace it at once.
    func flash(_ text: String, seconds: Double = 1.2, error: Bool = false) {
        if error { errorToastUntil = Date().addingTimeInterval(seconds) } else if Date() < errorToastUntil { return }
        toast = text
        // By turn, not by text: the same text shown again must not be cleared by the first one's timer.
        toastSeq += 1
        let shown = toastSeq
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if self.toastSeq == shown { self.toast = nil }
        }
    }

    /// A decision just happened: say what, and how to take it back. Stays a little longer than a plain
    /// toast, because in "Undecided" the photo leaves the screen and this is the only trace of what happened.
    private func flashDecision(_ what: String, undo: String) {
        flash(what + countSuffix + " · " + undo, seconds: 2.2)
    }

    // MARK: - File operations

    /// Moves rejected photos into the `_Отклонённые` subfolder (along with XMP and the paired JPEG). Nothing is deleted.
    static let rejectedFolderName = "_Отклонённые"

    /// All rejected photos of the folder → "_Отклонённые" (menu Culling, the Rejected view).
    func moveRejected() { moveToRejectedFolder(photos.filter(\.rejected)) }

    /// The clicked or selected photos → "_Отклонённые" (context menu); ones not rejected yet are rejected first.
    func moveTargetsToRejectedFolder() { moveToRejectedFolder(targets) }

    /// Moves the photos with their companions (XMP, JPEG twin) into "_Отклонённые" next to them.
    /// The files are kept, so this is the safe way to get rejects out of the way; it can't be undone with ⌘Z.
    func moveToRejectedFolder(_ list: [Photo], ask: Bool = true) {
        guard !list.isEmpty else { flash(tr("Нет отклонённых")); return }
        let fresh = list.filter { !$0.rejected }.count
        if ask {
        let alert = NSAlert()
        alert.messageText = tr("Перенести \(list.count) кадров в папку «_Отклонённые»?")
        alert.informativeText = tr("Папка создаётся рядом со съёмкой, файлы не удаляются — их можно вернуть в Finder. Отменить через ⌘Z нельзя.")
            + (fresh > 0 ? "\n" + tr("Ещё не отклонённые (\(fresh)) будут помечены как брак.") : "")
        alert.addButton(withTitle: tr("Перенести"))
        alert.addButton(withTitle: tr("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        var errors: [String] = []
        for p in list where !p.rejected {
            if let i = index[p.id] {
                photos[i].rejected = true
                if !writeSidecar(i) { errors.append("\(Sidecar.url(for: p.url).lastPathComponent): " + tr("не удалось записать XMP")) }
            }
        }
        flushEdits()
        let fm = FileManager.default
        var moved = 0
        var movedPairs: [(from: URL, to: URL)] = []
        var reserved: [URL: Set<String>] = [:], taken: [URL: Set<String>] = [:]
        // Suffixed names also skip the other frames of the shoot (IMG_1 → IMG_1-2 while IMG_1-2 is moved too
        // or may be later), as in Exporter.plan.
        let ownBases = Set(photos.map { $0.url.deletingPathExtension().lastPathComponent.lowercased() })
        for p in list {
            let dest = p.url.deletingLastPathComponent().appendingPathComponent(Self.rejectedFolderName, isDirectory: true)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } catch {
                errors.append("\(p.name): \(error.localizedDescription)")
                continue
            }
            // The photo and its companions are one set: one free name for all of them (a frame with the same
            // name may already be there), so the XMP never ends up next to someone else's RAW.
            let files = Exporter.existingCompanions(of: p.url)
            if taken[dest] == nil { taken[dest] = Exporter.takenBases(in: dest) }
            let base = Exporter.freeBase(p.url.deletingPathExtension().lastPathComponent, exts: Exporter.setExtensions(files),
                                         in: dest, reserved: &reserved[dest, default: []], avoid: (taken[dest] ?? []).union(ownBases))
            let (target, errs) = Exporter.transfer(files, of: p.url, base: base, to: dest, move: true)
            errors += errs
            if let target { moved += 1; movedPairs.append((p.url, target)) }
        }
        moveEdits(movedPairs)
        photos.removeAll { !fm.fileExists(atPath: $0.url.path) }
        reindex()
        selection = selection.filter { index[$0] != nil }
        // The Rejected view has done its job: back to all photos instead of an empty screen.
        if filter == .rejected && visible.isEmpty { filter = .all }
        if currentID.map({ index[$0] == nil }) ?? true { focus(visible.first?.id) }
        flash(tr("Перенесено в «_Отклонённые»: \(moved)"))
        showFileErrors(errors)
    }

    /// File errors of a move or save, so "Moved: 0" on a locked card comes with the reason.
    func showFileErrors(_ errors: [String]) {
        guard !errors.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("Не все файлы удалось перенести или скопировать (\(errors.count))")
        let shown = 8
        alert.informativeText = errors.prefix(shown).joined(separator: "\n")
            + (errors.count > shown ? "\n" + tr("…и ещё \(errors.count - shown)") : "")
        alert.runModal()
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
        let items = exportItems(list), all = exportItems(photos)
        let shoot = folder?.lastPathComponent
        // Moved originals take their edits along, so the ones still waiting for the debounce go to disk first.
        if settings.format == .original && settings.move { flushEdits() }
        exportDone = 0
        exportTotal = items.count
        exportTask = Task { [weak self] in
            var ok = 0, skipped = 0
            var errors: [String] = [], moved: [(from: URL, to: URL)] = []
            let jobs = await Task.detached { Exporter.plan(items, to: target, settings, shootName: shoot, shoot: all) }.value
            // RAW → JPEG is heavy (~1–2 s per 50 MP photo), so run 3 in parallel.
            let workers = settings.format == .jpeg ? 3 : 1
            await withTaskGroup(of: Exporter.Outcome.self) { group in
                var it = jobs.makeIterator()
                func add() {
                    guard let job = it.next() else { return }
                    group.addTask { Exporter.export(job, to: target, settings) }
                }
                for _ in 0..<workers { add() }
                while let r = await group.next() {
                    if r.ok { ok += 1 }
                    if r.skipped { skipped += 1 }
                    errors += r.errors
                    if let m = r.moved { moved.append(m) }
                    if Task.isCancelled { group.cancelAll(); break }
                    await MainActor.run { self?.exportDone += 1 }
                    add()
                }
            }
            await MainActor.run {
                self?.finishExport(ok: ok, skipped: skipped, errors: errors, target: target, moved: moved,
                                   removed: settings.format == .original && settings.move)
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func exportItems(_ list: [Photo]) -> [ExportItem] {
        list.enumerated().map { ExportItem(url: $1.url, adj: $1.adj, date: $1.exif.date, index: $0 + 1) }
    }

    private func finishExport(ok: Int, skipped: Int, errors: [String], target: URL, moved: [(from: URL, to: URL)], removed: Bool) {
        exportTotal = 0
        showExport = false
        moveEdits(moved)
        if removed {
            let fm = FileManager.default
            photos.removeAll { !fm.fileExists(atPath: $0.url.path) }
            reindex()
            if currentID.map({ index[$0] == nil }) ?? true { focus(visible.first?.id) }
        }
        flash(tr("Сохранено: \(ok) → \(target.lastPathComponent)") + (skipped > 0 ? " · " + tr("уже были: \(skipped)") : ""))
        showFileErrors(errors)
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
        let items = exportItems(list), all = exportItems(photos)
        let shoot = folder?.lastPathComponent
        Task {
            let out = await Task.detached {
                Exporter.plan(items, to: target, s, shootName: shoot, shoot: all).map { Exporter.export($0, to: target, s) }
            }.value
            let ok = out.filter(\.ok).count, errors = out.flatMap(\.errors)
            // Nothing saved because of errors is not "already there": the alert says what happened.
            if ok > 0 || errors.isEmpty {
                flash(ok > 0 ? tr("→ \(target.lastPathComponent): \(ok) шт.") : tr("Уже есть в \(target.lastPathComponent)"))
            }
            showFileErrors(errors)
        }
    }

    /// The selection, or, if only one is selected, everything shown in the filter.
    func openVisibleInCaptureOne() {
        openInCaptureOne((multiSelected ? targets : visible).map(\.url))
    }

    /// Capture One wherever it is installed and whatever the version is called ("Capture One 23.app",
    /// ~/Applications, Express): found by bundle id, then among the apps that can open the photo.
    private func openInCaptureOne(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let ws = NSWorkspace.shared
        let ids = ["com.captureone.captureone16", "com.captureone.captureone15", "com.captureone.captureone14",
                   "com.captureone.captureone13", "com.phaseone.captureone12", "com.phaseone.captureone11",
                   "com.captureone.captureoneexpress", "com.phaseone.captureoneexpress"]
        let app = ids.lazy.compactMap { ws.urlForApplication(withBundleIdentifier: $0) }.first
            ?? ws.urlsForApplications(toOpen: first).first { u in
                let id = Bundle(url: u)?.bundleIdentifier?.lowercased() ?? ""
                return id.contains("captureone") || u.lastPathComponent.hasPrefix("Capture One")
            }
        guard let app else { flash(tr("Capture One не найден")); return }
        ws.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
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
        openInCaptureOne(targets.map(\.url))
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

/// The one writer for the per-folder stores (index, history, edits): writes run one at a time in the
/// order they were asked for, and a snapshot still waiting is replaced by a newer one for the same file,
/// so an older snapshot can never land on top of a newer one and a burst of saves costs one write.
/// Keys are "<kind>:<folder path>".
final class StoreWriter: @unchecked Sendable {
    static let shared = StoreWriter()
    private let queue = DispatchQueue(label: "ru.kozlov.kadr.stores", qos: .utility)
    private let lock = NSLock()
    private var pending: [(key: String, barrier: Bool, write: @Sendable () -> Void)] = []
    private var running: [String] = []

    /// Queues the write of `key` (a store file); replaces a write of it that hasn't started yet.
    /// A `barrier` (edits following moved files) is never jumped: a snapshot asked for after it is
    /// queued behind it instead of replacing the one before it.
    func save(_ key: String, barrier: Bool = false, _ write: @escaping @Sendable () -> Void) {
        lock.lock()
        let idle = pending.isEmpty
        if !barrier, let i = pending.lastIndex(where: { $0.key == key }), !pending[(i + 1)...].contains(where: \.barrier) {
            pending[i].write = write
        } else {
            pending.append((key, barrier, write))
        }
        lock.unlock()
        // A drain already queued will pick this one up too.
        if idle { queue.async { self.drain() } }
    }

    /// Waits until everything queued so far is on disk (quit, before removing a store file).
    func flush() { queue.sync { drain() } }

    /// Waits only if something queued or being written concerns one of `folders` (or is a barrier, whose
    /// folders aren't known): opening another folder doesn't wait for the old one's big index to be encoded.
    func flush(touching folders: Set<String>) {
        lock.lock()
        let busy = pending.contains { $0.barrier || touches($0.key, folders) } || running.contains { touches($0, folders) }
        lock.unlock()
        if busy { flush() }
    }

    private func touches(_ key: String, _ folders: Set<String>) -> Bool {
        guard let i = key.firstIndex(of: ":") else { return true }
        return folders.contains(String(key[key.index(after: i)...]))
    }

    private func drain() {
        lock.lock()
        let jobs = pending
        pending = []
        running = jobs.map { $0.barrier ? "barrier" : $0.key }   // no folder in it: touches every folder
        lock.unlock()
        for j in jobs { j.write() }
        lock.lock(); running = []; lock.unlock()
    }
}
