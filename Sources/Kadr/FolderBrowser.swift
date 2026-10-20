import AppKit
import Observation
import SwiftUI

/// File system access: favorite and recent folders, connected drives and memory cards.
@MainActor
@Observable
final class FolderBrowser {
    var favorites: [URL] = []
    var recent: [URL] = []
    var volumes: [URL] = []
    /// Called when a new camera card is connected (has DCIM at the root).
    var onCardMounted: ((URL) -> Void)?
    private var scannedOnce = false

    private let favKey = "favoriteFolders", recentKey = "recentFolders"

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let saved = UserDefaults.standard.stringArray(forKey: favKey) {
            favorites = saved.map { URL(fileURLWithPath: $0) }
        } else {
            favorites = ["Pictures", "Documents/Фотосессии", "Desktop", "Downloads"]
                .map { home.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        recent = (UserDefaults.standard.stringArray(forKey: recentKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
        // Cards already inserted at launch don't trigger the banner; only new connections do.
        if scannedOnce {
            for v in volumes where !before.contains(v) && CardImporter.isCameraCard(v) { onCardMounted?(v) }
        }
        scannedOnce = true
    }

    func addRecent(_ u: URL) {
        recent.removeAll { $0.standardizedFileURL == u.standardizedFileURL }
        recent.insert(u, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent.map(\.path), forKey: recentKey)
    }

    func isFavorite(_ u: URL) -> Bool { favorites.contains { $0.standardizedFileURL == u.standardizedFileURL } }

    func toggleFavorite(_ u: URL) {
        if isFavorite(u) { favorites.removeAll { $0.standardizedFileURL == u.standardizedFileURL } } else { favorites.append(u) }
        UserDefaults.standard.set(favorites.map(\.path), forKey: favKey)
    }

    static func displayName(_ u: URL) -> String {
        if u.path == FileManager.default.homeDirectoryForCurrentUser.path { return tr("Домой") }
        return (try? u.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? u.lastPathComponent
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

/// Folder row in the tree: click to open, disclosure triangle to show subfolders.
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

    private var label: some View {
        Button { lib.open(url) } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            Button(tr("Открыть")) { lib.open(url) }
            Button(tr("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(lib.browser.isFavorite(url) ? tr("Убрать из избранного") : tr("Добавить в избранное")) { lib.browser.toggleFavorite(url) }
        }
    }
}
