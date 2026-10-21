import SwiftUI
import UniformTypeIdentifiers

/// Left panel: where the photos come from. Filters are in the bar above the photos (FilterBar),
/// so opening a folder and narrowing it down never needs a tab switch.
///
/// «Продолжить» fills itself with the folders you open (newest first) and shows culling progress;
/// «Избранное» is yours: the ⋯ menu, the context menu, a ★ on a recent folder or a drop from Finder add to it.
struct Sidebar: View {
    @Environment(Library.self) private var lib
    @AppStorage("sb.continue") private var showContinue = true
    @AppStorage("sb.cards") private var showCards = true
    @AppStorage("sb.favorites") private var showFavorites = true
    @AppStorage("sb.drives") private var showDrives = true
    @AppStorage("sb.recentShown") private var recentShown = 6
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(isExpanded: $showContinue) {
                    if lib.browser.recent.isEmpty {
                        Text(tr("Здесь появятся папки, которые вы открывали, — с прогрессом отбора."))
                            .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                    }
                    ForEach(lib.browser.recent.prefix(recentShown), id: \.self) { RecentRow(url: $0) }
                } header: {
                    SectionTitle(tr("Продолжить")) {
                        Text(tr("Папки, которые вы открывали, новые сверху. Клик — продолжить с места, где остановились."))
                        Picker(tr("Показывать"), selection: $recentShown) {
                            ForEach([4, 6, 8, 12], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Divider()
                        Button(tr("Очистить список")) { lib.browser.clearRecent(keeping: lib.folder) }
                            .disabled(lib.browser.recent.isEmpty)
                    }
                }
                if !lib.browser.cards.isEmpty {
                    Section(tr("Карты памяти"), isExpanded: $showCards) {
                        ForEach(lib.browser.cards, id: \.self) { CardRow(url: $0) }
                    }
                }
                Section(isExpanded: $showFavorites) {
                    ForEach(lib.browser.favorites, id: \.self) { FolderRow(url: $0, icon: icon(for: $0)) }
                        .onMove { lib.browser.moveFavorites(from: $0, to: $1) }
                    Button { lib.chooseFolder() } label: {
                        Label(tr("Другая папка…"), systemImage: "folder.badge.plus").foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                } header: {
                    SectionTitle(tr("Избранное")) {
                        Text(tr("Ваши папки: ★ у недавней папки, правая кнопка в дереве или перетащите папку из Finder сюда."))
                        Button(tr("Добавить папку…")) { lib.browser.chooseFavorite() }
                    }
                }
                if !lib.browser.drives.isEmpty {
                    Section(tr("Диски"), isExpanded: $showDrives) {
                        ForEach(lib.browser.drives, id: \.self) { FolderRow(url: $0, icon: "externaldrive") }
                    }
                }
            }
            .listStyle(.sidebar)
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

/// A folder you worked on: one click opens it where you stopped; the bar shows how much is decided,
/// the caption says where the folder is (two shoots can share a name). Subfolders open under the triangle.
struct RecentRow: View {
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
        .task(id: url) {
            let u = url
            children = await Task.detached(priority: .utility) { FolderBrowser.subfolders(of: u) }.value
        }
    }

    private var row: some View {
        let isOpen = lib.folder?.standardizedFileURL == url.standardizedFileURL
        let p = progress(isOpen)
        let fav = lib.browser.isFavorite(url)
        return Button { if !isOpen { lib.open(url) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "folder.fill" : "folder")
                        .foregroundStyle(isOpen ? Color.accentColor : .secondary).frame(width: 16)
                    Text(FolderBrowser.displayName(url)).lineLimit(1).truncationMode(.middle)
                        .fontWeight(isOpen ? .semibold : .regular)
                    Spacer(minLength: 4)
                    if hover {
                        HStack(spacing: 2) {
                            Button { lib.browser.toggleFavorite(url) } label: {
                                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? Theme.star : .secondary)
                            }
                            .help(fav ? tr("Убрать из избранного") : tr("Добавить в избранное"))
                            Button { lib.browser.removeRecent(url) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .help(tr("Убрать из списка"))
                            .disabled(isOpen)
                        }
                        .buttonStyle(.plain).font(.caption)
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
                HStack(spacing: 6) {
                    Text(FolderBrowser.shortPath(url)).lineLimit(1).truncationMode(.head).layoutPriority(-1)
                    if let d = p.done { Spacer(minLength: 2); Text(d).monospacedDigit().fixedSize() }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(url.path)
        .contextMenu {
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(fav ? tr("Убрать из избранного") : tr("Добавить в избранное")) { lib.browser.toggleFavorite(url) }
            Divider()
            Button(tr("Убрать из списка")) { lib.browser.removeRecent(url) }.disabled(isOpen)
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
            Button(tr("Открыть как папку")) { lib.open(url) }
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// The folder selected in the tree: where it is, what's inside, how far culling got, and Open.
struct SelectedFolderCard: View {
    let url: URL
    @Environment(Library.self) private var lib
    @State private var info: (photos: Int, folders: Int)?

    var body: some View {
        @Bindable var lib = lib
        let isOpen = lib.folder?.standardizedFileURL == url.standardizedFileURL
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(FolderBrowser.displayName(url)).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { lib.browser.selected = nil } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Закрыть"))
            }
            Text(FolderBrowser.shortPath(url)).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).help(url.path)
            Group {
                if let info {
                    Text(tr("Фото: \(info.photos)") + (info.folders > 0 ? tr(" · подпапок: \(info.folders)") : ""))
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
            Toggle(tr("С вложенными папками"), isOn: $lib.includeSubfolders)
                .toggleStyle(.checkbox).font(.caption)
                .help(tr("Показывать снимки из всех подпапок"))
            HStack {
                Button(isOpen ? tr("Открыта") : tr("Открыть")) { lib.open(url); lib.browser.selected = nil }
                    .buttonStyle(.borderedProminent).disabled(isOpen)
                Button { lib.browser.toggleFavorite(url) } label: {
                    Image(systemName: lib.browser.isFavorite(url) ? "star.fill" : "star")
                }
                .help(lib.browser.isFavorite(url) ? tr("Убрать из избранного") : tr("Добавить в избранное"))
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(12)
        .task(id: url) {
            info = nil
            let u = url
            info = await Task.detached(priority: .utility) { (FolderBrowser.photoCount(in: u), FolderBrowser.subfolders(of: u).count) }.value
        }
    }
}
