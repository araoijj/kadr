import Foundation

/// Настройки приложения (окно «Настройки», ⌘,). Хранятся в UserDefaults; значения по умолчанию — щадящие.
enum Prefs {
    static let d = UserDefaults.standard

    private static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    // Общие
    static var language: String { d.string(forKey: "pref.language") ?? "system" }   // system, ru, en, es, it
    static var reopenLastFolder: Bool { bool("pref.reopenLast", true) }
    static var autoAdvance: Bool { bool("pref.autoAdvance", true) }
    static var cardBanner: Bool { bool("pref.cardBanner", true) }
    static var cullByDefault: Bool { bool("pref.cullDefault", false) }   // открывать папку в режиме «Отбор»
    static var sceneGapMinutes: Int { int("pref.sceneGap", 10) }         // новая сцена после паузы, минуты

    // Хранилище
    static var dataFolder: String? { d.string(forKey: "pref.dataFolder") }

    // Производительность и память
    static var analysisThreads: Int { int("pref.threads", 2) }          // 1…4
    static var thumbCache: Int { int("pref.thumbCache", 4000) }          // превью в памяти
    static var renderCache: Int { int("pref.renderCache", 4) }           // проявленных кадров в памяти

    // Журнал
    static var historyLimit: Int { int("pref.historyLimit", 100) }       // 25, 50, 100, 200
    static var historyKeep: Bool { bool("pref.historyKeep", true) }      // хранить между запусками

    // Индекс
    static var indexEnabled: Bool { bool("pref.indexEnabled", true) }
}
