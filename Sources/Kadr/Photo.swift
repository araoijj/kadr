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
        case .red: "Красный"
        case .yellow: "Жёлтый"
        case .green: "Зелёный"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        }
    }

    /// Клавиши 6–9 как в Lightroom / Capture One.
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
        if let focal { parts.append("\(Int(focal.rounded())) мм") }
        if let aperture { parts.append(String(format: "f/%.1f", aperture)) }
        if let shutter {
            parts.append(shutter >= 1 ? String(format: "%.1f с", shutter) : "1/\(Int((1 / shutter).rounded())) с")
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
    var mtime: Double = 0        // время изменения файла — для сверки с индексом

    var rating: Int = 0          // 0…5
    var rejected: Bool = false   // в XMP хранится как Rating = -1
    var label: ColorLabel?
    var adj = Adjustments()      // обработка (хранится в .kadr/edits.json)

    var exif = ExifInfo()
    var hash: UInt64?            // dHash превью — для поиска похожих
    var sharpness: Double?       // дисперсия лапласиана, больше — резче
    var seriesID: Int?           // номер серии похожих кадров
    var isBestInSeries = false
    var duplicateOf: URL?        // точная копия другого файла
    var indexed = false          // анализ есть (из индекса или посчитан сейчас)

    var lensName: String { exif.lens?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Объектив не указан" }
    var day: Date? { exif.date.map { Calendar.current.startOfDay(for: $0) } }
}

enum SortKey: String, CaseIterable {
    case date, name, rating, lens, folder, size
    var title: String {
        switch self {
        case .date: "Время съёмки"
        case .name: "Имя файла"
        case .rating: "Оценка"
        case .lens: "Объектив"
        case .folder: "Папка"
        case .size: "Размер файла"
        }
    }
}

enum GroupKey: String, CaseIterable {
    case none, day, folder, lens, rating
    var title: String {
        switch self {
        case .none: "Без группировки"
        case .day: "По дням"
        case .folder: "По папкам"
        case .lens: "По объективам"
        case .rating: "По оценке"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
