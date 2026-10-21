import SwiftUI

/// Left panel: where the photos come from. Filters are in the bar above the photos (FilterBar),
/// so opening a folder and narrowing it down never needs a tab switch.
struct Sidebar: View {
    @Environment(Library.self) private var lib
    @AppStorage("sb.continue") private var showContinue = true
    @AppStorage("sb.cards") private var showCards = true
    @AppStorage("sb.favorites") private var showFavorites = true
    @AppStorage("sb.drives") private var showDrives = true

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section(tr("Продолжить"), isExpanded: $showContinue) {
                    if lib.browser.recent.isEmpty {
                        Text(tr("Здесь появятся папки, которые вы открывали, — с прогрессом отбора."))
                            .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                    }
                    ForEach(lib.browser.recent.prefix(6), id: \.self) { RecentRow(url: $0) }
                }
                if !lib.browser.cards.isEmpty {
                    Section(tr("Карты памяти"), isExpanded: $showCards) {
                        ForEach(lib.browser.cards, id: \.self) { CardRow(url: $0) }
                    }
                }
                Section(tr("Избранное"), isExpanded: $showFavorites) {
                    ForEach(lib.browser.favorites, id: \.self) { FolderRow(url: $0, icon: icon(for: $0)) }
                    Button { lib.chooseFolder() } label: {
                        Label(tr("Другая папка…"), systemImage: "folder.badge.plus").foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
                if !lib.browser.drives.isEmpty {
                    Section(tr("Диски"), isExpanded: $showDrives) {
                        ForEach(lib.browser.drives, id: \.self) { FolderRow(url: $0, icon: "externaldrive") }
                    }
                }
            }
            .listStyle(.sidebar)
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

/// A folder you worked on: one click opens it where you stopped; the bar shows how much is decided.
struct RecentRow: View {
    let url: URL
    @Environment(Library.self) private var lib

    var body: some View {
        let isOpen = lib.folder?.standardizedFileURL == url.standardizedFileURL
        let p = progress(isOpen)
        Button { if !isOpen { lib.open(url) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "folder.fill" : "folder")
                        .foregroundStyle(isOpen ? Color.accentColor : .secondary).frame(width: 16)
                    Text(FolderBrowser.displayName(url)).lineLimit(1).truncationMode(.middle)
                        .fontWeight(isOpen ? .semibold : .regular)
                    Spacer(minLength: 4)
                    if let f = p.fraction {
                        Text(f >= 1 ? "✓" : "\(Int(f * 100))%").font(.caption.monospacedDigit())
                            .foregroundStyle(f >= 1 ? .green : .secondary)
                    }
                }
                if let f = p.fraction {
                    ProgressView(value: min(f, 1)).progressViewStyle(.linear).controlSize(.mini)
                        .tint(f >= 1 ? .green : .accentColor)
                        .padding(.leading, 22)
                }
                Text(p.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .padding(.leading, 22)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(lib.browser.isFavorite(url) ? tr("Убрать из избранного") : tr("Добавить в избранное")) { lib.browser.toggleFavorite(url) }
            Divider()
            Button(tr("Убрать из списка")) { lib.browser.removeRecent(url) }.disabled(isOpen)
        }
    }

    /// Live numbers for the open folder, the ones saved when it was left for the rest.
    private func progress(_ isOpen: Bool) -> (fraction: Double?, text: String) {
        let parent = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        var total = 0, done = 0
        if isOpen, !lib.photos.isEmpty {
            let d = lib.decided
            total = lib.photos.count; done = d.kept + d.rejected
        } else if let s = FolderState.load(url), let t = s.total, t > 0 {
            total = t; done = (s.kept ?? 0) + (s.rejected ?? 0)
        }
        guard total > 0 else { return (nil, parent) }
        return (Double(done) / Double(total), tr("Решено \(done) из \(total)"))
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

/// The folder selected in the tree: what's inside, how far culling got, and Open.
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
