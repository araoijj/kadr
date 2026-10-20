import SwiftUI

struct Sidebar: View {
    @Environment(Library.self) private var lib
    @AppStorage("sb.folders") private var showFolders = true
    @AppStorage("sb.shoot") private var showShoot = true
    @AppStorage("sb.rating") private var showRating = true
    @AppStorage("sb.color") private var showColor = false
    @AppStorage("sb.lens") private var showLens = true
    @AppStorage("sb.days") private var showDays = true
    @AppStorage("sb.analysis") private var showAnalysis = true

    var body: some View {
        @Bindable var lib = lib
        List(selection: Binding(get: { lib.filter }, set: { if let f = $0 { lib.filter = f; lib.move(0) } })) {
            Section(tr("Папки"), isExpanded: $showFolders) {
                if !lib.browser.recent.isEmpty {
                    DisclosureGroup {
                        ForEach(lib.browser.recent, id: \.self) { FolderRow(url: $0, icon: "clock") }
                    } label: {
                        Label(tr("Недавние"), systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    }
                }
                ForEach(lib.browser.favorites, id: \.self) { u in
                    FolderRow(url: u, icon: icon(for: u))
                }
                ForEach(lib.browser.volumes, id: \.self) { u in
                    FolderRow(url: u, icon: "sdcard")
                }
                Button {
                    lib.showImport = true
                } label: {
                    Label(tr("Импорт с карты…"), systemImage: "square.and.arrow.down")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                Toggle(tr("С вложенными папками"), isOn: $lib.includeSubfolders)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help(tr("Показывать снимки из всех подпапок открытой папки"))
            }

            if lib.folder != nil {
                Section(tr("Съёмка"), isExpanded: $showShoot) {
                    row(.all)
                    row(.unrated)
                    row(.picked)
                    row(.rejected, tint: Theme.reject)
                }
                Section(tr("Оценка"), isExpanded: $showRating) {
                    ForEach((1...5).reversed(), id: \.self) { n in starRow(n) }
                }
                Section(tr("Цвет"), isExpanded: $showColor) {
                    ForEach(ColorLabel.allCases) { l in row(.label(l), tint: l.color) }
                }
                if lib.lenses.count > 1 {
                    Section(tr("Объективы"), isExpanded: $showLens) {
                        ForEach(lib.lenses, id: \.name) { l in
                            toggleRow(l.name, icon: "camera.aperture", count: l.count, on: lib.lensFilter == l.name) {
                                lib.lensFilter = lib.lensFilter == l.name ? nil : l.name
                                lib.move(0)
                            }
                        }
                    }
                }
                if lib.days.count > 1 {
                    Section(tr("Даты"), isExpanded: $showDays) {
                        ForEach(lib.days, id: \.day) { d in
                            toggleRow(d.day.formatted(.dateTime.day().month(.abbreviated).year().locale(I18n.locale)), icon: "calendar",
                                      count: d.count, on: lib.dayFilter == d.day) {
                                lib.dayFilter = lib.dayFilter == d.day ? nil : d.day
                                lib.move(0)
                            }
                        }
                    }
                }
                Section(tr("Анализ"), isExpanded: $showAnalysis) {
                    row(.best, tint: Theme.star)
                    row(.duplicates)
                    if lib.seriesCount > 0 {
                        Label(tr("Серий похожих: \(lib.seriesCount)"), systemImage: "square.stack.3d.up")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func icon(for u: URL) -> String {
        switch u.lastPathComponent {
        case "Pictures": "photo.on.rectangle"
        case "Desktop": "menubar.dock.rectangle"
        case "Downloads": "arrow.down.circle"
        case "Documents": "doc"
        default: "folder"
        }
    }

    /// Строка-переключатель: работает вместе с основным фильтром (например, ★3 и объектив 85 мм).
    private func toggleRow(_ title: String, icon: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(title).lineLimit(1).truncationMode(.middle)
                    .fontWeight(on ? .semibold : .regular)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
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
