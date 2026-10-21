import AppKit
import Observation
import SwiftUI

/// Where photos come from, in three layers:
/// - `shoots` — the working folders. A folder gets here only when you press "Scan" (or import a card);
///   opening a shoot never adds anything. Newest on top, reordered by hand.
/// - `favorites` — bookmarks into the file system: places you go to pick the next shoot.
/// - the explorer — home, drives, cards: the whole file system, for finding a folder and scanning it.
@MainActor
@Observable
final class FolderBrowser {
    var favorites: [URL] = []
    var shoots: [URL] = []
    var volumes: [URL] = []
    /// Folder highlighted in the sidebar tree: one click selects, a double click or "Open" opens it.
    var selected: URL?
    /// Photos on each camera card that haven't been imported yet (nil while counting).
    var newOnCard: [URL: Int] = [:]

    var cards: [URL] { volumes.filter { CardImporter.isCameraCard($0) } }
    var drives: [URL] { volumes.filter { !CardImporter.isCameraCard($0) } }
    /// Called when a new camera card is connected (has DCIM at the root).
    var onCardMounted: ((URL) -> Void)?
    private var scannedOnce = false

    private let favKey = "favoriteFolders", shootsKey = "shoots", recentKey = "recentFolders"
    static let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        let home = Self.home
        if let saved = UserDefaults.standard.stringArray(forKey: favKey) {
            favorites = saved.map { URL(fileURLWithPath: $0) }
        } else {
            favorites = ["Pictures", "Documents/Фотосессии"]
                .map { home.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let saved = UserDefaults.standard.stringArray(forKey: shootsKey) {
            shoots = saved.map { URL(fileURLWithPath: $0) }
        } else {
            // First launch of the three-layer sidebar: the old "Continue" list becomes the shoots,
            // so no progress is lost; the system folders the old favorites started with go away.
            shoots = (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).map { URL(fileURLWithPath: $0) }
            let system = Set(["Desktop", "Downloads"].map { home.appendingPathComponent($0).standardizedFileURL })
            favorites.removeAll { system.contains($0.standardizedFileURL) }
            UserDefaults.standard.set(favorites.map(\.path), forKey: favKey)
            UserDefaults.standard.set(shoots.map(\.path), forKey: shootsKey)
        }
        shoots = shoots.filter { FileManager.default.fileExists(atPath: $0.path) }
        refreshVolumes()
        // A memory card or drive was inserted; the list updates by itself.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }
    }

    func refreshVolumes() {
        let before = Set(volumes)
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return v?.volumeIsRootFileSystem != true && v?.volumeIsBrowsable != false
            }
        for c in cards where newOnCard[c] == nil {
            Task {
                let n = await Task.detached(priority: .utility) { CardImporter.newCount(on: c) }.value
                newOnCard[c] = n
            }
        }
        newOnCard = newOnCard.filter { volumes.contains($0.key) }
        // Cards already inserted at launch don't trigger the banner; only new connections do.
        if scannedOnce {
            for v in volumes where !before.contains(v) && CardImporter.isCameraCard(v) { onCardMounted?(v) }
        }
        scannedOnce = true
    }

    func isShoot(_ u: URL) -> Bool { shoots.contains { $0.standardizedFileURL == u.standardizedFileURL } }

    /// A new shoot goes on top; one already in the list stays where you put it.
    func addShoot(_ u: URL) {
        guard !isShoot(u) else { return }
        shoots.insert(u, at: 0)
        UserDefaults.standard.set(shoots.map(\.path), forKey: shootsKey)
    }

    func removeShoot(_ u: URL) {
        shoots.removeAll { $0.standardizedFileURL == u.standardizedFileURL }
        UserDefaults.standard.set(shoots.map(\.path), forKey: shootsKey)
    }

    func moveShoots(from: IndexSet, to: Int) {
        shoots.move(fromOffsets: from, toOffset: to)
        UserDefaults.standard.set(shoots.map(\.path), forKey: shootsKey)
    }

