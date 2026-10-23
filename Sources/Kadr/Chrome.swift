import AppKit
import SwiftUI

/// Shared chrome, so every mode is built from the same parts:
/// - `Bar` — a top or bottom strip (filters, culling, compare, selection). It takes the width it is given
///   instead of asking for its ideal width: a wide bar would otherwise force the window to grow and push
///   the sidebar out. Inside, a `ViewThatFits` picks the variant that fits.
/// - `.floatingBar()` — the capsule for controls that float over the photo (zoom, crop, toast, card banner).
struct Bar<Content: View>: View {
    enum Edge { case top, bottom }
    var edge: Edge = .top
    var tint: Color? = nil
    @ViewBuilder let content: Content
    @State private var height: CGFloat = Theme.barHeight

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .leading) {
                content
                    .padding(.horizontal, Theme.barPadding)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .clipped()
            .background(tint ?? Theme.bar)
            .overlay(alignment: edge == .top ? .bottom : .top) { Divider() }
    }
}

struct FloatingBar<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.1)))
    }
}

extension View {
    /// Capsule for a one-row floating control; pass a rounded rectangle for several rows.
    func floatingBar() -> some View { modifier(FloatingBar(shape: Capsule())) }
    func floatingBar<S: InsettableShape>(_ shape: S) -> some View { modifier(FloatingBar(shape: shape)) }
}

/// One-line message over the photo; disappears by itself.
struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .floatingBar()
            .frame(maxWidth: 520)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

/// Settings that live on the NSWindow, applied the moment the view lands in one (NSApp.windows is still
/// empty in onAppear). One window per library: no macOS window tabs — a tab bar restored from an earlier
/// launch would sit under the toolbar as a wide pill with a useless "+" (new empty window).
struct WindowTweaks: NSViewRepresentable {
    func makeNSView(context: Context) -> TweakView { TweakView() }
    func updateNSView(_ v: TweakView, context: Context) {}

    final class TweakView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            KeyHandler.window = w
            Self.apply(w)
            // State restoration can bring the tab bar back a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak w] in w.map(Self.apply) }
        }

        static func apply(_ w: NSWindow) {
            w.tabbingMode = .disallowed
            if w.tabGroup?.isTabBarVisible == true { w.toggleTabBar(nil) }
        }
    }
}
