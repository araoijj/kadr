import AppKit
import SwiftUI

@main
struct KadrApp: App {
    @State private var library = Library()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // One window per library: no macOS window tabs (a tab bar turned on once by View → Show Tab Bar
        // stays on and looks like an empty search field under the toolbar).
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        // On quit: the index, history and edits still waiting to be written, and where you stopped in the folder.
        let lib = library
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lib.flushStores(); lib.saveFolderState() }
        }
        KeyHandler.trackKeyWindow(lib)
        // Bundled face mesh: loaded in the background right at launch.
        Task.detached(priority: .utility) { FaceMesh.shared.installBundledIfNeeded() }
        // Denoise results on disk: trimmed once a launch, after the folder has opened, so the photos its edits
        // use are known and kept. Not from a bare build: it shares the cache with the installed app but knows
        // only its own test folder.
        if Bundle.main.bundleURL.pathExtension == "app" { Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            for _ in 0..<60 where lib.loading { try? await Task.sleep(for: .seconds(10)) }
            let keep = lib.photos.filter { $0.adj.aiDenoise > 0 }.map { ($0.url, $0.adj.raw) }
            Task.detached(priority: .background) { Denoiser.trimCache(keeping: keep) }
        } }
    }

    var body: some Scene {
        WindowGroup(I18n.appName) {
            ContentView()
                .environment(library)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
        .commands {
            // ⌘Z / ⇧⌘Z — Kadr's history; in text fields, regular input undo.
            CommandGroup(after: .appInfo) {
                Button(tr("Проверить обновления…")) { Task { await Updater.check(manual: true) } }
            }
            CommandGroup(replacing: .undoRedo) {
                // Not disabled off the photos: ⌘Z must keep reaching text fields in Settings and sheets. There
                // the photo action's name is just dropped, since the item won't undo it.
                Button((library.photosKey ? library.undoTitle : nil).map { tr("Отменить: \($0)") } ?? tr("Отменить")) {
                    if let um = NSApp.keyWindow?.firstResponder as? NSTextView { um.undoManager?.undo() }
                    else if KeyHandler.isPhotosWindow(KeyHandler.menuWindow(NSApp.keyWindow)) { library.undo() }
                }
                .keyboardShortcut(Keys.undo)
                Button((library.photosKey ? library.redoTitle : nil).map { tr("Вернуть: \($0)") } ?? tr("Вернуть")) {
                    if let um = NSApp.keyWindow?.firstResponder as? NSTextView { um.undoManager?.redo() }
                    else if KeyHandler.isPhotosWindow(KeyHandler.menuWindow(NSApp.keyWindow)) { library.redo() }
                }
                .keyboardShortcut(Keys.redo)
                Divider()
                Button(tr("Журнал изменений")) { library.showInfo = true; library.inspectorTab = .history }
                    .keyboardShortcut(Keys.history)
                    .disabled(!library.photosKey)
            }
            // Items that act on the photos are off while Settings, a sheet or an alert has the keys.
            CommandGroup(replacing: .newItem) {
                Group {
                    Button(tr("Открыть папку…")) { library.chooseFolder() }
                        .keyboardShortcut(Keys.open)
                    Button(tr("Импорт с карты памяти…")) { library.showImport = true }
                        .keyboardShortcut(Keys.importCard)
                }
                .disabled(!library.photosKey)
            }
            CommandGroup(after: .toolbar) {
                Group {
                    Button(tr("Увеличить")) { library.zoomIn() }.keyboardShortcut(Keys.zoomIn)
                    Button(tr("Уменьшить")) { library.zoomOut() }.keyboardShortcut(Keys.zoomOut)
                    Button(tr("Вписать в окно")) { library.setZoom(nil) }.keyboardShortcut(Keys.zoomFit)
                    Button(tr("Масштаб 100%")) { library.loupe = true; library.setZoom(1, at: library.loupeCenter) }.keyboardShortcut(Keys.zoom100)
                    Divider()
                    // F itself is KeyHandler's: a bare menu key equivalent would fire while typing "f" in a field.
                    Button(library.fullscreen ? tr("Выйти из полноэкранного просмотра (F)") : tr("Во весь экран (F)")) { Fullscreen.shared.toggle(library) }
                        .disabled(library.current == nil)
                    Divider()
                    // The sidebar's two tabs; ⌘1 itself is zoom 100%, as in other photo apps.
                    Button(tr("Панель: Источники")) { UserDefaults.standard.set(Sidebar.Tab.sources.rawValue, forKey: Sidebar.tabKey) }
                        .keyboardShortcut(Keys.sourcesPanel)
                    Button(tr("Панель: Фильтры")) { UserDefaults.standard.set(Sidebar.Tab.filters.rawValue, forKey: Sidebar.tabKey) }
                        .keyboardShortcut(Keys.filtersPanel)
                    Button(tr("Сбросить все фильтры")) { library.resetFilters() }
                        .keyboardShortcut(Keys.resetFilters)
                        .disabled(library.filter == .all && !library.extraFiltersActive)
                }
                .disabled(!library.photosKey)
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button(tr("Горячие клавиши")) { library.showShortcuts = true }.keyboardShortcut(Keys.shortcuts)
                    .disabled(!library.photosKey)
            }
            CommandMenu(tr("Обработка")) {
                Group {
                    Button(tr("Выровнять экспозицию и баланс по текущему")) { library.matchToCurrent() }
                        .keyboardShortcut(Keys.match)
                    Divider()
                    Button(tr("Копировать обработку")) { library.copyAdjustments() }
                        .keyboardShortcut(Keys.copyEdits)
                    Button(tr("Вставить обработку")) { library.pasteAdjustments() }
                        .keyboardShortcut(Keys.pasteEdits)
                    Button(tr("Сбросить обработку")) { library.resetAdjustments() }
                        .keyboardShortcut(Keys.resetEdits)
                    Divider()
                    Menu(tr("Применить стиль")) {
                        ForEach(library.styles) { st in
                            Button(st.name) { library.applyStyle(st) }
                        }
                    }
                    Button(tr("Загрузить LUT (.cube)…")) { library.importLUTs() }
                    Divider()
                    Toggle(tr("Показать до обработки"), isOn: $library.showOriginal)
                }
                .disabled(!library.photosKey)
            }
            CommandMenu(tr("Отбор")) {
                Group {
                    Toggle(tr("Слой «Отбор»: ярлыки AI, лица, прогресс (O)"), isOn: Binding(get: { library.culling }, set: { _ in library.toggleCullingLayer() }))
                    Button(tr("Итог отбора…")) { library.showCullSummary = true }
                        .disabled(library.folder == nil)
                    Button(tr("Турнир: лучший кадр серии (T)")) { library.startTournament() }
                        .disabled(!library.canCompare)
                }
                .disabled(!library.photosKey)
                Divider()
                // Typed in a text field, ⌘⌫ keeps deleting to the line start; typed over a sheet or in Settings it
                // does nothing. Chosen with the mouse, it moves the rejects unless a sheet is over the library.
                Button(tr("Перенести отклонённые в «_Отклонённые»")) {
                    let w = NSApp.keyWindow, typed = NSApp.currentEvent?.type == .keyDown
                    if typed, let tv = w?.firstResponder as? NSTextView { tv.deleteToBeginningOfLine(nil) }
                    else if KeyHandler.isPhotosWindow(typed ? w : KeyHandler.window) { library.moveRejected() }
                }
                    .keyboardShortcut(Keys.moveRejected)
                Group {
                    Button(tr("Сохранить в папку…")) { library.showExport = true }
                        .keyboardShortcut(Keys.export)
                    Button(tr("Открыть в Capture One")) { library.openVisibleInCaptureOne() }
                        .keyboardShortcut(Keys.captureOne)
                    Divider()
                    Button(tr("Выделить всё")) { library.selectAll() }
                    Button(tr("Выделить серию")) { library.selectSeries() }
                        .keyboardShortcut(Keys.selectSeries)
                    Button(tr("Показать только серию этого кадра")) { if let p = library.current { library.showSeries(of: p) } }
                        .disabled(library.current?.seriesID == nil)
                    Divider()
                    if library.aiRunning {
                        Button(tr("Остановить AI-анализ")) { library.stopAI() }
                    } else {
                        Button(tr("Запустить AI-анализ")) { library.startAI() }
                            .keyboardShortcut(Keys.startAI)
                            .disabled(library.folder == nil || library.analyzed < library.photos.count || library.aiPending == 0)
                    }
                    Button(tr("Записать AI-теги в ключевые слова…")) { library.writeTagKeywords() }
                        .disabled(library.folder == nil || library.aiRunning)
                    AutoCropMenu(lib: library).disabled(library.folder == nil)
                    Button(tr("Пересчитать анализ папки")) { library.reanalyze() }
                    Button(tr("Показать в Finder")) { library.revealCurrent() }
                        .keyboardShortcut(Keys.reveal)
                }
                .disabled(!library.photosKey)
                Toggle(tr("Переходить дальше после оценки"), isOn: $library.autoAdvance)
            }
        }
    }
}

