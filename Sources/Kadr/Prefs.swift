import Foundation

/// App preferences (the "Settings" window, ⌘,). Stored in UserDefaults; defaults are conservative.
enum Prefs {
    static let d = UserDefaults.standard

    private static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    // General
    static var language: String { d.string(forKey: "pref.language") ?? "system" }   // system, ru, en, es, it
    static var reopenLastFolder: Bool { bool("pref.reopenLast", true) }
    static var autoAdvance: Bool { bool("pref.autoAdvance", true) }
    static var cardBanner: Bool { bool("pref.cardBanner", true) }
    static var cullByDefault: Bool { bool("pref.cullDefault", false) }
    static var aiAuto: Bool { bool("pref.aiAuto", false) }               // run AI analysis automatically after indexing (otherwise via the button)   // open the folder in "Culling" mode
    static var sceneGapMinutes: Int { int("pref.sceneGap", 10) }         // new scene after a pause, minutes

    // Storage
    static var dataFolder: String? { d.string(forKey: "pref.dataFolder") }

    // Performance and memory
    static var analysisThreads: Int { int("pref.threads", 2) }          // 1…4
    /// Memory for decoded previews, MB; 0 — automatic (⅛ of RAM, 512 MB–4 GB).
    static var previewMB: Int { int("pref.previewMB", 0) }
    static var previewBytes: Int {
        previewMB > 0 ? previewMB * 1_048_576 : previewBytesAuto
    }
    static var previewBytesAuto: Int { min(4096, max(512, Int(ProcessInfo.processInfo.physicalMemory / 8 / 1_048_576))) * 1_048_576 }
    static var renderCache: Int { int("pref.renderCache", 4) }           // developed photos in memory

    // History
    static var historyLimit: Int { int("pref.historyLimit", 100) }       // 25, 50, 100, 200
    static var historyKeep: Bool { bool("pref.historyKeep", true) }      // keep between launches

    // Index
    static var indexEnabled: Bool { bool("pref.indexEnabled", true) }
}
