import Foundation

/// Ready-made recipes by collection. The parameters are tuned for Kadr: our own, not borrowed presets.
/// Film recipes use LUTs from the t3mujinpack collection (MIT) and appear once it's downloaded.
extension Style {
    static let builtIns: [Style] = basic + portrait + landscape + cinema + blackWhite + film

    static let basic: [Style] = [
        Style(tr("Тёплый свет"), "Базовые") { $0.wbShift = 750; $0.shadows = 10; $0.vibrance = 15 },
        Style(tr("Холодный"), "Базовые") { $0.wbShift = -750; $0.saturation = -5 },
        Style(tr("Сочный"), "Базовые") { $0.contrast = 20; $0.vibrance = 35; $0.clarity = 10 },
        Style(tr("Яркий день"), "Базовые") { $0.exposure = 0.3; $0.highlights = -25; $0.shadows = 25; $0.vibrance = 20 },
        Style(tr("Мягкий"), "Базовые") { $0.contrast = -20; $0.highlights = -15; $0.shadows = 15; $0.clarity = -10 },
        Style(tr("Матовый"), "Базовые") { $0.wbShift = 300; $0.contrast = -10; $0.fade = 30; $0.saturation = -15 },
    ]

    static let portrait: [Style] = [
        Style(tr("Нежная кожа"), "Портрет") {
            $0.wbShift = 180; $0.contrast = -10; $0.highlights = -15; $0.shadows = 10; $0.clarity = -20; $0.vibrance = -5
        },
        Style(tr("Тёплый вечер"), "Портрет") {
            $0.wbShift = 900; $0.tint = 5; $0.fade = 10; $0.highlightHue = 40; $0.highlightSat = 25; $0.vignette = -20
        },
        Style(tr("Пастель"), "Портрет") {
            $0.exposure = 0.2; $0.contrast = -25; $0.fade = 25; $0.saturation = -20; $0.shadowHue = 200; $0.shadowSat = 15
        },
        Style(tr("Глянец"), "Портрет") { $0.contrast = 15; $0.clarity = 10; $0.vibrance = 15; $0.highlights = -10 },
        Style(tr("Свадебный светлый"), "Портрет") {
            $0.exposure = 0.35; $0.contrast = -15; $0.highlights = -30; $0.shadows = 20; $0.wbShift = 240
            $0.saturation = -10; $0.fade = 10; $0.clarity = -10
        },
    ]

    static let landscape: [Style] = [
        Style(tr("Сочный пейзаж"), "Пейзаж") { $0.contrast = 20; $0.clarity = 30; $0.vibrance = 40; $0.highlights = -30; $0.shadows = 20 },
        Style(tr("Драматичное небо"), "Пейзаж") {
            $0.highlights = -60; $0.clarity = 40; $0.contrast = 25; $0.wbShift = -240; $0.vignette = -25
        },
        Style(tr("Золотой час"), "Пейзаж") {
            $0.wbShift = 1050; $0.vibrance = 20; $0.highlightHue = 45; $0.highlightSat = 30; $0.shadows = 15
        },
        Style(tr("Туманное утро"), "Пейзаж") { $0.contrast = -30; $0.fade = 30; $0.wbShift = -300; $0.clarity = -20; $0.saturation = -15 },
    ]

    static let cinema: [Style] = [
        Style("Teal & Orange", "Кино") {
            $0.shadowHue = 190; $0.shadowSat = 40; $0.highlightHue = 30; $0.highlightSat = 35; $0.contrast = 15; $0.saturation = -10
        },
        Style("Moody", "Кино") {
            $0.exposure = -0.2; $0.contrast = 10; $0.fade = 15; $0.saturation = -30; $0.shadowHue = 210; $0.shadowSat = 25
            $0.vignette = -30; $0.clarity = 10
        },
        Style(tr("Ночной неон"), "Кино") { $0.wbShift = -600; $0.tint = 15; $0.vibrance = 30; $0.contrast = 20; $0.shadowHue = 260; $0.shadowSat = 30 },
        Style(tr("Выцветший фильм"), "Кино") {
            $0.fade = 35; $0.contrast = -10; $0.saturation = -25; $0.highlightHue = 50; $0.highlightSat = 20; $0.grain = 25
        },
    ]

    static let blackWhite: [Style] = [
        Style(tr("Ч/Б контраст"), "Чёрно-белые") { $0.saturation = -100; $0.contrast = 35 },
        Style(tr("Ч/Б мягкий"), "Чёрно-белые") { $0.saturation = -100; $0.contrast = -10; $0.fade = 20 },
        Style(tr("Ч/Б драма"), "Чёрно-белые") { $0.saturation = -100; $0.contrast = 50; $0.clarity = 40; $0.vignette = -35; $0.grain = 15 },
        Style(tr("Ч/Б нуар"), "Чёрно-белые") {
            $0.saturation = -100; $0.contrast = 60; $0.exposure = -0.3; $0.highlights = -20; $0.vignette = -45; $0.grain = 30
        },
        Style(tr("Ч/Б селен"), "Чёрно-белые") { $0.saturation = -100; $0.contrast = 20; $0.shadowHue = 260; $0.shadowSat = 15; $0.highlightHue = 40; $0.highlightSat = 10 },
    ]

    /// Recipes based on film emulations: LUT + grain/vignette.
    static let film: [Style] = [
        filmStyle("Portra 400", "Color Negative - Kodak Portra 400") { $0.grain = 12 },
        filmStyle("Portra 160 NC", "Color Negative - Kodak Portra 160 NC") { $0.grain = 8 },
        filmStyle("Ektar 100", "Color Negative - Kodak Ektar 100") { $0.grain = 6 },
        filmStyle("Kodak Gold 200", "Color Negative - Kodak Gold 200") { $0.grain = 15; $0.vignette = -10 },
        filmStyle("Fuji Pro 400H", "Color Negative - Fuji Pro 400H") { $0.grain = 12 },
        filmStyle("Fuji Superia 400", "Color Negative - Fuji Superia 400") { $0.grain = 18 },
        filmStyle("Velvia 50", "Color Slide - Fuji Velvia 50") { $0.grain = 5 },
        filmStyle("Provia 100F", "Color Slide - Fuji Provia 100F") { $0.grain = 5 },
        filmStyle("Kodachrome 64", "Color Slide - Kodak Kodakchrome 64") { $0.grain = 10; $0.vignette = -10 },
        filmStyle("Tri-X 400", "Black and White - Kodak Tri-X 400") { $0.grain = 35; $0.contrast = 10 },
        filmStyle("Ilford HP5 Plus", "Black and White - Ilford HP5 Plus 400") { $0.grain = 30 },
        filmStyle("Ilford Delta 3200", "Black and White - Ilford Delta 3200") { $0.grain = 55; $0.vignette = -15 },
    ]

    private static func filmStyle(_ name: String, _ lut: String, _ build: (inout Adjustments) -> Void) -> Style {
        Style(name, "Плёнка") {
            $0.lut = "\(LUTCollection.t3mujin.folder)/t3mujinpack - \(lut).png"
            build(&$0)
        }
    }

    static let collectionOrder = ["Мои стили", "Базовые", "Портрет", "Пейзаж", "Кино", "Чёрно-белые", "Плёнка"]
}