/// Modifier-free hotkeys, as in Photo Mechanic / Capture One.
@MainActor
struct KeyHandler {
    /// The library window (set by WindowTweaks). The local monitor sees keys of every window in the app.
    static weak var window: NSWindow?

    /// Only keys meant for the photos: the library window (or full screen) with no sheet, alert or modal
    /// panel over it and no text being typed. Settings, sheets and popovers get their keys as usual.
    private static func accepts(_ e: NSEvent) -> Bool {
        guard let w = e.window, isPhotosWindow(w) else { return false }
        let r = w.firstResponder
        return !(r is NSTextView || (r as? NSTextField)?.isEditable == true)
    }

    /// The library window (or full screen) with no sheet, alert or modal panel over it.
    static func isPhotosWindow(_ w: NSWindow?) -> Bool {
        NSApp.modalWindow == nil && isPhotos(w)
    }

    /// Same, minus the modal check: an alert's runModal can still be winding down when the window regains key.
    private static func isPhotos(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        // Full screen counts only while the library has no sheet: one opened from there goes behind it.
        return (w is FullscreenWindow || w === window) && window?.attachedSheet == nil
    }

    /// The window a ⌘ menu item acts for: a popover over the library (thumbnail size, analysis progress) is
    /// a key window of its own, and the items must keep working while one is open. Bare keys don't use this.
    static func menuWindow(_ w: NSWindow?) -> NSWindow? {
        guard let w, w.className.contains("Popover"), let parent = w.parent else { return w }
        return parent
    }