    /// Forgets every shoot except the open one.
    func clearShoots(keeping open: URL?) {
        shoots = shoots.filter { r in open.map { $0.standardizedFileURL == r.standardizedFileURL } ?? false }
        UserDefaults.standard.set(shoots.map(\.path), forKey: shootsKey)
    }

    /// Roots of the explorer: home first, then the drives (cards have their own section).
    var explorerRoots: [URL] { [Self.home] + drives }

    /// Selects a folder in the sidebar (the card shows it) and makes sure the explorer is unfolded.
    func reveal(_ u: URL) {
        UserDefaults.standard.set(true, forKey: "sb.explorer")
        selected = u
    }

    func isFavorite(_ u: URL) -> Bool { favorites.contains { $0.standardizedFileURL == u.standardizedFileURL } }

    func toggleFavorite(_ u: URL) {
        if isFavorite(u) { favorites.removeAll { $0.standardizedFileURL == u.standardizedFileURL } } else { favorites.append(u) }
        UserDefaults.standard.set(favorites.map(\.path), forKey: favKey)
    }

    /// Adds folders (files are ignored, duplicates too). Returns how many were added.
    @discardableResult
    func addFavorites(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls where !isFavorite(u) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            favorites.append(u); n += 1
        }
        if n > 0 { UserDefaults.standard.set(favorites.map(\.path), forKey: favKey) }
        return n
    }

    func moveFavorites(from: IndexSet, to: Int) {
        favorites.move(fromOffsets: from, toOffset: to)
        UserDefaults.standard.set(favorites.map(\.path), forKey: favKey)
    }

    /// Lets the user pick a folder for the favorites list without opening it.
    func chooseFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = tr("Добавить")
        panel.message = tr("Выберите папки для «Избранного»")
        if panel.runModal() == .OK { addFavorites(panel.urls) }
    }

    static func displayName(_ u: URL) -> String {
        if u.path == FileManager.default.homeDirectoryForCurrentUser.path { return tr("Домой") }
        return (try? u.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? u.lastPathComponent
    }

    /// Where the folder lives, short: "~/Pictures/пляж" or "/Volumes/Extreme SSD/Inbox".
    static func shortPath(_ u: URL) -> String {
        let p = u.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    /// Subfolders, excluding hidden ones, packages (.app, .photoslibrary) and system folders.
    nonisolated static func subfolders(of u: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        return ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [])
            .filter { c in
                let v = try? c.resourceValues(forKeys: keys)
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Number of photos directly in the folder (not in subfolders).
    nonisolated static func photoCount(in u: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? [])
            .filter { ImageStore.rawExtensions.contains(($0 as NSString).pathExtension.lowercased()) || ImageStore.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .count
    }
}

/// Folder row in the tree: a click selects it (the card below says what's inside and offers Scan),
/// the disclosure triangle shows subfolders. Nothing here scans by itself.
struct FolderRow: View {
    let url: URL
    var title: String?
    var icon = "folder"
    @Environment(Library.self) private var lib
    @State private var expanded = false
    @State private var children: [URL]?
    @State private var count: Int?

    var body: some View {
        Group {
            if let children, children.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children ?? [], id: \.self) { FolderRow(url: $0) }
                } label: { label }
            }
        }
        .task(id: url) {
            let u = url
            let (c, n) = await Task.detached(priority: .utility) { (FolderBrowser.subfolders(of: u), FolderBrowser.photoCount(in: u)) }.value
            children = c
            count = n
        }
    }

    private var isCurrent: Bool { lib.folder?.standardizedFileURL == url.standardizedFileURL }

    private var isSelected: Bool { lib.browser.selected?.standardizedFileURL == url.standardizedFileURL }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(title ?? FolderBrowser.displayName(url))
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1).padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { expanded.toggle() }
        .onTapGesture { lib.browser.selected = url }
        .help(url.path)
        .contextMenu {
            Button(isCurrent ? tr("Открыта") : tr("Сканировать")) { lib.scan(url) }.disabled(isCurrent)
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(lib.browser.isFavorite(url) ? tr("Убрать из избранного") : tr("Добавить в избранное")) { lib.browser.toggleFavorite(url) }
        }
    }
}
