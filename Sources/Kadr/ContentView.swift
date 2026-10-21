import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var lib
    @State private var monitor: Any?
    // The sidebar stays unless you hide it yourself: with automatic visibility, a mode switch in a
    // narrow window could collapse it.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var lib = lib
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            // Every mode is a column: banners and bars above and below, the photos in between.
            // Bars never dictate the width (see Chrome.swift), so the window never grows by itself.
            VStack(spacing: 0) {
                CardBanner()
                if lib.folder == nil {
                    EmptyState()
                } else if lib.comparing {
                    CompareView()
                } else if lib.culling {
                    CullView()
                } else {
                    FilterBar()
                    if lib.loupe { LoupeView() } else { GridView() }
                }
                if lib.multiSelected && lib.folder != nil && !lib.comparing { SelectionBar() }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if let t = lib.toast { Toast(text: t).padding(.bottom, toastInset) }
            }
            .inspector(isPresented: $lib.showInfo) {
                Inspector()
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 600)
        .toolbar { toolbar }
        .sheet(isPresented: $lib.showExport) { ExportSheet().environment(lib) }
        .sheet(isPresented: $lib.showImport) { ImportSheet().environment(lib) }
        .sheet(isPresented: $lib.showShortcuts) { ShortcutsView() }
        .navigationTitle(lib.folder?.lastPathComponent ?? I18n.appName)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            lib.open(isDir.boolValue ? u : u.deletingLastPathComponent())
            return true
        }
        .onAppear {
            // A tab bar saved from an earlier launch is restored even with tabbing off: hide it once.
            DispatchQueue.main.async {
                for w in NSApp.windows where w.tabGroup?.isTabBarVisible == true { w.toggleTabBar(nil) }
                for w in NSApp.windows { w.tabbingMode = .disallowed }
            }
            Updater.checkAtLaunch()
            // kadr /path/to/folder — open it right away
            if lib.folder == nil, CommandLine.arguments.count > 1 {
                let u = URL(fileURLWithPath: CommandLine.arguments[1])
                if FileManager.default.fileExists(atPath: u.path) { lib.open(u) }
            }
            if lib.folder == nil, Prefs.reopenLastFolder, let last = lib.browser.recent.first {
                lib.open(last)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { e in
                MainActor.assumeIsolated {
                    if e.type == .leftMouseDown { return ClickModifiers.handle(e, lib) }
                    if e.type == .scrollWheel { return ScrollZoom.handle(e, lib) }
                    return KeyHandler.handle(e, lib) ? nil : e
                }
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    /// Keeps the toast above whatever sits at the bottom: filmstrip and zoom bar, the selection bar.
    private var toastInset: CGFloat {
        var y: CGFloat = lib.comparing ? 60 : lib.loupe || lib.culling ? 150 : 28
        if lib.multiSelected && lib.folder != nil && !lib.comparing { y += Theme.barHeight + 4 }
        return y
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var lib = lib
        ToolbarItem(placement: .navigation) {
            Button { lib.chooseFolder() } label: { Label(tr("Открыть"), systemImage: "folder") }
                .help(tr("Открыть папку (⌘O)"))
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { lib.undo() } label: { Label(tr("Отменить"), systemImage: "arrow.uturn.backward") }
                .disabled(!lib.canUndo)
                .help(lib.undoTitle.map { tr("Отменить: \($0) (⌘Z)") } ?? tr("Нечего отменять"))
            Button { lib.redo() } label: { Label(tr("Вернуть"), systemImage: "arrow.uturn.forward") }
                .disabled(!lib.canRedo)
                .help(lib.redoTitle.map { tr("Вернуть: \($0) (⇧⌘Z)") } ?? tr("Нечего возвращать"))
        }
        ToolbarItem(placement: .principal) {
            ToolsBar()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if lib.folder != nil {
                // Decisions right in the toolbar: easy to find without knowing the keys.
                ControlGroup {
                    Button { lib.keep() } label: { Label(tr("Оставить"), systemImage: "checkmark.circle") }
                        .help(tr("Оставить (P) — ★, если оценки ещё нет"))
                    Button { lib.toggleReject() } label: { Label(tr("Брак"), systemImage: "xmark.circle") }
                        .help(tr("В брак / вернуть (X или Delete)"))
                }
                .disabled(lib.current == nil)
            }
            Button { lib.showShortcuts = true } label: { Label(tr("Клавиши"), systemImage: "keyboard") }
                .help(tr("Шпаргалка по клавишам и интерфейсу (?)"))
            if lib.folder != nil {
                if lib.analyzed < lib.photos.count {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(tr("Индексация \(lib.analyzed)/\(lib.photos.count)"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if lib.aiRunning {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text(tr("AI-анализ \(lib.aiDone)/\(lib.aiTotal)"))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button { lib.stopAI() } label: { Image(systemName: "stop.circle") }
                            .buttonStyle(.borderless).help(tr("Остановить AI-анализ"))
                    }
                }
                Button { lib.showExport = true } label: {
                    Label(tr("Сохранить в папку"), systemImage: "square.and.arrow.down.on.square")
                }
                .help(tr("Сохранить отобранные в папку (⌘S). S — текущий кадр сразу"))
                Menu {
                    Button(tr("Перенести отклонённые в «_Отклонённые»"), systemImage: "trash") { lib.moveRejected() }
                    Button(tr("Сохранить в папку…"), systemImage: "square.and.arrow.down") { lib.showExport = true }
                    Button(tr("Открыть показанные в Capture One"), systemImage: "camera.aperture") { lib.openVisibleInCaptureOne() }
                    Divider()
                    Button(tr("Показать в Finder"), systemImage: "magnifyingglass") { lib.revealCurrent() }
                } label: {
                    Label(tr("Действия"), systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

enum Theme {
    static let canvas = Color(red: 0.085, green: 0.088, blue: 0.095)
    static let cell = Color.white.opacity(0.04)
    static let bar = Color.black.opacity(0.2)        // top and bottom strips
    static let barHeight: CGFloat = 38
    static let barPadding: CGFloat = 14
    static let star = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let reject = Color(red: 0.93, green: 0.33, blue: 0.31)
    static let keep = Color(red: 0.36, green: 0.80, blue: 0.47)
}

// MARK: - Empty state

struct EmptyState: View {
    @Environment(Library.self) private var lib
    @State private var hover = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text(tr("Перетащите папку со съёмкой"))
                    .font(.title2.weight(.semibold))
                Text(tr("RAW Sony, Canon, Nikon, Fuji и JPEG. Оценки сохраняются в XMP — их сразу видит Capture One."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button(tr("Выбрать папку…")) { lib.chooseFolder() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            KeyHints().padding(.top, 18)
        }
        .padding(60)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(.white.opacity(0.12))
        )
        .padding(40)
    }
}

struct KeyHints: View {
    private let hints: [(String, String)] = [
        ("← →", tr("листать")), ("1–5", tr("звёзды")), ("0", tr("снять оценку")), ("X", tr("отклонить")),
        ("6–9", tr("цвет")), (tr("Пробел"), tr("сетка / кадр")), ("Z", tr("зум 100%")), ("I", tr("инфо")),
        ("S", tr("кадр в папку")), ("⌘S", tr("сохранить отобранные")),
        (tr("⌘ / ⇧ + клик"), tr("выделить несколько")), ("⌘A", tr("выделить всё")),
        ("E", tr("обработка")), ("C", tr("сравнить кадры")), ("⌘I", tr("импорт с карты")), ("\\", tr("до / после")),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            ForEach(0..<hints.count / 2, id: \.self) { r in
                GridRow {
                    hint(hints[r * 2])
                    hint(hints[r * 2 + 1])
                }
            }
        }
    }

    private func hint(_ h: (String, String)) -> some View {
        HStack(spacing: 8) {
            Text(h.0)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            Text(h.1).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// ⌘-click and Ctrl-click add a frame to the selection (Ctrl, as Windows users are used to).
/// On a Mac, Ctrl-click usually opens a menu, so we turn it into ⌘-click; the menu is on right-click.
@MainActor
enum ClickModifiers {
    static func handle(_ e: NSEvent, _ lib: Library) -> NSEvent? {
        lib.clickModifiers = e.modifierFlags.intersection([.command, .shift, .control])
        guard e.modifierFlags.contains(.control) else { return e }
        let flags = e.modifierFlags.subtracting(.control).union(.command)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: e.locationInWindow, modifierFlags: flags,
                                  timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                  eventNumber: e.eventNumber, clickCount: e.clickCount, pressure: e.pressure) ?? e
    }
}
