import SwiftUI

/// Bottom bar for several selected photos: one decision for all of them. A fixed strip, not a floating
/// one, so it never covers the last row of the grid; narrow windows get icons instead of captions.
struct SelectionBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        Bar(edge: .bottom) {
            ViewThatFits(in: .horizontal) {
                // Each width with tighter gaps too: they pay for the 22 pt click targets, so captions and
                // icons give way at about the same widths as before.
                row(captions: true)
                row(captions: true, spacing: 6)
                row(captions: false)
                row(captions: false, spacing: 6)
            }
        }
    }

    private func row(captions: Bool, spacing: CGFloat = 12) -> some View {
        HStack(spacing: spacing) {
            Text(captions ? tr("Выделено \(lib.targets.count)") : "\(lib.targets.count)")
                .font(.callout.weight(.semibold)).monospacedDigit().fixedSize()

            divider

            // Glyphs keep their size; the 22 pt frames are the click targets (a 13 pt dot was hard to hit).
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { n in
                    Button { lib.setRating(n) } label: { Image(systemName: "star.fill").font(.callout).hitTarget() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.star.opacity(0.35 + Double(n) * 0.13))
                        .help(tr("\(n) ★ всем"))
                        .accessibilityLabel(tr("\(n) ★ всем"))
                }
                Button { lib.setRating(0) } label: { Image(systemName: "star.slash").font(.callout).hitTarget() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Снять оценку"))
                    .accessibilityLabel(tr("Снять оценку"))
            }

            HStack(spacing: 0) {
                ForEach(ColorLabel.allCases) { l in
                    Button { lib.toggleLabel(l) } label: { Circle().fill(l.color).frame(width: 13, height: 13).hitTarget() }
                        .buttonStyle(.plain).help(l.title).accessibilityLabel(l.title)
                }
            }

            divider

            action(tr("Оставить"), "checkmark.circle", tint: Theme.keep, captions: captions, help: tr("Оставить все выделенные (P)")) { lib.keep() }
            action(tr("Брак"), "xmark.circle", tint: Theme.reject, captions: captions, help: tr("В брак все выделенные (X)")) { lib.toggleReject() }

            divider

            action(tr("Сравнить"), "rectangle.split.2x1", tint: .primary, captions: captions, help: tr("Сравнить 2–8 кадров рядом (C)")) { lib.startCompare() }
            action(tr("Сохранить в папку"), "square.and.arrow.down.on.square", tint: .primary, captions: captions, help: tr("Сохранить выделенные в папку (⌘S)")) {
                lib.export.scope = .selected
                lib.showExport = true
            }

            Spacer(minLength: 0)

            Button { lib.clearSelection() } label: { Image(systemName: "xmark").hitTarget() }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Снять выделение (Esc)"))
                .accessibilityLabel(tr("Снять выделение (Esc)"))
        }
    }

    private func action(_ title: String, _ icon: String, tint: Color, captions: Bool, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if captions { Text(title) }
            }
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }

    private var divider: some View {
        Divider().frame(height: 16)
    }
}
