import AppKit
import SwiftUI

/// Full-screen viewing (F from any mode): the photo alone on a black screen, the same keys as everywhere,
/// a strip of facts at the bottom that appears on every flip and goes away by itself.
/// A borderless window above the menu bar, so the main window and its panels stay exactly as they were.
@MainActor
final class Fullscreen {
    static let shared = Fullscreen()
    private var window: NSWindow?
    private weak var lib: Library?
    /// The window F was pressed in: on exit the keys go back there, not to whichever window
    /// `NSApp.windows` lists first (that could be Settings).
    private weak var main: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { window != nil }

    func toggle(_ lib: Library) { isActive ? exit() : enter(lib) }

    func enter(_ lib: Library) {
        guard window == nil, lib.current != nil else { return }
        // From the menu, a popover may be key. The library window as a last resort: without `main` its getting
        // the keys back (⌘Tab, a Dock click) would read as another window and step out.
        main = KeyHandler.menuWindow(NSApp.keyWindow) ?? NSApp.mainWindow ?? KeyHandler.window
        let screen = main?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let w = FullscreenWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: FullscreenView().environment(lib).preferredColorScheme(.dark).screenMetrics(start: screen))
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        w.makeKeyAndOrderFront(nil)
        window = w
        self.lib = lib
        lib.fullscreen = true
        watchOtherWindows()
    }

    /// `refocus: false` leaves the keys where they are: another window (Settings, an alert, an open panel) has them.
    func exit(refocus: Bool = true) {
        guard let w = window else { return }
        window = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        w.orderOut(nil)
        NSApp.presentationOptions = []
        lib?.fullscreen = false
        if refocus {
            let back = main.flatMap { $0.isVisible ? $0 : nil }
                ?? NSApp.windows.first { $0.isVisible && $0 !== w && !($0 is NSPanel) }
            back?.makeKeyAndOrderFront(nil)
        }
        main = nil
    }

    /// This window sits above the menu bar, so anything else that opens — a sheet on the library, an alert,
    /// an open panel, Settings — would be hidden under it. Step out for all of them, in one place.
    private func watchOtherWindows() {
        let nc = NotificationCenter.default
        // A sheet goes on the library window under this one: step out and hand it the keys.
        observers.append(nc.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Fullscreen.shared.stepOut(refocus: true) }
        })
        // Any other window taking the keys (alerts and panels run modally, so they don't go through a sheet).
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                // Not the library window: AppKit may hand it the keys back on ⌘Tab or a Dock click, and that
                // isn't a reason to leave (nothing new is shown over it).
                guard let w = n.object as? NSWindow, !(w is FullscreenWindow), w !== Fullscreen.shared.main else { return }
                Fullscreen.shared.stepOut(refocus: false)
            }
        })
    }

    /// Deferred: exit() releases the window whose hosting view may be mid-update. Common and modal-panel
    /// modes, so it also runs while an alert's runModal is spinning.
    private func stepOut(refocus: Bool) {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { Fullscreen.shared.exit(refocus: refocus) }
        }
    }
}

/// Borderless windows don't take keys unless they say so.
final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct FullscreenView: View {
    @Environment(Library.self) private var lib
    @State private var showInfo = true
    @State private var hideInfo: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = lib.current {
                ZoomableLoupe(photo: p)
            }
        }
        .overlay(alignment: .bottom) {
            if showInfo, let p = lib.current {
                FullscreenInfo(photo: p).padding(.bottom, 28).transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = lib.toast { Toast(text: t).padding(.bottom, 92) }
        }
        .onAppear { reveal() }
        .onChange(of: lib.currentID) { _, _ in reveal() }
        // Sheets, alerts and other windows: Fullscreen steps out for them itself (watchOtherWindows).
        .onContinuousHover { phase in if case .active = phase { reveal() } }
        .onDisappear { hideInfo?.cancel() }
    }

    /// Show the strip and hide it 2.5 s after the last reason to show it.
    private func reveal() {
        withAnimation(.easeOut(duration: 0.12)) { showInfo = true }
        // One timer, restarted: hover fires on every mouse move, and a sleeping Task per move piled up.
        hideInfo?.cancel()
        hideInfo = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { showInfo = false }
        }
    }
}

/// Name · place in the list · burst position · decision · exposure. One line, and the way out.
struct FullscreenInfo: View {
    let photo: Photo
    @Environment(Library.self) private var lib

    var body: some View {
        let list = lib.visible
        let pos = (list.firstIndex { $0.id == photo.id } ?? 0) + 1
        HStack(spacing: 14) {
            Text(photo.name).font(.callout.weight(.semibold))
            Text(tr("\(pos) из \(list.count)")).monospacedDigit()
            if photo.seriesID != nil {
                let s = lib.series(of: photo)
                let sp = (s.firstIndex { $0.id == photo.id } ?? 0) + 1
                Label(tr("Серия: \(sp) из \(s.count)"), systemImage: "square.stack.3d.up").monospacedDigit()
            }
            if photo.rejected {
                Label(tr("Брак"), systemImage: "xmark.circle.fill").foregroundStyle(Theme.reject)
            } else if photo.rating > 0 {
                Text(String(repeating: "★", count: photo.rating)).foregroundStyle(Theme.star)
            }
            if let l = photo.label { Circle().fill(l.color).frame(width: 10, height: 10) }
            let exp = photo.exif.exposureLine
            if !exp.isEmpty { Text(exp).foregroundStyle(.secondary) }
            Text(tr("F или Esc — выйти")).font(.caption).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .lineLimit(1)
        .floatingBar()
        .allowsHitTesting(false)
    }
}
