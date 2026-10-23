import SwiftUI

struct InfoPanel: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ScrollView {
            if let p = lib.current {
                VStack(alignment: .leading, spacing: 18) {
                    if lib.multiSelected {
                        Label(tr("Выделено \(lib.targets.count) — оценка и цвет применятся ко всем"), systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.name).font(.headline)
                        if let d = p.exif.date {
                            Text(d.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(I18n.locale)))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    ratingControl(p)
                    labelControl(p)

                    Divider()

                    if !p.exif.exposureLine.isEmpty {
                        Text(p.exif.exposureLine)
                            .font(.callout.monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        row(tr("Камера"), p.exif.camera)
                        row(tr("Объектив"), p.exif.lens)
                        if let w = p.exif.width, let h = p.exif.height {
                            row(tr("Размер"), tr("\(w) × \(h)  ·  \(String(format: "%.0f", Double(w * h) / 1_000_000)) Мп"))
                        }
                        row(tr("Файл"), ByteCountFormatter.string(fromByteCount: p.fileSize, countStyle: .file))
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Анализ")).font(.subheadline.weight(.semibold))
                        if let s = p.sharpness {
                            SharpnessBar(value: s, max: maxSharpness)
                        }
                        if p.seriesID != nil {
                            let s = lib.series(of: p)
                            Text(p.isBestInSeries ? tr("Самый резкий кадр в серии из \(s.count)") : tr("Серия из \(s.count) похожих кадров"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let d = p.duplicateOf {
                            Text(tr("Точная копия \(d.lastPathComponent)"))
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tr("Нет выбранного снимка")).foregroundStyle(.secondary).padding()
            }
        }
    }

    private var maxSharpness: Double { lib.maxSharpness ?? 1 }

    private func ratingControl(_ p: Photo) -> some View {
        HStack(spacing: 6) {
            RatingStars(rating: p.rating, font: .title3, spacing: 6) { n in lib.setRating(p.rating == n ? 0 : n) }
            Spacer()
            Button { lib.toggleReject() } label: {
                Image(systemName: p.rejected ? "xmark.circle.fill" : "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(p.rejected ? Theme.reject : .secondary)
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .help(tr("Отклонить (X)"))
            .accessibilityLabel(tr("Отклонить (X)"))
            .accessibilityAddTraits(p.rejected ? .isSelected : [])
        }
    }

    private func labelControl(_ p: Photo) -> some View {
        // 22 pt targets around the 18 pt dots, with the spacing cut by the same 4 pt: the row looks as before.
        LabelDots(size: 18, spacing: 6, target: true, on: { p.label == $0 }, dim: { p.label != $0 }, dimmed: 0.3) { lib.toggleLabel($0) }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                    Text(value).textSelection(.enabled)
                }
                .font(.callout)
            }
        }
    }
}

struct SharpnessBar: View {
    let value: Double
    let max: Double

    var body: some View {
        let k = min(1, value / Swift.max(max, 1))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("Резкость")).font(.callout)
                Spacer()
                Text("\(Int(k * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(k > 0.5 ? Color.green : k > 0.25 ? Color.yellow : Theme.reject)
                        .frame(width: g.size.width * k)
                }
            }
            .frame(height: 5)
            Text(tr("относительно самого резкого кадра в папке"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
