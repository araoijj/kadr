import SwiftUI

/// Bottom bar for several selected photos: one decision for all of them. A fixed strip, not a floating
/// one, so it never covers the last row of the grid; narrow windows get icons instead of captions.
struct SelectionBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        Bar(edge: .bottom) {
            ViewThatFits(in: .horizontal) {
                row(captions: true)
                row(captions: false)
            }
        }
    }

    private func row(captions: Bool) -> some View {
        HStack(spacing: 12) {
            Text(captions ? tr("Выделено \(lib.targets.count)") : "\(lib.targets.count)")
                .font(.callout.weight(.semibold)).monospacedDigit().fixedSize()

            divider

            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Button { lib.setRating(n) } label: { Image(systemName: "star.fill").font(.callout) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.star.opacity(0.35 + Double(n) * 0.13))
                        .help(tr("\(n) ★ всем"))
                }
                Button { lib.setRating(0) } label: { Image(systemName: "star.slash").font(.callout) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Снять оценку"))
            }

            HStack(spacing: 6) {
                ForEach(ColorLabel.allCases) { l in
                    Button { lib.toggleLabel(l) } label: { Circle().fill(l.color).frame(width: 13, height: 13) }
                        .buttonStyle(.plain).help(l.title)
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

            Button { lib.clearSelection() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Снять выделение (Esc)"))
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
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
    }
}
