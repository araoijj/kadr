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
        // On quit: unsaved (debounced) edits and where you stopped in the folder.
        let lib = library
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lib.flushEdits(); lib.saveFolderState() }
        }
        // Bundled face mesh: loaded in the background right at launch.
        Task.detached(priority: .utility) { FaceMesh.shared.installBundledIfNeeded() }
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
                Button(library.undoTitle.map { tr("Отменить: \($0)") } ?? tr("Отменить")) {
                    if let um = NSApp.keyWindow?.firstResponder as? NSTextView { um.undoManager?.undo() } else { library.undo() }
                }
                .keyboardShortcut("z")
                Button(library.redoTitle.map { tr("Вернуть: \($0)") } ?? tr("Вернуть")) {
                    if let um = NSApp.keyWindow?.firstResponder as? NSTextView { um.undoManager?.redo() } else { library.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button(tr("Журнал изменений")) { library.showInfo = true; library.inspectorTab = .history }
                    .keyboardShortcut("y")
            }
            CommandGroup(replacing: .newItem) {
                Button(tr("Открыть папку…")) { library.chooseFolder() }
                    .keyboardShortcut("o")
                Button(tr("Импорт с карты памяти…")) { library.showImport = true }
                    .keyboardShortcut("i")
            }
            CommandGroup(after: .toolbar) {
                Button(tr("Увеличить")) { library.zoomIn() }.keyboardShortcut("=")
                Button(tr("Уменьшить")) { library.zoomOut() }.keyboardShortcut("-")
                Button(tr("Вписать в окно")) { library.setZoom(nil) }.keyboardShortcut("0")
                Button(tr("Масштаб 100%")) { library.loupe = true; library.setZoom(1, at: library.loupeCenter) }.keyboardShortcut("1")
                Divider()
                Button(library.fullscreen ? tr("Выйти из полноэкранного просмотра") : tr("Во весь экран")) { Fullscreen.shared.toggle(library) }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled(library.current == nil)
                Divider()
                // The sidebar's two tabs; ⌘1 itself is zoom 100%, as in other photo apps.
                Button(tr("Панель: Источники")) { UserDefaults.standard.set(Sidebar.Tab.sources.rawValue, forKey: Sidebar.tabKey) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button(tr("Панель: Фильтры")) { UserDefaults.standard.set(Sidebar.Tab.filters.rawValue, forKey: Sidebar.tabKey) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button(tr("Сбросить все фильтры")) { library.resetFilters() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(library.filter == .all && !library.extraFiltersActive)
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button(tr("Горячие клавиши")) { library.showShortcuts = true }.keyboardShortcut("/", modifiers: .command)
            }
            CommandMenu(tr("Обработка")) {
                Button(tr("Выровнять экспозицию и баланс по текущему")) { library.matchToCurrent() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
                Button(tr("Копировать обработку")) { library.copyAdjustments() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(tr("Вставить обработку")) { library.pasteAdjustments() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button(tr("Сбросить обработку")) { library.resetAdjustments() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
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
            CommandMenu(tr("Отбор")) {
                Toggle(tr("Слой «Отбор»: ярлыки AI, лица, прогресс (O)"), isOn: $library.culling)
                Button(tr("Итог отбора…")) { library.showCullSummary = true }
                    .disabled(library.folder == nil)
                Divider()
                Button(tr("Перенести отклонённые в «_Отклонённые»")) { library.moveRejected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button(tr("Сохранить в папку…")) { library.showExport = true }
                    .keyboardShortcut("s", modifiers: .command)
                Button(tr("Открыть в Capture One")) { library.openVisibleInCaptureOne() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button(tr("Выделить всё")) { library.selectAll() }
                Button(tr("Выделить серию")) { library.selectSeries() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(tr("Показать только серию этого кадра")) { if let p = library.current { library.showSeries(of: p) } }
                    .disabled(library.current?.seriesID == nil)
                Divider()
                if library.aiRunning {
                    Button(tr("Остановить AI-анализ")) { library.stopAI() }
                } else {
                    Button(tr("Запустить AI-анализ")) { library.startAI() }
                        .keyboardShortcut("a", modifiers: [.command, .option])
                        .disabled(library.folder == nil || library.analyzed < library.photos.count || library.aiPending == 0)
                }
                Button(tr("Записать AI-теги в ключевые слова…")) { library.writeTagKeywords() }
                    .disabled(library.folder == nil || library.aiRunning)
                AutoCropMenu(lib: library).disabled(library.folder == nil)
                Button(tr("Пересчитать анализ папки")) { library.reanalyze() }
                Button(tr("Показать в Finder")) { library.revealCurrent() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Toggle(tr("Переходить дальше после оценки"), isOn: $library.autoAdvance)
            }
        }
    }
}

/// Modifier-free hotkeys, as in Photo Mechanic / Capture One.
@MainActor
struct KeyHandler {
    static func handle(_ e: NSEvent, _ lib: Library) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        if cmd, !lib.showExport, e.charactersIgnoringModifiers?.lowercased() == "a" || e.charactersIgnoringModifiers == "ф" {
            lib.selectAll(); return true                           // ⌘A
        }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let shift = e.modifierFlags.contains(.shift)
        if NSApp.keyWindow?.firstResponder is NSTextView || lib.showExport || lib.showImport { return false }
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
            default: break
            }
            if ["a", "ф"].contains(e.charactersIgnoringModifiers?.lowercased() ?? "") { lib.autoCropCurrent(); return true }   // A: auto crop
            if ["r", "к"].contains(e.charactersIgnoringModifiers?.lowercased() ?? "") { lib.finishCrop(); return true }
        }
        if e.charactersIgnoringModifiers == "?" || (shift && e.keyCode == 44) {   // ? — Shift + the "/" key on any layout
            lib.showShortcuts = true; return true
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
        case 126: lib.move(lib.loupe ? -1 : -lib.columns, extend: shift); return true // ↑
        case 125: lib.move(lib.loupe ? 1 : lib.columns, extend: shift); return true   // ↓
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
        case "o", "щ": lib.culling.toggle()
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
