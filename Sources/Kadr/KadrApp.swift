import AppKit
import SwiftUI

@main
struct KadrApp: App {
    @State private var library = Library()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Кадр") {
            ContentView()
                .environment(library)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть папку…") { library.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Обработка") {
                Button("Копировать обработку") { library.copyAdjustments() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Вставить обработку") { library.pasteAdjustments() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Сбросить обработку") { library.resetAdjustments() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Menu("Применить стиль") {
                    ForEach(library.styles) { st in
                        Button(st.name) { library.applyStyle(st) }
                    }
                }
                Button("Загрузить LUT (.cube)…") { library.importLUTs() }
                Divider()
                Toggle("Показать до обработки", isOn: $library.showOriginal)
            }
            CommandMenu("Отбор") {
                Button("Перенести отклонённые в «_Отклонённые»") { library.moveRejected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Сохранить в папку…") { library.showExport = true }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Открыть в Capture One") { library.openVisibleInCaptureOne() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Выделить всё") { library.selectAll() }
                Button("Выделить серию") { library.selectSeries() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Показать в Finder") { library.revealCurrent() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Toggle("Переходить дальше после оценки", isOn: $library.autoAdvance)
            }
        }
    }
}

/// Горячие клавиши без модификаторов — как в Photo Mechanic / Capture One.
@MainActor
struct KeyHandler {
    static func handle(_ e: NSEvent, _ lib: Library) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        if cmd, !lib.showExport, e.charactersIgnoringModifiers?.lowercased() == "a" || e.charactersIgnoringModifiers == "ф" {
            lib.selectAll(); return true                           // ⌘A
        }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let shift = e.modifierFlags.contains(.shift)
        if NSApp.keyWindow?.firstResponder is NSTextView || lib.showExport { return false }
        switch e.keyCode {
        case 123: lib.move(-1, extend: shift); return true                       // ←  (⇧ — расширить выделение)
        case 124: lib.move(1, extend: shift); return true                        // →
        case 126: lib.move(lib.loupe ? -1 : -lib.columns, extend: shift); return true // ↑
        case 125: lib.move(lib.loupe ? 1 : lib.columns, extend: shift); return true   // ↓
        case 49: lib.loupe.toggle(); lib.zoom100 = false; return true  // пробел
        case 36: lib.loupe = true; return true                    // Enter
        case 53:                                                   // Esc
            if lib.zoom100 { lib.zoom100 = false } else if lib.loupe { lib.loupe = false } else { lib.clearSelection() }
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
        case "i", "ш": lib.showInfo.toggle()
        case "g", "п": lib.loupe = false
        case "e", "у":
            lib.inspectorTab = lib.inspectorTab == .edit ? .info : .edit
            lib.showInfo = true
        case "\\": lib.showOriginal.toggle()
        case "s", "ы": lib.quickSend()
        default: return false
        }
        return true
    }
}
