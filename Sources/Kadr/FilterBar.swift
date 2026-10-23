import AppKit
import SwiftUI

/// Bar above the photos: where you are, the main culling filters one click away, and chips for whatever
/// else narrows the view. The full set of filters lives in the sidebar's «Фильтры» tab (FiltersPanel).
struct FilterBar: View {
    @Environment(Library.self) private var lib
    @State private var showThumbSize = false

    var body: some View {
        Bar {
            // The count sits outside the variants, so it stays in sight however narrow the column is; the
            // variants get what is left, and the last one is cut on the right instead of pushing it out.
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    row(full: true)
                    row(full: false)
                    HStack(spacing: 8) {
                        breadcrumb(icon: false); sortMenu(caption: false); Spacer(minLength: 6); decisionsMenu; more(caption: true)
                        if lib.filter == .rejected { rejectedAction(caption: false) }
                        if lib.inSeries { backFromSeries(caption: false) }
                        if lib.culling { cullStatus(full: false) }
                        Spacer(minLength: 6)
                        if !lib.loupe { thumbSize(width: 56) }
                    }
                    // About 300 pt: the folder name is in its menu, the preview size in a popover, and the
                    // situational actions (burst, rejects, culling) in «Ещё» — a clipped edge must not hide them.
                    HStack(spacing: 6) {
                        breadcrumb(icon: true); sortMenu(caption: false); Spacer(minLength: 4); decisionsMenu
                        more(caption: false, actions: true)
                        if !lib.loupe { thumbSizeButton }
                        Spacer(minLength: 0)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                count
            }
        }
    }

    private func row(full: Bool) -> some View {
        HStack(spacing: 10) {
            breadcrumb(icon: false)
            sortMenu(caption: true)
            Spacer(minLength: 6)
            if full {
                decisions(compact: false); stars; labels; more(caption: true)
            } else {
                decisions(compact: true); stars; more(caption: true)
            }
            if lib.filter == .rejected { rejectedAction(caption: full) }
            if lib.inSeries { backFromSeries(caption: full) }
            Spacer(minLength: 6)
            if lib.culling { cullStatus(full: full) }
            if full { chips }
            if !lib.loupe { thumbSize(width: full ? 80 : 64) }
        }
    }

    // MARK: - Culling layer

    /// The pass so far: how much is seen, and the summary. Only while the layer is on; it replaces the top
    /// bar of the former culling mode. The kept / rejected / undecided counts are already on the decision
    /// buttons to the left.
    private func cullStatus(full: Bool) -> some View {
        let total = lib.photos.count
        let seen = min(lib.viewed.count, total)   // reindex keeps `viewed` within the folder
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                // Short form: the eye says this counts viewed frames, not the shown «N из M» at the right.
                if !full { Image(systemName: "eye").font(.caption).foregroundStyle(.secondary) }
                ProgressView(value: Double(seen), total: Double(max(total, 1))).frame(width: full ? 80 : 44)
                Text(full ? tr("Просмотрено \(seen) из \(total)") : "\(seen)/\(total)")
                    .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
            }
            .help(tr("Сколько кадров вы уже видели со включённым слоем «Отбор»"))
            // The layer shows little until the analysis has run: the way to start it is right here.
            if !lib.aiReady && !lib.aiRunning && lib.analyzed >= lib.photos.count && !lib.photos.isEmpty {
                Button { lib.startAI() } label: {
                    HStack(spacing: 4) { Image(systemName: "sparkles"); if full { Text(tr("AI-анализ")).fixedSize() } }
                }
                .controlSize(.small).fixedSize()
                .help(tr("Найдёт смаз, моргание, пересвет и лучшие кадры в сериях. Нагружает Mac: ~1 минута на 1000 кадров (⌥⌘A)."))
            }
            Button(tr("Итог…")) { lib.showCullSummary = true }.controlSize(.small).fixedSize()
                .help(tr("Итог отбора: сколько оставлено и отклонено, что делать дальше"))
            HintButton(id: "cull")
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
    /// In every variant of the bar: with the sidebar and the inspector open, the full one rarely fits.
    private func thumbSize(width: CGFloat) -> some View {
        @Bindable var lib = lib
        return HStack(spacing: 4) {
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
            Slider(value: $lib.thumbSize, in: 120...420).frame(width: width).controlSize(.mini)
        }
        .help(tr("Размер превью"))
    }

