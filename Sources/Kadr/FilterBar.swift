import AppKit
import SwiftUI

/// Bar above the photos: where you are, the main culling filters one click away, and the rest under "More".
/// Replaces the "Filters" tab of the sidebar, so narrowing a folder down never needs a tab switch.
struct FilterBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        Bar {
            ViewThatFits(in: .horizontal) {
                row(full: true)
                row(full: false)
                HStack(spacing: 8) {
                    breadcrumb; sortMenu(caption: false); Spacer(minLength: 6); decisionsMenu; more
                    if lib.filter == .rejected { rejectedAction(caption: false) }
                    if lib.inSeries { backFromSeries(caption: false) }
                    Spacer(minLength: 6); count
                }
            }
        }
    }

    private func row(full: Bool) -> some View {
        HStack(spacing: 10) {
            breadcrumb
            sortMenu(caption: true)
            Spacer(minLength: 6)
            if full {
                decisions(compact: false); stars; labels; more
            } else {
                decisions(compact: true); stars; more
            }
            if lib.filter == .rejected { rejectedAction(caption: full) }
            if lib.inSeries { backFromSeries(caption: full) }
            Spacer(minLength: 6)
            if full { chips }
            if full, !lib.loupe { thumbSize }
            count
        }
    }

    /// A burst is open: the way back to the photos you came from is right here, not only on Esc.
    private func backFromSeries(caption: Bool) -> some View {
        Button { lib.leaveSeries() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                if caption { Text(tr("Все кадры (Esc)")).lineLimit(1).fixedSize() }
            }
        }
        .controlSize(.small)
        .help(tr("Выйти из серии — назад к кадрам, из которых вы её открыли (Esc)"))
    }

    /// What to do with the rejects once they are reviewed: get them out of the shoot folder.
    private func rejectedAction(caption: Bool) -> some View {
        let n = lib.count(.rejected)
        return Button { lib.moveRejected() } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.badge.minus")
                if caption { Text(tr("Перенести в «_Отклонённые» (\(n))")).lineLimit(1).fixedSize() }
            }
        }
        .controlSize(.small)
        .disabled(n == 0)
        .help(tr("Все отклонённые кадры (\(n)) переедут в подпапку «_Отклонённые» рядом со съёмкой. Файлы не удаляются."))
    }

    /// Size of the previews in the grid; it lived in the toolbar, where it ate 110 px of every mode.
    private var thumbSize: some View {
        @Bindable var lib = lib
        return HStack(spacing: 4) {
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
            Slider(value: $lib.thumbSize, in: 120...420).frame(width: 80).controlSize(.mini)
        }
        .help(tr("Размер превью"))
    }

    // MARK: - Where

    /// Folder name; the menu goes up to the parent folders.
    private var breadcrumb: some View {
        Menu {
            if let f = lib.folder {
                ForEach(parents(of: f), id: \.self) { p in
                    Button(FolderBrowser.displayName(p)) { lib.open(p) }
                }
                Divider()
                Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
        } label: {
            Label(lib.folder.map(FolderBrowser.displayName) ?? "", systemImage: "folder")
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 220, alignment: .leading)
        .help(lib.folder.map { tr("Открыта: \($0.path)") + "\n" + tr("Меню — перейти в папку выше") } ?? "")
    }

    private func parents(of u: URL) -> [URL] {
        var out: [URL] = [], p = u.deletingLastPathComponent()
        while p.path != "/" && out.count < 6 {
            out.append(p)
            if p.path == "/Volumes" { break }
            p = p.deletingLastPathComponent()
        }
        return out
    }

    // MARK: - Order

    /// What the photos are ordered by, always in sight: the order is the first thing you need to trust
    /// when flipping through a shoot, and it used to hide in a toolbar menu.
    private func sortMenu(caption: Bool) -> some View {
        @Bindable var lib = lib
        return Menu {
            Picker(tr("Сортировать"), selection: $lib.sortKey) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle(tr("По убыванию"), isOn: $lib.sortDescending)
            Divider()
            Picker(tr("Группировать"), selection: $lib.groupKey) {
                ForEach(GroupKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: lib.sortDescending ? "arrow.down" : "arrow.up").font(.caption2.weight(.bold))
                if caption {
                    Text(sortCaption).lineLimit(1).fixedSize()
                } else {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tr("Порядок кадров: \(lib.sortKey.title.lowercased()), \(lib.sortDescending ? tr("по убыванию") : tr("по возрастанию"))")
              + (lib.groupKey == .none ? "" : " · " + lib.groupKey.title.lowercased()))
    }

    private var sortCaption: String {
        let key: String = switch lib.sortKey {
        case .date: tr("по времени")
        case .name: tr("по имени")
        case .rating: tr("по оценке")
        case .lens: tr("по объективу")
        case .folder: tr("по папке")
        case .size: tr("по размеру")
        }
        return lib.groupKey == .none ? key : key + " · " + lib.groupKey.title.lowercased()
    }

    // MARK: - Decisions

    private static let main: [PhotoFilter] = [.all, .undecided, .picked, .rejected]

    private func name(_ f: PhotoFilter) -> String {
        switch f {
        case .all: tr("Все")
        case .undecided: tr("Без решения")
        case .picked: tr("Оставлено")
        case .rejected: tr("Брак")
        default: f.title
        }
    }

    private func decisions(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Self.main, id: \.self) { f in
                let on = lib.filter == f
                Button { set(f) } label: {
                    HStack(spacing: 4) {
                        if f == .rejected { Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Theme.reject) }
                        if f == .picked { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                        if !compact || on { Text(name(f)) }
                        Text("\(lib.count(f))").monospacedDigit().foregroundStyle(on ? .primary : .secondary)
                    }
                    .font(.callout.weight(on ? .semibold : .regular))
                    .lineLimit(1).fixedSize()   // never wrap: ViewThatFits must see the row's real width
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(on ? Color.accentColor.opacity(0.35) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(name(f))
            }
        }
        .padding(2)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var decisionsMenu: some View {
        Menu {
            ForEach(Self.main, id: \.self) { f in Button("\(name(f)) · \(lib.count(f))") { set(f) } }
        } label: {
            Text(Self.main.contains(lib.filter) ? name(lib.filter) : lib.filter.title).lineLimit(1)
        }
        .fixedSize()
    }

    private var stars: some View {
        let n: Int? = if case .stars(let k) = lib.filter { k } else { nil }
        return Menu {
            Button(tr("Любая оценка")) { set(.all) }
            ForEach((1...5).reversed(), id: \.self) { k in
                Button(String(repeating: "★", count: k) + (k < 5 ? tr(" и выше") : "") + " · \(lib.count(.stars(k)))") { set(.stars(k)) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: n == nil ? "star" : "star.fill").foregroundStyle(n == nil ? .secondary : Theme.star)
                if let n { Text("≥\(n)").monospacedDigit() }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tr("Фильтр по звёздам"))
    }

    private var labels: some View {
        HStack(spacing: 5) {
            ForEach(ColorLabel.allCases) { l in
                let on = lib.filter == .label(l)
                Button { set(on ? .all : .label(l)) } label: {
                    Circle().fill(l.color).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: on ? 2 : 0))
                        .opacity(on || lib.count(.label(l)) > 0 ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .help(l.title + " · \(lib.count(.label(l)))")
            }
        }
    }

    // MARK: - More

    private var more: some View {
        @Bindable var lib = lib
        let extra = !Self.main.contains(lib.filter) && !isStars && !isLabel
        return Menu {
            Section(tr("Серии")) {
                pick(.best)
                pick(.duplicates)
            }
            if lib.aiOn {
                Section(tr("AI-отбор")) {
                    pick(.recommended)
                    pick(.suspects)
                    pick(.leaders)
                    if lib.count(.smiling) > 0 { pick(.smiling) }
                    ForEach(CullReason.allCases.filter { lib.count(.reason($0)) > 0 }) { r in pick(.reason(r)) }
                }
            } else if !lib.aiReady && !lib.aiRunning {
                Button(tr("Запустить AI-анализ")) { lib.startAI() }.disabled(lib.analyzed < lib.photos.count)
            }
            if lib.scenes.count > 1 {
                Menu(tr("Сцены")) {
                    ForEach(lib.scenes) { sc in
                        Button("\(sc.title) · \(lib.sceneProgress(sc))/\(sc.count)") { set(.scene(sc.id)) }
                    }
                }
            }
            if lib.lenses.count > 1 {
                Menu(tr("Объективы")) {
                    ForEach(lib.lenses, id: \.name) { l in
                        Toggle("\(l.name) · \(l.count)", isOn: Binding(get: { lib.lensFilter == l.name },
                                                                    set: { lib.lensFilter = $0 ? l.name : nil; lib.move(0) }))
                    }
                }
            }
            if lib.days.count > 1 {
                Menu(tr("Даты")) {
                    ForEach(lib.days, id: \.day) { d in
                        Toggle("\(d.day.formatted(.dateTime.day().month(.abbreviated).year().locale(I18n.locale))) · \(d.count)",
                               isOn: Binding(get: { lib.dayFilter == d.day }, set: { lib.dayFilter = $0 ? d.day : nil; lib.move(0) }))
                    }
                }
            }
            let tags = lib.aiReady && lib.aiEnabled.contains(.tags) ? Array(lib.tags.prefix(25)) : []
            if !tags.isEmpty {
                Menu(tr("Что на снимках")) {
                    ForEach(tags, id: \.id) { t in
                        Toggle("\(TagNames.title(t.id)) · \(t.count)", isOn: Binding(get: { lib.tagFilter == t.id },
                                                                                     set: { lib.tagFilter = $0 ? t.id : nil; lib.move(0) }))
                    }
                }
            }
            Divider()
            Toggle(tr("Скрыть брак (H)"), isOn: $lib.hideRejected)
            Toggle(tr("С вложенными папками"), isOn: $lib.includeSubfolders)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle" + (extra ? ".fill" : ""))
                Text(extra ? lib.filter.title : tr("Ещё")).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tr("Серии, дубли, AI-отбор, сцены, объективы, даты"))
    }

    private var isStars: Bool { if case .stars = lib.filter { true } else { false } }
    private var isLabel: Bool { if case .label = lib.filter { true } else { false } }

    private func pick(_ f: PhotoFilter) -> some View {
        Toggle("\(f.title) · \(lib.count(f))", isOn: Binding(get: { lib.filter == f }, set: { set($0 ? f : .all) }))
    }

    private func set(_ f: PhotoFilter) {
        lib.filter = f
        lib.move(0)
    }

    // MARK: - Shown

    /// Extra filters as chips with a cross to clear each.
    private var chips: some View {
        HStack(spacing: 6) {
            if let l = lib.lensFilter { chip(l, icon: "camera.aperture") { lib.lensFilter = nil } }
            if let d = lib.dayFilter {
                chip(d.formatted(.dateTime.day().month(.abbreviated).locale(I18n.locale)), icon: "calendar") { lib.dayFilter = nil }
            }
            if let t = lib.tagFilter { chip(TagNames.title(t), icon: "tag") { lib.tagFilter = nil } }
            if lib.hideRejected && lib.filter != .rejected {
                chip(tr("брак скрыт"), icon: "eye.slash") { lib.hideRejected = false }
            }
        }
    }

    /// How many photos are shown; turns into a hint when extra filters hide some.
    private var count: some View {
        let extra = lib.lensFilter != nil || lib.dayFilter != nil || lib.tagFilter != nil || (lib.hideRejected && lib.filter != .rejected)
        return Text(tr("\(lib.visible.count) из \(lib.photos.count)"))
            .font(.caption.monospacedDigit()).foregroundStyle(extra ? Color.accentColor : .secondary)
            .fixedSize()
            .help(extra ? tr("Часть кадров скрыта фильтрами объектива, даты, тегов или «Скрыть брак» — см. «Ещё»") : "")
    }

    private func chip(_ text: String, icon: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(tr("Снять фильтр"))
    }
}
