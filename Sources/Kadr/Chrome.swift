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

// MARK: - Shared controls

/// An active filter as a small capsule with a cross: the filter bar and the «Фильтры» panel.
struct Chip: View {
    let text: String
    var icon: String?
    let clear: () -> Void

    init(_ text: String, icon: String? = nil, clear: @escaping () -> Void) {
        self.text = text; self.icon = icon; self.clear = clear
    }

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.selected, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(tr("Снять этот фильтр"))
    }
}

/// The colour labels as a row of dots, one click each: a label to set (info, selection bar) or to filter by.
/// The chosen one gets a white ring; `dim` fades the others (not this photo's, or no frame has it).
struct LabelDots: View {
    var size: CGFloat
    var spacing: CGFloat
    /// A 22 pt click target around each dot; off where a bar's width must not change.
    var target = false
    var on: (ColorLabel) -> Bool = { _ in false }
    var dim: (ColorLabel) -> Bool = { _ in false }
    var dimmed = 0.35
    var help: (ColorLabel) -> String = { $0.title }
    let action: (ColorLabel) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(ColorLabel.allCases) { l in
                let set = on(l)
                Button { action(l) } label: {
                    Circle().fill(l.color).frame(width: size, height: size)
                        .overlay(Circle().strokeBorder(.white, lineWidth: set ? 2 : 0))
                        .opacity(dim(l) ? dimmed : 1)
                        .modifier(TargetIf(on: target))
                }
                .buttonStyle(.plain)
                .help(help(l))
                .accessibilityLabel(l.title)
                .accessibilityAddTraits(set ? .isSelected : [])
            }
        }
    }
}

/// Stars 1–5 to click. With a `rating`, filled up to it; without one (several photos at once) all are
/// filled, brighter towards five. `caption` is the tooltip and the spoken name; without it, "n ★".
struct RatingStars: View {
    var rating: Int?
    var font: Font
    var spacing: CGFloat
    var caption: ((Int) -> String)?
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { n in
                let lit = rating.map { n <= $0 }
                Button { set(n) } label: {
                    Image(systemName: lit == false ? "star" : "star.fill")
                        .font(font)
                        .foregroundStyle(lit == nil ? Theme.star.opacity(0.35 + Double(n) * 0.13) : lit! ? Theme.star : .secondary)
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .help(caption?(n) ?? "")
                .accessibilityLabel(caption.map { Text($0(n)) } ?? Text(verbatim: "\(n) ★"))   // no words to translate
                .accessibilityAddTraits(lit == true ? .isSelected : [])
            }
        }
    }
}

private struct TargetIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.hitTarget() } else { content }
    }
}

/// The line above an edit slider: a mark, the name, the value and a reset that appears once the value is
/// changed; double-clicking the name resets too (unless `plain`).
struct SliderHeader<Mark: View>: View {
    let title: String
    let value: String
    let changed: Bool
    var resetHelp: String?
    /// The toning rows: the value stays quiet when changed, and the name doesn't reset.
    var plain = false
    let reset: () -> Void
    @ViewBuilder let mark: Mark

    var body: some View {
        HStack(spacing: 6) {
            mark
            Text(title)
                .foregroundStyle(changed ? .primary : .secondary)
                .onTapGesture(count: 2) { if !plain { reset() } }
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(changed && !plain ? .semibold : .regular))
                .foregroundStyle(changed && !plain ? .primary : .secondary)
            Button(action: reset) { Image(systemName: "arrow.uturn.backward.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
                .help(resetHelp ?? "")
        }
    }
}

extension SliderHeader where Mark == SliderIcon {
    init(_ title: String, icon: String, value: String, changed: Bool, resetHelp: String? = tr("Сбросить"), reset: @escaping () -> Void) {
        self.init(title: title, value: value, changed: changed, resetHelp: resetHelp, reset: reset) {
            SliderIcon(name: icon, changed: changed)
        }
    }
}

/// A slider's symbol, in the accent once its value is changed.
struct SliderIcon: View {
    let name: String
    let changed: Bool
    var body: some View {
        Image(systemName: name).frame(width: 18).foregroundStyle(changed ? Color.accentColor : .secondary)
    }
}

/// A slider over a colour strip (temperature, tint, hue) instead of its own track.
struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let colors: [Color]
    var height: CGFloat = 4
    var opacity = 0.7

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(height: height).clipShape(Capsule()).opacity(opacity).padding(.horizontal, 2)
            Slider(value: $value, in: range).tint(.clear)
        }
    }
}

/// A picture made off the main thread for `key`: `placeholder` until the first one arrives. A new key keeps
/// the old picture until its own is ready (a thumbnail re-rendered after an edit doesn't flash), and a
/// failed load keeps it too, unless `keepOnFailure` is off (a face or preview of something else entirely).
struct LoadedImage<Key: Equatable, Content: View, Placeholder: View>: View {
    let key: Key
    let load: () async -> CGImage?
    var keepOnFailure = true
    @ViewBuilder let content: (CGImage) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: CGImage?

    var body: some View {
        // A ZStack, not a Group: the task must stay on one view when the placeholder gives way to the picture.
        ZStack {
            if let image { content(image) } else { placeholder() }
        }
        .task(id: key) {
            let img = await load()
            if img != nil || !keepOnFailure, !Task.isCancelled { image = img }
        }
    }
}

// MARK: - Screen

/// The screen a window is on. `NSScreen.main` is the screen of the key window (or the first one), so with
/// two monitors it sized renders and sheets for whichever screen had focus, not the one showing the photos.
struct ScreenMetrics: Equatable {
    var side: CGFloat = 2560     // the longer side, in pixels
    var height: CGFloat = 900    // the visible height, in points
    /// What a frame is developed at to fill this screen; capped, a 6K display would gain little for the time.
    var renderSide: CGFloat { min(side, 3200) }
}

extension ScreenMetrics {
    init(_ s: NSScreen) {
        self.init(side: max(s.frame.width, s.frame.height) * s.backingScaleFactor, height: s.visibleFrame.height)
    }
}

private struct ScreenKey: EnvironmentKey { static let defaultValue = ScreenMetrics() }

extension EnvironmentValues {
    var screen: ScreenMetrics {
        get { self[ScreenKey.self] }
        set { self[ScreenKey.self] = newValue }
    }
}

extension View {
    /// Gives the views below the metrics of the screen their window is on, kept up when it moves to another.
    /// Until the probe reports (after the view is in a window), `start` or the key window's screen stands in:
    /// a first render or a sheet's height mustn't go by the 2560 / 900 defaults.
    func screenMetrics(start: NSScreen? = nil) -> some View {
        modifier(ScreenReader(metrics: (start ?? NSScreen.main).map(ScreenMetrics.init) ?? ScreenMetrics()))
    }
}

private struct ScreenReader: ViewModifier {
    @State var metrics: ScreenMetrics

    func body(content: Content) -> some View {
        content
            .environment(\.screen, metrics)
            .background(ScreenProbe { m in if m != metrics { metrics = m } })
    }
}

private struct ScreenProbe: NSViewRepresentable {
    let changed: (ScreenMetrics) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ v: ProbeView, context: Context) { v.changed = changed; v.report() }

    final class ProbeView: NSView {
        var changed: ((ScreenMetrics) -> Void)?
        // nonisolated(unsafe): deinit removes it; NotificationCenter's removeObserver is thread-safe.
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let w = window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        func report() {
            guard let s = window?.screen else { return }
            let m = ScreenMetrics(s)
            // Deferred: state must not change while SwiftUI is placing this view.
            DispatchQueue.main.async { [weak self] in self?.changed?(m) }
        }
    }
}