    /// The narrowest bar: the slider folds into a button, the slider itself floats in a popover.
    private var thumbSizeButton: some View {
        @Bindable var lib = lib
        return Button { showThumbSize.toggle() } label: {
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Размер превью"))
        .popover(isPresented: $showThumbSize, arrowEdge: .bottom) {
            Slider(value: $lib.thumbSize, in: 120...420).frame(width: 160).controlSize(.small).padding(12)
        }
    }

    // MARK: - Where

    /// Folder name (only the icon in the narrowest bar); the menu goes up to the parent folders.
    private func breadcrumb(icon: Bool) -> some View {
        Menu {
            if let f = lib.folder {
                // The full name and path, for when the label had to be shortened.
                Text(FolderBrowser.displayName(f))
                Text(FolderBrowser.shortPath(f))
                Divider()
                // Parents are shown in the explorer, not scanned: scanning is a deliberate step.
                ForEach(parents(of: f), id: \.self) { p in
                    Button(FolderBrowser.displayName(p)) { lib.browser.reveal(p) }
                }
                Divider()
                Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
        } label: {
            // Shortened in code, not by the layout: the label keeps `.fixedSize()` so ViewThatFits
            // measures its true width; a layout-truncated label would overflow onto the sort menu.
            HStack(spacing: 4) {
                if icon {
                    Image(systemName: "folder")
                } else {
                    Label(lib.folder.map { Self.shortName(FolderBrowser.displayName($0)) } ?? "", systemImage: "folder")
                        .lineLimit(1)
                }
                MenuChevron()
            }
            .contentShape(Rectangle())
        }
        .plainMenu()
        .fixedSize()
        .help(lib.folder.map { tr("Открыта: \($0.path)") + "\n" + tr("Меню — перейти в папку выше") } ?? "")
    }

    /// "11160601_1.06.2026_Studio_Photo_kun" → "11160601_1.06…_Photo_kun": the start and the end survive.
    static func shortName(_ s: String, max: Int = 26) -> String {
        guard s.count > max else { return s }
        let head = (max - 1) / 2, tail = max - 1 - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
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
                MenuChevron()
            }
            .contentShape(Rectangle())
        }
        .plainMenu()
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
        .background(Theme.control, in: Capsule())
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
                MenuChevron()
            }
            .contentShape(Rectangle())
        }
        .plainMenu()
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

    private func more(caption: Bool, actions: Bool = false) -> some View {
        @Bindable var lib = lib
        let extra = !Self.main.contains(lib.filter) && !isStars && !isLabel
        // Series, AI picks, scenes, lenses, days, people and tags moved to the sidebar's «Фильтры» tab:
        // one click each, with counts, instead of two levels of menus.
        return Menu {
            if actions { situationalActions }
            Button(tr("Все фильтры в панели… (⌥⌘2)")) { Sidebar.show(.filters) }
            if extra { Button(tr("Снять фильтр «\(lib.filter.title)»")) { set(.all) } }
            Divider()
            Toggle(tr("Скрыть брак (H)"), isOn: $lib.hideRejected)
            Toggle(tr("С вложенными папками"), isOn: $lib.includeSubfolders)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle" + (extra ? ".fill" : ""))
                if caption { Text(extra ? lib.filter.title : tr("Ещё")).lineLimit(1) }
                MenuChevron()
            }
            .contentShape(Rectangle())
        }
        .plainMenu()
        .fixedSize()
        .help(tr("Панель фильтров (⌥⌘2), скрыть брак, подпапки"))
    }

    /// The bar's situational buttons as menu items, for the narrowest bar.
    @ViewBuilder private var situationalActions: some View {
        if lib.inSeries { Button(tr("Все кадры (Esc)")) { lib.leaveSeries() } }
        if lib.filter == .rejected {
            let n = lib.count(.rejected)
            Button(tr("Перенести в «_Отклонённые» (\(n))")) { lib.moveRejected() }.disabled(n == 0)
        }
        if lib.culling {
            if !lib.aiReady && !lib.aiRunning && lib.analyzed >= lib.photos.count && !lib.photos.isEmpty {
                Button(tr("AI-анализ")) { lib.startAI() }
            }
            Button(tr("Итог…")) { lib.showCullSummary = true }
        }
        if lib.inSeries || lib.filter == .rejected || lib.culling { Divider() }
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
            ForEach(lib.tagFilters.sorted(), id: \.self) { t in chip(TagNames.title(t), icon: "tag") { lib.toggleTag(t, add: true) } }
            ForEach(lib.people.filter { lib.personFilters.contains($0.id) }) { p in
                chip(p.title, icon: "person.crop.circle") { lib.togglePerson(p.id, add: true) }
            }
            if lib.hideRejected && lib.filter != .rejected {
                chip(tr("брак скрыт"), icon: "eye.slash") { lib.hideRejected = false }
            }
        }
    }

    /// How many photos are shown; turns into a hint when extra filters hide some.
    private var count: some View {
        let extra = lib.extraFiltersActive
        return Text(tr("\(lib.visible.count) из \(lib.photos.count)"))
            .font(.caption.monospacedDigit()).foregroundStyle(extra ? Color.accentColor : .secondary)
            .fixedSize()
            .help(extra ? tr("Часть кадров скрыта фильтрами объектива, даты, тегов, людей или «Скрыть брак» — см. панель «Фильтры» (⌥⌘2)") : "")
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
