import Foundation

/// UI localization. The source language is Russian; the en/es/it dictionaries are in Translations.swift.
/// tr() takes an already-built string: an exact match or a template with {} in place of substitutions
/// ("Выделено {}" → "Selected {}"), so strings with numbers and names get translated without code changes.
enum I18n {
    static let supported = ["ru", "en", "es", "it"]

    /// Dates use the UI language, not the system one.
    static let locale = Locale(identifier: lang)

    /// App name: "Кадр" in Russian, Kadr in other languages. ("Кадр" in the dictionary is a photo "frame".)
    static var appName: String { lang == "ru" ? "Кадр" : "Kadr" }

    /// The language is chosen at launch: from settings or the system (an unknown system language falls back to English).
    static let lang: String = {
        let p = Prefs.language
        if p != "system", supported.contains(p) { return p }
        let sys = String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        return supported.contains(sys) ? sys : "en"
    }()

    static let table: [String: String] = {
        switch lang {
        case "en": Translations.en
        case "es": Translations.es
        case "it": Translations.it
        default: [:]
        }
    }()

    /// Templates with substitutions: longer (more specific) ones first.
    private static let templates: [(NSRegularExpression, String)] = table
        .filter { $0.key.contains("{}") && $0.key != "{}" }
        .sorted { $0.key.count > $1.key.count }
        .compactMap { k, v in
            let parts = k.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern(for:))
            guard let re = try? NSRegularExpression(pattern: "^" + parts.joined(separator: "(.+?)") + "$", options: [.dotMatchesLineSeparators]) else { return nil }
            return (re, v)
        }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func translate(_ s: String) -> String {
        guard lang != "ru", !s.isEmpty else { return s }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[s] { return c }
        var out = table[s]
        if out == nil {
            let ns = s as NSString
            for (re, v) in templates {
                guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
                let caps = (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
                out = fill(v, caps)
                break
            }
        }
        let r = out ?? s
        if cache.count > 5000 { cache.removeAll() }
        cache[s] = r
        return r
    }

    /// {} are filled in order, {1} {2} by index (when the translation uses a different word order).
    private static func fill(_ t: String, _ caps: [String]) -> String {
        var r = t
        for (i, c) in caps.enumerated() { r = r.replacingOccurrences(of: "{\(i + 1)}", with: c) }
        var i = 0
        while let range = r.range(of: "{}"), i < caps.count {
            r.replaceSubrange(range, with: caps[i]); i += 1
        }
        return r
    }
}

/// Translates a UI string.
@inline(__always) func tr(_ s: String) -> String { I18n.translate(s) }
