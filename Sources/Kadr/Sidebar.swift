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
    @AppStorage("sb.cull") private var showCull = true
    @AppStorage("sb.scenes") private var showScenes = true
    @AppStorage("sb.tab") private var tab = 0      // 0 = folders, 1 = filters

    var body: some View {
        // Two tabs so things aren't all piled together: "Folders" (as in Finder) and shooting "Filters".
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(tr("Папки")).tag(0)
                Text(tr("Фильтры")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 6)
            if tab == 0 { folders } else { filters }
        }
    }

    private var folders: some View {
        @Bindable var lib = lib
        return List {
            // The open folder at the top, with its subfolders: you can see right away where the photos are.
            if let f = lib.folder {
                Section(tr("Открыта")) {
                    FolderRow(url: f, icon: "folder.fill")
                    Text(f.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                        .selectionDisabled()
                }
            }
            Section(tr("Места")) {
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
        }
        .listStyle(.sidebar)
    }

    private var filters: some View {
        List(selection: Binding(get: { lib.filter }, set: { if let f = $0 { lib.filter = f; lib.move(0) } })) {
            if lib.folder == nil {
                Text(tr("Откройте папку на вкладке «Папки»")).font(.callout).foregroundStyle(.secondary).selectionDisabled()
            } else {
                Section(tr("Съёмка"), isExpanded: $showShoot) {
                    row(.all)
                    row(.undecided)
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
                if lib.scenes.count > 1 {
                    Section(tr("Сцены"), isExpanded: $showScenes) {
                        ForEach(lib.scenes) { sc in
                            HStack {
                                Label(sc.title, systemImage: "film.stack").lineLimit(1)
                                Spacer()
                                Text("\(lib.sceneProgress(sc))/\(sc.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .help(tr("Решено (оставлено или в браке) из всех кадров сцены"))
                            }
                            .tag(PhotoFilter.scene(sc.id))
                        }
                    }
                }
                Section(isExpanded: $showCull) {
                    if lib.aiOn {
                        row(.suspects, tint: .orange)
                        row(.leaders, tint: .green)
                        ForEach(CullReason.allCases.filter { lib.count(.reason($0)) > 0 }) { r in
                            row(.reason(r), tint: r.isDefect ? .orange : .yellow)
                        }
                    } else if lib.aiRunning {
                        Label(tr("AI-анализ \(lib.aiDone)/\(lib.aiTotal)"), systemImage: "hourglass")
                            .font(.callout).foregroundStyle(.secondary).selectionDisabled()
                    } else if lib.aiReady {
                        Text(tr("Подсказки выключены")).font(.callout).foregroundStyle(.secondary).selectionDisabled()
                    } else {
                        Button { lib.startAI() } label: { Label(tr("Запустить AI-анализ"), systemImage: "sparkles") }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .disabled(lib.analyzed < lib.photos.count)
                            .selectionDisabled()
                    }
                } header: {
                    Label(tr("AI-отбор"), systemImage: "sparkles")
                }
                Section(tr("Серии и дубли"), isExpanded: $showAnalysis) {
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

    /// Toggle row: works together with the main filter (e.g. ★3 and an 85 mm lens).
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
