import SwiftUI

/// Bottom bar for several selected photos: one decision for all of them. A fixed strip, not a floating
/// one, so it never covers the last row of the grid; narrow windows get icons instead of captions.
struct SelectionBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        Bar(edge: .bottom) {
            // The way out sits outside the variants, so a narrow column never cuts it off; the last variant
            // is cut on the right instead of holding the column wider.
            HStack(spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    // Each width with tighter gaps too: they pay for the 22 pt click targets, so captions and
                    // icons give way at about the same widths as before.
                    row(captions: true)
                    row(captions: true, spacing: 6)
                    row(captions: false)
                    row(captions: false, spacing: 6)
                    // A 1000 pt window with both panels: stars and labels fold into one menu.
                    row(captions: false, spacing: 6, marks: false)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                Button { lib.clearSelection() } label: { Image(systemName: "xmark").hitTarget() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Снять выделение (Esc)"))
                    .accessibilityLabel(tr("Снять выделение (Esc)"))
            }
        }
    }

    private func row(captions: Bool, spacing: CGFloat = 12, marks: Bool = true) -> some View {
        HStack(spacing: spacing) {
            Text(captions ? tr("Выделено \(lib.targets.count)") : "\(lib.targets.count)")
                .font(.callout.weight(.semibold)).monospacedDigit().fixedSize()

            divider

            if marks {
                // Glyphs keep their size; the 22 pt frames are the click targets (a 13 pt dot was hard to hit).
                HStack(spacing: 0) {
                    RatingStars(font: .callout, spacing: 0, caption: { tr("\($0) ★ всем") }) { lib.setRating($0) }
                    Button { lib.setRating(0) } label: { Image(systemName: "star.slash").font(.callout).hitTarget() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Снять оценку"))
                        .accessibilityLabel(tr("Снять оценку"))
                }

                LabelDots(size: 13, spacing: 0, target: true) { lib.toggleLabel($0) }
            } else {
                marksMenu
            }

            divider

            action(tr("Оставить"), "checkmark.circle", tint: Theme.keep, captions: captions, help: tr("Оставить все выделенные (P)")) { lib.keep() }
            action(tr("Брак"), "xmark.circle", tint: Theme.reject, captions: captions, help: tr("В брак все выделенные (X)")) { lib.toggleReject() }

            divider

            action(tr("Сравнить"), "rectangle.split.2x1", tint: .primary, captions: captions, help: tr("Сравнить выделенные кадры рядом (C)")) { lib.startCompare() }
            action(tr("Сохранить в папку"), "square.and.arrow.down.on.square", tint: .primary, captions: captions, help: tr("Сохранить выделенные в папку (⌘S)")) {
                lib.export.scope = .selected
                lib.showExport = true
            }

            Spacer(minLength: 0)
        }
    }

    /// Rating and colour label for the narrowest bar, as one menu.
    private var marksMenu: some View {
        Menu {
            ForEach((1...5).reversed(), id: \.self) { k in Button(tr("\(k) ★ всем")) { lib.setRating(k) } }
            Button(tr("Снять оценку")) { lib.setRating(0) }
            Divider()
            ForEach(ColorLabel.allCases) { l in Button(l.title) { lib.toggleLabel(l) } }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "star").font(.callout)
                MenuChevron()
            }
            .hitTarget()
        }
        .plainMenu()
        .fixedSize()
        .help(tr("Оценка и метка всем выделенным"))
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
