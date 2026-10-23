import SwiftUI
import UniformTypeIdentifiers

/// Left panel, three layers top to bottom:
/// - «Съёмки» — what you work on. Only "Scan" puts a folder here; progress and the path on every row,
///   subfolders under the triangle (each can become a shoot of its own).
/// - «Избранное» — flat bookmarks into the file system. A click unfolds the explorer down to the place.
/// - «Проводник» — home and drives. A click shows the folder card below with "Scan"; nothing scans by itself.
/// Filters are in the bar above the photos (FilterBar).
struct Sidebar: View {
    enum Tab: String { case sources, filters }
    static let tabKey = "sb.tab"
    /// Switches the sidebar tab from anywhere (menu, filter bar); AppStorage picks the change up.
    static func show(_ t: Tab) { UserDefaults.standard.set(t.rawValue, forKey: tabKey) }

    @Environment(Library.self) private var lib
    @AppStorage(tabKey) private var tab = Tab.sources.rawValue
    @AppStorage("sb.shoots") private var showShoots = true
    @AppStorage("sb.cards") private var showCards = true
    @AppStorage("sb.favorites") private var showFavorites = true
    @AppStorage("sb.explorer") private var showExplorer = false
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(tr("Источники")).tag(Tab.sources.rawValue)
                Text(tr("Фильтры")).tag(Tab.filters.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
            .help(tr("⌥⌘1 — источники, ⌥⌘2 — фильтры"))
            if tab == Tab.filters.rawValue {
                FiltersPanel()
            } else {
                sources
            }
        }
    }

    private var sources: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    Section(isExpanded: $showShoots) {
                        if lib.browser.shoots.isEmpty {
                            Text(tr("Пока пусто. Выберите папку в «Избранном» или «Проводнике» и нажмите «Сканировать»."))
                                .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                        }
                        ForEach(lib.browser.shoots, id: \.self) { ShootRow(url: $0) }
                            .onMove { lib.browser.moveShoots(from: $0, to: $1) }
                    } header: {
                        SectionTitle(tr("Съёмки")) {
                            Text(tr("Папки, с которыми вы работаете. Сюда попадает только то, что вы отсканировали; порядок — перетаскиванием."))
                            Button(tr("Сканировать папку…")) { lib.chooseFolder() }
                            Divider()
                            Button(tr("Убрать все, кроме открытой")) { lib.browser.clearShoots(keeping: lib.folder) }
                                .disabled(lib.browser.shoots.isEmpty)
                        }
                    }
                    if !lib.browser.cards.isEmpty {
                        Section(tr("Карты памяти"), isExpanded: $showCards) {
                            ForEach(lib.browser.cards, id: \.self) { CardRow(url: $0) }
                        }
                    }
                    Section(isExpanded: $showFavorites) {
                        if lib.browser.favorites.isEmpty {
                            Text(tr("Закладки на папки, где лежат съёмки. Добавьте через ⋯ или перетащите папку из Finder."))
                                .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                        }
                        ForEach(lib.browser.favorites, id: \.self) { FavoriteRow(url: $0, icon: icon(for: $0)) }
                            .onMove { lib.browser.moveFavorites(from: $0, to: $1) }
                    } header: {
                        SectionTitle(tr("Избранное")) {
                            Text(tr("Закладки: места, где вы ищете съёмки. Клик открывает это место в «Проводнике»."))
                            Button(tr("Добавить папку…")) { lib.browser.chooseFavorite() }
                        }
                    }
                    Section(isExpanded: $showExplorer) {
                        ForEach(lib.browser.explorerRoots, id: \.self) { u in
                            let card = lib.browser.cards.contains(u)
                            FolderRow(url: u, title: card ? tr("\(FolderBrowser.displayName(u)) · карта") : nil,
                                      icon: u == FolderBrowser.home ? "house" : card ? "sdcard.fill" : "externaldrive")
                        }
                    } header: {
                        SectionTitle(tr("Проводник")) {
                            Text(tr("Вся файловая система: домашняя папка, диски и карты памяти. Клик — карточка папки, «Сканировать» — в «Съёмки»."))
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: lib.browser.revealTarget) { _, t in
                    // Rows deep in the tree appear as their parents load; try again once they have.
                    guard let t else { return }
                    for delay in [0.15, 0.6, 1.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            withAnimation { proxy.scrollTo(t, anchor: .center) }
                        }
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for p in providers {
                        if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                    }
                    let n = lib.browser.addFavorites(urls)
                    if n > 0 { lib.flash(tr("В «Избранное»: \(n)")) }
                }
                return true
            }
            .overlay {
                if dropTarget {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                        .overlay(alignment: .bottom) {
                            Text(tr("Отпустите — папка попадёт в «Избранное»")).font(.caption).padding(8)
                                .floatingBar(RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
                        }
                        .allowsHitTesting(false)
                }
            }
            if let s = lib.browser.selected {
                Divider()
                SelectedFolderCard(url: s)
            }
        }
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
}

