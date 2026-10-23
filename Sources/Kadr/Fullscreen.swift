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

    var isActive: Bool { window != nil }

    func toggle(_ lib: Library) { isActive ? exit() : enter(lib) }

    func enter(_ lib: Library) {
        guard window == nil, lib.current != nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let w = FullscreenWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        w.contentView = NSHostingView(rootView: FullscreenView().environment(lib).preferredColorScheme(.dark))
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        w.makeKeyAndOrderFront(nil)
        window = w
        self.lib = lib
        lib.fullscreen = true
    }

    func exit() {
        guard let w = window else { return }
        window = nil
        w.orderOut(nil)
        NSApp.presentationOptions = []
        lib?.fullscreen = false
        NSApp.windows.first { $0.isVisible && $0 !== w && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
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
    @State private var infoToken = 0

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
        // Sheets open on the library window, under this one: step out so the sheet is seen and gets the keys.
        .onChange(of: lib.showShortcuts || lib.showCullSummary || lib.showExport || lib.showImport) { _, on in
            if on { Fullscreen.shared.exit() }
        }
        .onContinuousHover { phase in if case .active = phase { reveal() } }
    }

    /// Show the strip and hide it 2.5 s after the last reason to show it.
    private func reveal() {
        infoToken += 1
        let token = infoToken
        withAnimation(.easeOut(duration: 0.12)) { showInfo = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if infoToken == token { withAnimation(.easeOut(duration: 0.4)) { showInfo = false } }
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
