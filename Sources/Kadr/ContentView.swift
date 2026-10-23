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
                // Max 400, not 420: in the 1000 pt minimum window with the sidebar at its 300 this still leaves
                // the photos column 300 pt instead of 280, less for the views there to overflow.
                Inspector()
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 400)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbar }
        .sheet(isPresented: $lib.showExport) { ExportSheet().environment(lib) }
        .sheet(isPresented: $lib.showImport) { ImportSheet().environment(lib) }
        .sheet(isPresented: $lib.showShortcuts) { ShortcutsView() }
        .sheet(isPresented: $lib.showCullSummary) { CullSummary().environment(lib) }
        .navigationTitle(lib.folder?.lastPathComponent ?? I18n.appName)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            lib.scan(isDir.boolValue ? u : u.deletingLastPathComponent())
            return true
        }
        .background(WindowTweaks())
        .onAppear {
            Updater.checkAtLaunch()
            // kadr /path/to/folder — open it right away
            if lib.folder == nil, CommandLine.arguments.count > 1 {
                let u = URL(fileURLWithPath: CommandLine.arguments[1])
                if FileManager.default.fileExists(atPath: u.path) { lib.scan(u) }
            }
            if lib.folder == nil, Prefs.reopenLastFolder, !lib.browser.shoots.isEmpty {
                // Looked for off the main thread: a stat on a dropped network volume can hang for long.
                let shoots = lib.browser.shoots
                Task {
                    let last = await Task.detached(priority: .userInitiated) { shoots.first(where: FolderBrowser.reachable) }.value
                    if lib.folder == nil, let last { lib.open(last) }
                }
            }
            // onAppear can come again (window restored); one monitor is enough.
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { e in
                // Local monitors run on the main thread, so the event never leaves it; NSEvent isn't Sendable,
                // hence handed out through an unchecked local rather than as assumeIsolated's result.
                nonisolated(unsafe) var out: NSEvent?
                MainActor.assumeIsolated {
                    if e.type == .leftMouseDown { out = ClickModifiers.handle(e, lib) }
                    else if e.type == .scrollWheel { out = ScrollZoom.handle(e, lib) }
                    else { out = KeyHandler.handle(e, lib) ? nil : e }
                }
                return out
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }

    /// Keeps the toast above whatever sits at the bottom: filmstrip and zoom bar, the selection bar.
    private var toastInset: CGFloat {
        var y: CGFloat = lib.comparing ? 60 : lib.loupe ? 150 : 28
        if lib.multiSelected && lib.folder != nil && !lib.comparing { y += Theme.barHeight + 4 }
        return y
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var lib = lib
        ToolbarItem(placement: .navigation) {
            Button { lib.chooseFolder() } label: { Label(tr("Открыть"), systemImage: "folder") }
                .tip(tr("Открыть папку"), key: "⌘O", icon: "folder", tr("Папка со съёмкой: она появится в «Съёмках» и проиндексируется."))
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { lib.undo() } label: { Label(tr("Отменить"), systemImage: "arrow.uturn.backward") }
                .disabled(!lib.canUndo)
                .tip(tr("Отменить"), key: "⌘Z", icon: "arrow.uturn.backward",
                     lib.undoTitle.map { tr("Вернуть как было: \($0).") } ?? tr("Нечего отменять: оценки и обработка ещё не менялись."))
            Button { lib.redo() } label: { Label(tr("Вернуть"), systemImage: "arrow.uturn.forward") }
                .disabled(!lib.canRedo)
                .tip(tr("Вернуть"), key: "⇧⌘Z", icon: "arrow.uturn.forward",
                     lib.redoTitle.map { tr("Повторить отменённое: \($0).") } ?? tr("Нечего возвращать."))
        }
        ToolbarItem(placement: .principal) {
            ToolsBar()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if lib.folder != nil {
                // Decisions right in the toolbar: easy to find without knowing the keys.
                ControlGroup {
                    Button { lib.keep() } label: { Label(tr("Оставить"), systemImage: "checkmark.circle") }
                        .tip(tr("Оставить"), key: "P", icon: "checkmark.circle", tr("Кадр идёт в отобранные: ★, если оценки ещё нет. Следующий откроется сам."))
                    Button { lib.toggleReject() } label: { Label(tr("Брак"), systemImage: "xmark.circle") }
                        .tip(tr("Брак"), key: "X", icon: "xmark.circle", tr("Отклонить кадр или вернуть из брака. Файл остаётся на месте."))
                }
                .disabled(lib.current == nil)
            }
            Button { lib.showShortcuts = true } label: { Label(tr("Клавиши"), systemImage: "keyboard") }
                .tip(tr("Клавиши"), key: "?", icon: "keyboard", tr("Шпаргалка: все горячие клавиши на одном экране."))
            if lib.folder != nil {
                // One fixed-width ring for indexing, AI and denoise: captions with growing numbers made the
                // toolbar wider mid-work, which re-lays the split view (see EmptyState).
                BackgroundJobs()
                Button { lib.showExport = true } label: {
                    Label(tr("Сохранить в папку"), systemImage: "square.and.arrow.down.on.square")
                }
                .tip(tr("Сохранить в папку"), key: "⌘S", icon: "square.and.arrow.down.on.square", tr("Скопировать отобранные кадры в другую папку, RAW или JPEG. S — текущий кадр сразу."))
                Menu {
                    Button(tr("Перенести отклонённые в «_Отклонённые»"), systemImage: "trash") { lib.moveRejected() }
                    Button(tr("Сохранить в папку…"), systemImage: "square.and.arrow.down") { lib.showExport = true }
                    Button(tr("Открыть показанные в Capture One"), systemImage: "camera.aperture") { lib.openVisibleInCaptureOne() }
                    Divider()
                    Button(tr("Показать в Finder"), systemImage: "magnifyingglass") { lib.revealCurrent() }
                } label: {
                    Label(tr("Действия"), systemImage: "ellipsis.circle")
                }
                .tip(tr("Действия"), icon: "ellipsis.circle", tr("Перенести брак в подпапку, открыть в Capture One, показать в Finder."))
            }
        }
    }
}

