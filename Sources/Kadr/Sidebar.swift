import SwiftUI

struct Sidebar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        @Bindable var lib = lib
        List(selection: Binding(get: { lib.filter }, set: { if let f = $0 { lib.filter = f; lib.move(0) } })) {
            Section("Съёмка") {
                row(.all)
                row(.unrated)
                row(.picked)
                row(.rejected, tint: Theme.reject)
            }
            Section("Оценка") {
                ForEach((1...5).reversed(), id: \.self) { n in
                    starRow(n)
                }
            }
            Section("Цвет") {
                ForEach(ColorLabel.allCases) { l in
                    row(.label(l), tint: l.color)
                }
            }
            Section("Анализ") {
                row(.best, tint: Theme.star)
                row(.duplicates)
                if lib.seriesCount > 0 {
                    Label("Серий похожих: \(lib.seriesCount)", systemImage: "square.stack.3d.up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ f: PhotoFilter, tint: Color? = nil) -> some View {
        HStack {
            Label {
                Text(f.title)
            } icon: {
                Image(systemName: f.icon).foregroundStyle(tint ?? .secondary)
            }
            Spacer()
            countBadge(f)
        }
        .tag(f)
    }

    private func starRow(_ n: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < n ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(i < n ? Theme.star : .secondary.opacity(0.4))
            }
            Spacer()
            countBadge(.stars(n))
        }
        .tag(PhotoFilter.stars(n))
    }

    private func countBadge(_ f: PhotoFilter) -> some View {
        Text("\(lib.count(f))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
