import AppKit

/// Checks GitHub releases for a newer version: at launch at most once a day (Settings can turn it off),
/// or from the menu. Stable builds are offered stable releases only; beta builds also get newer betas.
/// Nothing is downloaded or installed automatically: the release page opens in the browser.
@MainActor
enum Updater {
    static let api = URL(string: "https://api.github.com/repos/araoijj/kadr/releases?per_page=30")!
    private static let lastKey = "upd.last"
    private static let skipKey = "upd.skip"

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    struct Release {
        let version: String
        let page: URL
        let prerelease: Bool
    }

    static func checkAtLaunch() {
        // A bare binary (swift build) has no bundle version: any release would look newer.
        guard Prefs.checkUpdates, Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(manual: false) }
    }

    static func check(manual: Bool) async {
        guard let r = await newest() else {
            if manual { alert(tr("Не удалось проверить обновления"), tr("Нет связи с GitHub. Попробуйте позже.")) }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        guard Version(r.version) > Version(current) else {
            if manual { alert(tr("У вас последняя версия"), tr("«Кадр» \(current) — новее на GitHub нет.")) }
            return
        }
        if !manual, UserDefaults.standard.string(forKey: skipKey) == r.version { return }
        let a = NSAlert()
        a.messageText = tr("Вышла новая версия «Кадра»: \(r.version)")
        a.informativeText = tr("У вас \(current). Скачайте архив со страницы выпуска и замените приложение — оценки, правки и настройки сохранятся.")
            + (r.prerelease ? "\n\n" + tr("Это бета-версия.") : "")
        a.addButton(withTitle: tr("Открыть страницу загрузки"))
        a.addButton(withTitle: tr("Позже"))
        a.addButton(withTitle: tr("Пропустить эту версию"))
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.page)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: skipKey)
        default: break
        }
    }

    /// The newest app release for this channel (model packages and drafts are skipped).
    static func newest() async -> Release? {
        var req = URLRequest(url: api, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let beta = Version(current).pre != nil
        let all: [Release] = list.compactMap { o in
            guard let tag = o["tag_name"] as? String, tag.hasPrefix("v"), o["draft"] as? Bool != true,
                  let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let pre = o["prerelease"] as? Bool ?? false
            if pre && !beta { return nil }
            return Release(version: String(tag.dropFirst()), page: page, prerelease: pre)
        }
        return all.max { Version($0.version) < Version($1.version) }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// "1.2.0-beta1": numbers, then an optional pre-release suffix that sorts before the release itself.
struct Version: Comparable {
    let nums: [Int]
    let pre: String?

    init(_ s: String) {
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        nums = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        pre = parts.count > 1 ? parts[1] : nil
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.nums.count, b.nums.count) {
            let x = i < a.nums.count ? a.nums[i] : 0, y = i < b.nums.count ? b.nums[i] : 0
            if x != y { return x < y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (p?, q?): return p.localizedStandardCompare(q) == .orderedAscending
        }
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