/// Background work as one ring of constant size, present while a folder is open so the toolbar never
/// changes width; the numbers are in the hover card, the stop buttons in the popover.
struct BackgroundJobs: View {
    @Environment(Library.self) private var lib
    @State private var open = false

    private struct Job { let icon: String, title: String, done: Int, total: Int, stop: (() -> Void)?; var stopText = "" }

    private var jobs: [Job] {
        var out: [Job] = []
        if lib.analyzed < lib.photos.count {
            out.append(Job(icon: "photo.stack", title: tr("Индексация \(lib.analyzed)/\(lib.photos.count)"),
                           done: lib.analyzed, total: lib.photos.count, stop: nil))
        } else if lib.aiRunning {
            out.append(Job(icon: "sparkles", title: tr("AI-анализ \(lib.aiDone)/\(lib.aiTotal)"),
                           done: lib.aiDone, total: lib.aiTotal, stop: { lib.stopAI() },
                           stopText: tr("Посчитанное останется, остальное досчитается потом.")))
        }
        if lib.denoiseRunning {
            out.append(Job(icon: "wand.and.stars", title: tr("Шумоподавление \(lib.denoiseDone + 1)/\(lib.denoiseTotal)"),
                           done: lib.denoiseDone, total: lib.denoiseTotal, stop: { lib.stopDenoise() },
                           stopText: tr("Готовые кадры останутся обработанными.")))
        }
        return out
    }

