import Foundation

/// Перевод интерфейса. Исходный язык — русский; словари en/es/it — в Translations.swift.
/// tr() принимает уже собранную строку: точное совпадение или шаблон с {} на месте подстановок
/// («Выделено {}» → «Selected {}»), поэтому строки с числами и именами переводятся без доработки кода.
enum I18n {
    static let supported = ["ru", "en", "es", "it"]

    /// Даты — на языке интерфейса, а не системы.
    static let locale = Locale(identifier: lang)

    /// Название приложения: по-русски «Кадр», на других языках — Kadr. («Кадр» в словаре — это «кадр» фотографии.)
    static var appName: String { lang == "ru" ? "Кадр" : "Kadr" }

    /// Язык выбирается при запуске: из настроек или системы (неизвестный системный — английский).
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

    /// Шаблоны с подстановками: длинные (точнее) — первыми.
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

    /// {} — по порядку, {1} {2} — по номеру (если в переводе другой порядок слов).
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

/// Перевести строку интерфейса.
@inline(__always) func tr(_ s: String) -> String { I18n.translate(s) }