    /// Keeps `lib.photosKey` current, so the ⌘ menu items that act on the photos are off while Settings,
    /// a sheet or an alert has the keys (a sheet's window becomes key, the library's comes back after it).
    /// No key window at all (the library closed with ⌘W) leaves them on: ⌘O must still open a folder.
    static func trackKeyWindow(_ lib: Library) {
        let update = { DispatchQueue.main.async { MainActor.assumeIsolated {
            lib.photosKey = NSApp.keyWindow.map { isPhotos(menuWindow($0)) } ?? true
        } } }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in update() }
        }
    }

    static func handle(_ e: NSEvent, _ lib: Library) -> Bool {
        guard accepts(e), !lib.showExport, !lib.showImport else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "a" || e.charactersIgnoringModifiers == "ф" {
            lib.selectAll(); return true                           // ⌘A (⇧⌘A, ⌥⌘A are menu items)
        }
        if !mods.intersection([.command, .control, .option]).isEmpty { return false }
        let shift = mods.contains(.shift)
        if lib.fullscreen {
            // The same keys as everywhere; only the way out and "next" differ.
            switch e.keyCode {
            case 53: Fullscreen.shared.exit(); return true                        // Esc
            case 49: lib.move(shift ? -1 : 1); return true                         // space: next (⇧ — back)
            default: break
            }
            if ["f", "а"].contains(e.charactersIgnoringModifiers?.lowercased() ?? "") { Fullscreen.shared.exit(); return true }
        }
        if lib.cropMode {
            switch e.keyCode {
            case 36, 76: lib.finishCrop(); return true      // Enter: done
            case 53: lib.cancelCrop(); return true          // Esc: cancel
            case 124 where !lib.autoCropQueue.isEmpty: lib.cancelCrop(); return true   // →: skip this suggestion
            case 123...126: return true                     // other arrows: the editor stays on its photo
            default: break
            }
            if ["a", "ф"].contains(e.charactersIgnoringModifiers?.lowercased() ?? "") { lib.autoCropCurrent(); return true }   // A: auto crop
            if ["r", "к"].contains(e.charactersIgnoringModifiers?.lowercased() ?? "") { lib.finishCrop(); return true }
        }
        if e.charactersIgnoringModifiers == "?" || (shift && e.keyCode == 44) {   // ? — Shift + the "/" key on any layout
            lib.showShortcuts = true; return true
        }
        if lib.removeMode {
            switch e.keyCode {
            case 36, 76: lib.applyRemove(); return true                                          // Enter: remove
            case 53: if lib.removePoints.isEmpty { lib.finishRemove() } else { lib.clearRemoveSelection() }; return true   // Esc
            default: break
            }
        }
        if lib.tournamentActive {
            switch e.keyCode {
            case 123: lib.pickTournament(left: true); return true    // ← left is better
            case 124: lib.pickTournament(left: false); return true   // → right is better
            case 53: lib.cancelTournament(); return true
            default: break
            }
        }
        if lib.comparing {
            switch e.keyCode {
            case 123, 126: lib.compareMove(-1); return true
            case 124, 125: lib.compareMove(1); return true
            case 53: lib.stopCompare(); return true
            case 49 where !lib.tournamentActive: lib.toggleCompareKeep(); return true          // space: mark to keep
            case 36 where !lib.tournamentActive, 76 where !lib.tournamentActive: lib.rejectOthersInCompare(); return true  // Enter: keep marked
            default: break
            }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "p" where !lib.tournamentActive, "з" where !lib.tournamentActive: lib.toggleCompareKeep(); return true
            case "x" where !lib.tournamentActive, "ч" where !lib.tournamentActive: lib.toggleCompareReject(); return true
            case "z", "я": lib.toggleCompareZoom(); return true
            case "c", "с": lib.stopCompare(); return true
            case "=", "+": lib.compareTileStep(1); return true     // bigger frames
            case "-": lib.compareTileStep(-1); return true
            default: break
            }
        }
        switch e.keyCode {
        case 123: lib.move(-1, extend: shift); return true                       // ←  (⇧ extends the selection)
        case 124: lib.move(1, extend: shift); return true                        // →
        case 126: lib.loupe ? lib.move(-1, extend: shift) : lib.moveRow(-1, extend: shift); return true   // ↑
        case 125: lib.loupe ? lib.move(1, extend: shift) : lib.moveRow(1, extend: shift); return true     // ↓
        case 49:                                                   // space: grid ↔ loupe, in every mode
            lib.loupe.toggle(); lib.zoom100 = false
            return true
        case 36: lib.loupe = true; return true                    // Enter
        case 53:                                                   // Esc
            if lib.zoom100 { lib.zoom100 = false }
            else if lib.inSeries { lib.leaveSeries(); lib.flash(tr("Назад ко всем кадрам")) }   // out of a burst first, the view stays
            else if lib.loupe { lib.loupe = false } else { lib.clearSelection() }   // the culling layer stays
            return true
        case 51, 117: lib.toggleReject(); return true              // Backspace / Delete
        default: break
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1 else { return false }
        if let n = Int(ch) {
            if n <= 5 { lib.setRating(n) } else if let l = ColorLabel.forKey(n) { lib.toggleLabel(l) }
            return true
        }
        switch ch {
        case "x", "ч": lib.toggleReject()
        case "z", "я": if lib.currentID != nil { lib.loupe = true; lib.zoom100.toggle() }
        case "=", "+": lib.zoomIn()
        case "-": lib.zoomOut()
        case "i", "ш": lib.showInfo.toggle()
        case "g", "п": lib.loupe = false
        case "e", "у":
            lib.inspectorTab = lib.inspectorTab == .edit ? .info : .edit
            lib.showInfo = true
        case "\\": lib.showOriginal.toggle()
        case "s", "ы": lib.quickSend()
        case "c", "с": lib.startCompare()
        case "p", "з": lib.keep()
        case "o", "щ": lib.toggleCullingLayer()
        case "t", "е": lib.startTournament()
        case "u", "г": lib.unflag()
        case "h", "р":
            lib.hideRejected.toggle()
            lib.flash(lib.hideRejected ? tr("Брак скрыт (H — показать)") : tr("Брак снова виден"))
        case "y", "н": lib.splitCompare.toggle(); if lib.splitCompare { lib.loupe = true }
        case "r", "к": lib.startCrop()
        case "f", "а": if lib.current != nil { Fullscreen.shared.toggle(lib) }
        default: return false
        }
        return true
    }
}
