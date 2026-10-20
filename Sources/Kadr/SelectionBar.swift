import SwiftUI

/// Панель внизу, когда выделено несколько снимков: действия сразу над всеми.
struct SelectionBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Text("Выделено \(lib.targets.count)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()

                divider

                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { n in
                        Button { lib.setRating(n) } label: {
                            Image(systemName: "star.fill").font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.star.opacity(0.35 + Double(n) * 0.13))
                        .help("\(n) ★ всем")
                    }
                    Button { lib.setRating(0) } label: { Image(systemName: "star.slash").font(.callout) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Снять оценку")
                }

                HStack(spacing: 6) {
                    ForEach(ColorLabel.allCases) { l in
                        Button { lib.toggleLabel(l) } label: { Circle().fill(l.color).frame(width: 13, height: 13) }
                            .buttonStyle(.plain).help(l.title)
                    }
                }

                Button { lib.toggleReject() } label: { Label("Отклонить", systemImage: "xmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(Theme.reject)

                divider

                Button { lib.startCompare() } label: {
                    Label("Сравнить", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .help("C")

                Button { lib.export.scope = .selected; lib.showExport = true } label: {
                    Label("Сохранить в папку", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.plain)

                Button { lib.clearSelection() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Снять выделение (Esc)")
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .padding(.bottom, lib.loupe ? 108 : 18)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16)
    }
}
