import Foundation
import SwiftUI

enum ColorLabel: String, CaseIterable, Identifiable, Codable {
    case red = "Red", yellow = "Yellow", green = "Green", blue = "Blue", purple = "Purple"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: Color(red: 0.93, green: 0.33, blue: 0.31)
        case .yellow: Color(red: 0.96, green: 0.78, blue: 0.26)
        case .green: Color(red: 0.36, green: 0.78, blue: 0.47)
        case .blue: Color(red: 0.33, green: 0.58, blue: 0.96)
        case .purple: Color(red: 0.69, green: 0.45, blue: 0.93)
        }
    }

    var title: String {
        switch self {
        case .red: tr("Красный")
        case .yellow: tr("Жёлтый")
        case .green: tr("Зелёный")
        case .blue: tr("Синий")
        case .purple: tr("Фиолетовый")
        }
    }

    /// Keys 6–9, as in Lightroom / Capture One.
    static func forKey(_ key: Int) -> ColorLabel? {
        switch key {
        case 6: .red
        case 7: .yellow
        case 8: .green
        case 9: .blue
        default: nil
        }
    }
}

struct ExifInfo: Equatable, Codable, Sendable {
    var date: Date?
    var camera: String?
    var lens: String?
    var iso: Int?
    var shutter: Double?
    var aperture: Double?
    var focal: Double?
    var width: Int?
    var height: Int?

    var exposureLine: String {
        var parts: [String] = []
        if let focal { parts.append(tr("\(Int(focal.rounded())) мм")) }
        if let aperture { parts.append(String(format: "f/%.1f", aperture)) }
        if let shutter {
            parts.append(shutter >= 1 ? String(format: tr("%.1f с"), shutter) : tr("1/\(Int((1 / shutter).rounded())) с"))
        }
        if let iso { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ·  ")
    }
}

struct Photo: Identifiable, Equatable {
    let id: URL
    var url: URL { id }
    var name: String { id.lastPathComponent }
    var fileSize: Int64
    var mtime: Double = 0        // file modification time, for checking against the index

    var rating: Int = 0          // 0…5
    var rejected: Bool = false   // stored in XMP as Rating = -1
    var label: ColorLabel?
    var adj = Adjustments()      // edits (stored in .kadr/edits.json)

    var exif = ExifInfo()
    var hash: UInt64?            // preview dHash, for finding similar photos
    var sharpness: Double?       // variance of the Laplacian; higher is sharper
    var seriesID: Int?           // series number of similar photos
    var isBestInSeries = false
    var duplicateOf: URL?        // exact copy of another file
    var indexed = false          // analysis exists (from the index or computed just now)
    var cull: CullData?          // culling data (CullAnalysis.swift)
    var sceneID: Int?            // scene: part of a shoot without long pauses (Scenes.swift)

    var lensName: String { exif.lens?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? tr("Объектив не указан") }
    /// Capture time; until EXIF is read (first indexing of a folder) the file time stands in, so the order
    /// by time is stable from the first second instead of reshuffling as the index fills in.
    var takenAt: Date { exif.date ?? Date(timeIntervalSince1970: mtime) }
    var day: Date? { exif.date.map { Calendar.current.startOfDay(for: $0) } }
}

enum SortKey: String, CaseIterable {
    case date, name, rating, lens, folder, size
    var title: String {
        switch self {
        case .date: tr("Время съёмки")
        case .name: tr("Имя файла")
        case .rating: tr("Оценка")
        case .lens: tr("Объектив")
        case .folder: tr("Папка")
        case .size: tr("Размер файла")
        }
    }
}

enum GroupKey: String, CaseIterable {
    case none, day, scene, folder, lens, rating
    var title: String {
        switch self {
        case .none: tr("Без группировки")
        case .scene: tr("По сценам")
        case .day: tr("По дням")
        case .folder: tr("По папкам")
        case .lens: tr("По объективам")
        case .rating: tr("По оценке")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
