import AppKit
import SwiftUI

/// A hover card for the toolbar: what the tool is for, in one line, with its key. The system tooltip fits
/// a name and comes late; this one explains the purpose and shows up in half a second, in the app's look.
struct Tip {
    var title: String
    var key: String?
    var icon: String
    var text: String
}

/// One floating panel for every tip: shown under the hovered control, never takes the focus or the mouse.
@MainActor
final class TipPanel {
    static let shared = TipPanel()
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    /// The control whose card is on screen, so a live card can be refreshed without re-hovering.
    private weak var shownAnchor: NSView?

    func schedule(_ tip: Tip, under anchor: NSView) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            MainActor.assumeIsolated { self.show(tip, under: anchor) }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        shownAnchor = nil
        panel?.orderOut(nil)
    }

    /// New text for the card already shown under `anchor` (live counts); nothing if it isn't shown.
    func refresh(_ tip: Tip, under anchor: NSView) {
        guard shownAnchor === anchor, panel?.isVisible == true else { return }
        show(tip, under: anchor)
    }

    private func show(_ tip: Tip, under anchor: NSView) {
        guard let win = anchor.window, win.isVisible else { return }
        let r = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let host = NSHostingView(rootView: TipCard(tip: tip))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = true
            p.isReleasedWhenClosed = false
            return p
        }()
        p.contentView = host
        // Centered under the control, kept inside the screen.
        let screen = (win.screen ?? NSScreen.main)?.visibleFrame ?? r
        var x = r.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        p.setFrame(NSRect(x: x, y: r.minY - size.height - 6, width: size.width, height: size.height), display: true)
        p.orderFront(nil)
        panel = p
        shownAnchor = anchor
    }
}

struct TipCard: View {
    let tip: Tip

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tip.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tip.title).font(.callout.weight(.semibold))
                    if let k = tip.key {
                        Text(k)
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(tip.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 250, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
        .preferredColorScheme(.dark)
    }
}

/// Finds the AppKit view behind a SwiftUI control, so the card can be placed under it on screen.
private struct AnchorView: NSViewRepresentable {
    let found: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { found(v) }; return v }
    func updateNSView(_ v: NSView, context: Context) {}
}

private struct TipModifier: ViewModifier {
    let tip: Tip
    let active: Bool
    @State private var anchor: NSView?
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .background(AnchorView { anchor = $0 })
            .onHover { inside in
                self.inside = inside
                if inside, active, let anchor { TipPanel.shared.schedule(tip, under: anchor) } else { TipPanel.shared.hide() }
            }
            .simultaneousGesture(TapGesture().onEnded { TipPanel.shared.hide() })
            // The card follows live text (progress counts) and goes when the control stops being active.
            .onChange(of: tip.text) { if inside, let anchor { TipPanel.shared.refresh(tip, under: anchor) } }
            .onChange(of: active) { if inside, !active { TipPanel.shared.hide() } }
    }
}

extension View {
    /// A hover card instead of `.help`: title, key and one line on what the control is for.
    /// `active: false` keeps the card away, e.g. while the control is hidden.
    func tip(_ title: String, key: String? = nil, icon: String, _ text: String, active: Bool = true) -> some View {
        modifier(TipModifier(tip: Tip(title: title, key: key, icon: icon, text: text), active: active))
    }
}