/// Section header with a ⋯ menu that says what the section is and what you can do with it.
struct SectionTitle<Items: View>: View {
    let title: String
    @ViewBuilder let items: Items

    init(_ title: String, @ViewBuilder items: () -> Items) {
        self.title = title
        self.items = items()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer(minLength: 4)
            Menu { items } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tr("Что это и как настроить"))
        }
    }
}

/// A shoot: one click opens it where you stopped; the bar shows how much is decided,
/// the caption says where the folder is and whether it was gathered with its subfolders.
/// Subfolders sit under the triangle: a click on one shows its card, so it can become a shoot of its own.
struct ShootRow: View {
    let url: URL
    @Environment(Library.self) private var lib
    @State private var hover = false
    @State private var expanded = false
    @State private var children: [URL]?

    var body: some View {
        Group {
            if let children, !children.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children, id: \.self) { FolderRow(url: $0) }
                } label: { row }
            } else {
                row
            }
        }
        // Again when its drive comes back.
        .task(id: [url.path, available ? "on" : "off"]) {
            let u = url
            children = await Task.detached(priority: .utility) { FolderBrowser.subfolders(of: u) }.value
        }
    }

    private var available: Bool { lib.browser.isAvailable(url) }
    private static var unavailableHint: String { tr("Папка недоступна: диск не подключён или папка перемещена") }

    private var row: some View {
        let isOpen = lib.folder?.standardizedFileURL == url.standardizedFileURL
        let p = progress(isOpen)
        let fav = lib.browser.isFavorite(url)
        let whole = isOpen ? lib.includeSubfolders : (FolderState.load(url)?.recursive ?? false)
        let available = isOpen || self.available
        return Button {
            if isOpen { return }
            // The last check may be old: ask the disk now, on the click.
            if available || FolderBrowser.reachable(url) {
                if !available { lib.browser.refreshAvailability() }
                lib.open(url)
            } else {
                lib.flash(Self.unavailableHint, seconds: 2)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "folder.fill" : "folder")
                        .foregroundStyle(isOpen ? Color.accentColor : .secondary).frame(width: 16)
                    Text(FolderBrowser.displayName(url)).lineLimit(1).truncationMode(.middle)
                        .fontWeight(isOpen ? .semibold : .regular)
                    Spacer(minLength: 4)
                    if hover {
                        Button { lib.browser.removeShoot(url) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).font(.caption)
                        .help(tr("Убрать из съёмок (файлы остаются на месте)"))
                    } else if let f = p.fraction {
                        Text(f >= 1 ? "✓" : "\(Int(f * 100))%").font(.caption.monospacedDigit())
                            .foregroundStyle(f >= 1 ? .green : .secondary)
                    }
                }
                if let f = p.fraction {
                    ProgressView(value: min(f, 1)).progressViewStyle(.linear).controlSize(.mini)
                        .tint(f >= 1 ? .green : .accentColor)
                        .padding(.leading, 22)
                }
                HStack(spacing: 4) {
                    if !available {
                        Image(systemName: "externaldrive.badge.xmark").help(Self.unavailableHint)
                    }
                    if whole {
                        Image(systemName: "square.stack.3d.down.right").help(tr("Собрана вместе с подпапками"))
                    }
                    Text(FolderBrowser.shortPath(url)).lineLimit(1).truncationMode(.head).layoutPriority(-1)
                    if let d = p.done { Spacer(minLength: 2); Text(d).monospacedDigit().fixedSize() }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
            .padding(.vertical, 2)
            // Kept with its progress until the drive is back, just greyed out.
            .opacity(available ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(url.path + (whole ? "\n" + tr("Собрана вместе с подпапками") : "") + (available ? "" : "\n" + Self.unavailableHint))
        .contextMenu {
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(!available)
            Button(tr("Показать в проводнике")) { lib.browser.reveal(url) }.disabled(!available)
            Button(fav ? tr("Убрать из избранного") : tr("Добавить в избранное")) { lib.browser.toggleFavorite(url) }
            Divider()
            Button(whole ? tr("Пересканировать только эту папку") : tr("Пересканировать с подпапками")) { lib.scan(url, recursive: !whole) }
                .disabled(!available)
            Divider()
            Button(tr("Убрать из съёмок")) { lib.browser.removeShoot(url) }
        }
    }

    /// Live numbers for the open folder, the ones saved when it was left for the rest.
    private func progress(_ isOpen: Bool) -> (fraction: Double?, done: String?) {
        var total = 0, done = 0
        if isOpen, !lib.photos.isEmpty {
            let d = lib.decided
            total = lib.photos.count; done = d.kept + d.rejected
        } else if let s = FolderState.load(url), let t = s.total, t > 0 {
            total = t; done = (s.kept ?? 0) + (s.rejected ?? 0)
        }
        guard total > 0 else { return (nil, nil) }
        return (Double(done) / Double(total), tr("\(done) из \(total)"))
    }
}

/// A bookmark: flat, no tree of its own. A click unfolds the explorer down to it and shows its card.
struct FavoriteRow: View {
    let url: URL
    var icon = "folder"
    @Environment(Library.self) private var lib

    var body: some View {
        let isSelected = lib.browser.selected?.standardizedFileURL == url.standardizedFileURL
        Button { lib.browser.reveal(url) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(FolderBrowser.displayName(url)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 1).padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Открыть это место в «Проводнике»") + "\n" + url.path)
        .contextMenu {
            Button(tr("Показать в проводнике")) { lib.browser.reveal(url) }
            Button(tr("Сканировать")) { lib.scan(url) }
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(tr("Убрать из избранного")) { lib.browser.toggleFavorite(url) }
        }
    }
}

/// A camera card: how many photos are new, and Import right in the row.
struct CardRow: View {
    let url: URL
    @Environment(Library.self) private var lib

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sdcard.fill").foregroundStyle(Color.accentColor).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(FolderBrowser.displayName(url)).lineLimit(1)
                Group {
                    if let n = lib.browser.newOnCard[url] {
                        Text(n == 0 ? tr("Всё уже импортировано") : tr("Новых: \(n)"))
                    } else {
                        Text(tr("Считаю новые…"))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(tr("Импорт")) {
                lib.importer.scan(url)
                lib.showImport = true
            }
            .controlSize(.small)
        }
        .contextMenu {
            Button(tr("Сканировать как папку")) { lib.scan(url, recursive: true) }
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// The folder selected in the tree: where it is, what's inside (here and in subfolders), how far
/// culling got, and how to scan it: this folder alone, or together with its subfolders.
struct SelectedFolderCard: View {
    let url: URL
    @Environment(Library.self) private var lib
    @State private var info: (here: Int, deep: Int, folders: Int)?
    private nonisolated static let deepCap = 5000

    var body: some View {
        let isOpen = lib.folder?.standardizedFileURL == url.standardizedFileURL
        let isShoot = lib.browser.isShoot(url)
        let card = lib.browser.card(containing: url)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card == url ? "sdcard.fill" : "folder.fill").foregroundStyle(Color.accentColor)
                Text(FolderBrowser.displayName(url)).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { lib.browser.selected = nil } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Закрыть"))
            }
            Text(FolderBrowser.shortPath(url)).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).help(url.path)
            Group {
                if let info {
                    let deep = info.deep >= Self.deepCap ? "\(Self.deepCap)+" : "\(info.deep)"
                    Text(tr("Здесь: \(info.here)")
                         + (info.folders > 0 ? tr(" · в подпапках: \(deep) · подпапок: \(info.folders)") : ""))
                } else {
                    Text(tr("Считаю…"))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let s = FolderState.load(url), let p = s.progress {
                ProgressView(value: min(p, 1)) {
                    Text(tr("Решено \((s.kept ?? 0) + (s.rejected ?? 0)) из \(s.total ?? 0)")).font(.caption2).foregroundStyle(.secondary)
                }
                .controlSize(.mini)
            }
            if isOpen {
                Text(tr("Открыта сейчас") + (lib.includeSubfolders ? tr(" · с подпапками") : "")).font(.caption).foregroundStyle(.secondary)
            }
            // On a camera card the usual way is to copy the photos off it first; browsing and scanning
            // in place stay possible (a card is a drive like any other). Its own row: three buttons
            // do not fit a narrow sidebar.
            if let card {
                Button(tr("Импорт с карты…")) { lib.importer.scan(card); lib.showImport = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help(tr("Скопировать новые снимки с карты на диск с проверкой, как через ⌘I"))
            }
            HStack(spacing: 6) {
                if isOpen {
                    Button(tr("Открыта")) {}.disabled(true)
                } else if isShoot {
                    Button(tr("Открыть")) { lib.open(url); lib.browser.selected = nil }
                        .buttonStyle(.borderedProminent)
                        .help(tr("Папка уже в «Съёмках»"))
                } else {
                    let hereEmpty = info.map { $0.here == 0 } ?? false
                    let hasDeep = info.map { $0.folders > 0 && $0.deep > 0 } ?? false
                    Button(tr("Сканировать")) { lib.scan(url, recursive: false); lib.browser.selected = nil }
                        .prominent(card == nil && !(hereEmpty && hasDeep))
                        .disabled(info != nil && hereEmpty)
                        .help(tr("Только снимки из этой папки → в «Съёмки»"))
                    if hasDeep {
                        Button(tr("С подпапками")) { lib.scan(url, recursive: true); lib.browser.selected = nil }
                            .prominent(card == nil && hereEmpty)
                            .help(tr("Снимки из этой папки и всех вложенных одним списком → в «Съёмки»"))
                    }
                }
                Button { lib.browser.toggleFavorite(url) } label: {
                    Image(systemName: lib.browser.isFavorite(url) ? "star.fill" : "star")
                }
                .help(lib.browser.isFavorite(url) ? tr("Убрать из избранного") : tr("Добавить в избранное"))
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(12)
        .task(id: url) {
            info = nil
            let u = url
            info = await Task.detached(priority: .utility) {
                let folders = FolderBrowser.subfolders(of: u).count
                return (FolderBrowser.photoCount(in: u), folders > 0 ? FolderBrowser.deepPhotoCount(in: u, cap: Self.deepCap) : 0, folders)
            }.value
        }
    }
}

private extension View {
    /// The recommended of two buttons is the prominent one.
    @ViewBuilder func prominent(_ yes: Bool) -> some View {
        if yes { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}