    var body: some View {
        let jobs = jobs
        let first = jobs.first
        Button { open.toggle() } label: {
            ZStack {
                if let first {
                    ProgressView(value: Double(first.done), total: Double(max(first.total, 1)))
                        .progressViewStyle(.circular).controlSize(.small)
                    Image(systemName: first.icon).font(.system(size: 7, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(first == nil ? 0 : 1)
        .allowsHitTesting(first != nil)
        .accessibilityHidden(first == nil)
        // Idle, the ring is hidden but keeps its place: no card over the empty spot.
        .tip(tr("Фоновые задачи"), icon: first?.icon ?? "clock",
             jobs.map(\.title).joined(separator: "\n") + "\n" + tr("Нажмите — подробности и остановка."),
             active: first != nil)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(jobs, id: \.icon) { j in
                    HStack(spacing: 8) {
                        Image(systemName: j.icon).foregroundStyle(Color.accentColor).frame(width: 16)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(j.title).font(.callout).monospacedDigit()
                            ProgressView(value: Double(j.done), total: Double(max(j.total, 1))).frame(width: 180)
                        }
                        if let stop = j.stop {
                            Button(tr("Стоп")) { stop() }.controlSize(.small).help(j.stopText)
                        }
                    }
                }
            }
            .padding(14)
        }
        .onChange(of: first == nil) { _, idle in if idle { open = false } }
    }
}

/// Design tokens. Parts built from them live in Chrome.swift:
/// - `.overlayCapsule()` / `.overlayCircle()` — every label, badge and small mark over a photo.
/// - Segmented choices come in two looks: `.tabs()` switches what a panel shows (system segmented,
///   neutral selection); `ChoiceSegments` sets a value of the photo or the export (drawn here, accent
///   selection) — so a tab never looks like a setting, on any macOS version.
/// - `RadioRow` — one option of a single choice listed in rows; `BipolarSlider` — a slider with 0 in the middle.
enum Theme {
    static let canvas = Color(red: 0.085, green: 0.088, blue: 0.095)
    // A preview's tile lies on the canvas, which is dark in any theme: a white wash, or a light theme
    // would draw black tiles on black.
    static let cell = wash(0.04, contrast: 0.10, onCanvas: true)
    // Fills on the window's own surfaces: a wash of the label colour (white on dark, black on light) that
    // gets stronger with Increase Contrast. A bare white.opacity only works on the dark theme.
    static let fill = wash(0.05, contrast: 0.12)       // a box of grouped content: destination, summary
    static let control = wash(0.06, contrast: 0.16)    // an option that is off: chip, radio row
    static let selected = Color.accentColor.opacity(0.22)   // the option that is on
    static let track = wash(0.10, contrast: 0.30)      // a track drawn by hand: BipolarSlider, gauges
    static let key = wash(0.09, contrast: 0.25)        // a keycap, a small inline button, a placeholder
    // Over a photo the frame decides the background, so these stay dark in any theme. Solid enough for a
    // bright frame: a see-through capsule hid the burst badge (Liquid Glass makes everything lighter).
    static let overlay = Color.black.opacity(0.8)
    static let overlayStrong = Color.black.opacity(0.9)    // hover, or a mark that is set
    static let overlayEdge = Color.white.opacity(0.18)
    static let overlayEdgeStrong = Color.white.opacity(0.5)
    static let tabTint = Color.gray                        // selection of a tab switcher (`.tabs()`)
    static let bar = Color.black.opacity(0.2)        // top and bottom strips
    static let barHeight: CGFloat = 38
    static let barPadding: CGFloat = 14
    static let star = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let reject = Color(red: 0.93, green: 0.33, blue: 0.31)
    static let keep = Color(red: 0.36, green: 0.80, blue: 0.47)

    /// The label colour at `alpha`, resolved per appearance, so a fill follows the theme and the
    /// Increase Contrast setting instead of assuming a dark window.
    static func wash(_ alpha: CGFloat, contrast: CGFloat, onCanvas: Bool = false) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let name = a.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            // No match (a vibrant or other custom appearance): judged by its name, never left light by default.
            let dark = onCanvas || (name.map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua }
                ?? a.name.rawValue.localizedCaseInsensitiveContains("dark"))
            let high = name == .accessibilityHighContrastDarkAqua || name == .accessibilityHighContrastAqua
            return (dark ? NSColor.white : .black).withAlphaComponent(high ? contrast : alpha)
        })
    }
}

// MARK: - Empty state

struct EmptyState: View {
    @Environment(Library.self) private var lib
    @State private var hover = false

    // Never dictates the column's size: with the sidebar and the inspector open, a 1000-pt window leaves
    // the photos under 400 pt, and a min size above that re-lays the split view round and round
    // (macOS 27 aborts the app at launch). Without room, the key hints go first.
    var body: some View {
        ViewThatFits {
            card(hints: true)
            card(hints: false)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func card(hints: Bool) -> some View {
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
            if hints { KeyHints().padding(.top, 18) }
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
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.key))
            Text(h.1).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// ⌘-click and Ctrl-click add a frame to the selection (Ctrl, as Windows users are used to).
/// On a Mac, Ctrl-click usually opens a menu, so over the grid and the filmstrip we turn it into ⌘-click
/// (the menu is on right-click there); everywhere else Ctrl-click keeps opening context menus.
@MainActor
enum ClickModifiers {
    static func handle(_ e: NSEvent, _ lib: Library) -> NSEvent? {
        lib.clickModifiers = e.modifierFlags.intersection([.command, .shift, .control])
        guard e.modifierFlags.contains(.control), ClickAnchor.contains(e) else { return e }
        let flags = e.modifierFlags.subtracting(.control).union(.command)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: e.locationInWindow, modifierFlags: flags,
                                  timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                  eventNumber: e.eventNumber, clickCount: e.clickCount, pressure: e.pressure) ?? e
    }
}

/// Invisible marker behind the grid and the filmstrip: tells ClickModifiers the click landed on photos.
struct ClickAnchor: NSViewRepresentable {
    @MainActor private static let views = NSHashTable<NSView>.weakObjects()

    func makeNSView(context: Context) -> NSView {
        let v = LoupeAnchor.PassthroughView()
        Self.views.add(v)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}

    @MainActor static func contains(_ e: NSEvent) -> Bool {
        views.allObjects.contains { v in
            v.window != nil && v.window == e.window && !v.isHiddenOrHasHiddenAncestor
                && v.bounds.contains(v.convert(e.locationInWindow, from: nil))
        }
    }
}
