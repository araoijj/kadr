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

    /// At least 22×22 pt to click for a small glyph or dot, whose drawn size stays as it is.
    func hitTarget() -> some View { frame(minWidth: 22, minHeight: 22).contentShape(Rectangle()) }

    /// A menu whose label is drawn here (chevron included). `.borderlessButton` on macOS 26+ redraws the
    /// label: colours and layout are lost and a glass capsule appears. A plain button keeps it as written
    /// on every version.
    func plainMenu() -> some View { menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden) }
}

/// The ⌄ after a menu's label, for menus styled with `plainMenu()` (their own indicator is hidden).
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
    }
}

/// The one look for labels, badges and small marks over a photo (see Theme). `edge` adds the thin rim
/// of things you click; `strong` is hover or a mark that is set.
struct OverlayChip<S: InsettableShape>: ViewModifier {
    let shape: S
    var edge = false
    var strong = false

    func body(content: Content) -> some View {
        content
            .background(strong ? Theme.overlayStrong : Theme.overlay, in: shape)
            .overlay { if edge { shape.strokeBorder(strong ? Theme.overlayEdgeStrong : Theme.overlayEdge) } }
    }
}

extension View {
    func overlayCapsule(edge: Bool = false, strong: Bool = false) -> some View {
        modifier(OverlayChip(shape: Capsule(), edge: edge, strong: strong))
    }
    func overlayCircle(edge: Bool = false, strong: Bool = false) -> some View {
        modifier(OverlayChip(shape: Circle(), edge: edge, strong: strong))
    }

    /// A segmented picker that switches what a panel shows. The neutral selection keeps tabs apart from
    /// settings (`ChoiceSegments`): on macOS 26+, left alone, the system tinted some switchers with the accent.
    func tabs() -> some View { modifier(Tabs()) }
}

/// A short single choice that sets a value (profile, file format): the chosen option filled with the accent.
/// Drawn here, not a system segmented picker: before 26 its selection is neutral and ignores the tint, so
/// a setting looked exactly like a tab (`.tabs()`). VoiceOver still gets the segmented picker, and with
/// keyboard focus on an option ←/→ step through them as in one.
struct ChoiceSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i], on = o.value == selection
                Button { selection = o.value } label: {
                    // Flexible and truncating: the inspector column must never be held wider by its labels.
                    Text(o.title).font(.callout.weight(on ? .semibold : .regular)).lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(on ? Color.white : .primary)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.control))
        .onMoveCommand { dir in
            guard let i = options.firstIndex(where: { $0.value == selection }) else { return }
            let j = dir == .left ? i - 1 : dir == .right ? i + 1 : i
            if options.indices.contains(j) { selection = options[j].value }
        }
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].title).tag(options[i].value) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}

private struct Tabs: ViewModifier {
    func body(content: Content) -> some View {
        let picker = content.pickerStyle(.segmented).labelsHidden()
        // Before 26 the selected segment is already neutral; a tint there would only repaint it.
        if #available(macOS 26, *) { picker.tint(Theme.tabTint) } else { picker }
    }
}

/// One option of a single choice listed in rows: an outlined circle when off, so every option reads as
/// one you can pick (the system radio group drew the off ones as dark dots, lost on a dark sheet).
struct RadioRow: View {
    let title: String
    var subtitle: String? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(on ? .semibold : .regular))
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.selected : Theme.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A slider with 0 in the middle (exposure, contrast, horizon): the accent runs from the centre to the
/// thumb, so at 0 there is none — the system slider fills from the left edge, and 0 looked half applied.
/// The system slider stays for the thumb, keys and accessibility; its track is masked off and drawn here.
struct BipolarSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // Thumb and track sizes differ by OS version and control size: asked of AppKit, not hard-coded.
        let (knob, line) = Self.metrics(controlSize)
        // Around the thumb the system track stays visible (wider while dragging: the glass thumb grows),
        // so it is never cut; for v > 0 its own fill there is the accent too.
        let gap = knob + (dragging ? 5 : 1)
        Slider(value: $value, in: range) { e in dragging = e; onEditingChanged(e) }
            // nil: the system accent, as the fill drawn here. Disabled, the system dims its own part only.
            .tint(value > 0 && isEnabled ? nil : Color.clear)
            .mask {
                GeometryReader { g in
                    let x = position(value, g.size.width, knob: knob)
                    Path { p in
                        // Past the bounds: the focus ring is drawn outside the slider and must stay.
                        p.addRect(CGRect(origin: .zero, size: g.size).insetBy(dx: -8, dy: -8))
                        for r in band(g.size, around: x, gap: gap, line: line) { p.addRect(r) }
                    }
                    .fill(style: FillStyle(eoFill: true))
                }
            }
            .background {
                GeometryReader { g in
                    let x = position(value, g.size.width, knob: knob), mid = position(0, g.size.width, knob: knob)
                    let end = x > mid ? x - knob : x + knob
                    ForEach(Array(band(g.size, around: x, gap: gap, line: line).enumerated()), id: \.offset) { _, r in
                        Capsule().fill(Theme.track)
                            .frame(width: r.width, height: line)
                            .position(x: r.midX, y: r.midY)
                    }
                    if abs(x - mid) > knob {
                        Capsule().fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: abs(end - mid), height: line)
                            .position(x: (end + mid) / 2, y: g.size.height / 2)
                    }
                }
            }
    }

    /// Half the thumb's width and the track's thickness of the system slider at this size.
    @MainActor private static var cache: [ControlSize: (CGFloat, CGFloat)] = [:]
    @MainActor private static func metrics(_ size: ControlSize) -> (knob: CGFloat, line: CGFloat) {
        if let m = cache[size] { return m }
        let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        switch size {
        case .mini: s.controlSize = .mini
        case .small: s.controlSize = .small
        case .large: s.controlSize = .large
        default: s.controlSize = .regular
        }
        s.sizeToFit()
        s.frame.size.width = 200
        let c = s.cell as? NSSliderCell
        let knob = (c?.knobThickness ?? 20) / 2, line = c?.barRect(flipped: true).height ?? 4
        let m = (knob > 0 ? knob : 10, line > 0 ? line : 4)
        cache[size] = m
        return m
    }

    /// Where the system puts the thumb's centre for `v`.
    private func position(_ v: Double, _ width: CGFloat, knob: CGFloat) -> CGFloat {
        let lo = range.lowerBound, hi = range.upperBound
        return knob + max(width - 2 * knob, 0) * CGFloat((min(max(v, lo), hi) - lo) / (hi - lo))
    }

    /// The track left and right of the thumb.
    private func band(_ size: CGSize, around x: CGFloat, gap: CGFloat, line: CGFloat) -> [CGRect] {
        let y = size.height / 2 - line / 2 - 1, h = line + 2
        return [CGRect(x: 0, y: y, width: max(x - gap, 0), height: h),
                CGRect(x: min(x + gap, size.width), y: y, width: max(size.width - x - gap, 0), height: h)]
    }
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
