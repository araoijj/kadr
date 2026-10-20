import Foundation

/// Vision tags are English identifiers; the most common ones get readable names in the app's language.
enum TagNames {
    private static let ru: [String: String] = [
        "people": "люди", "adult": "взрослые", "child": "дети", "baby": "младенец", "portrait": "портрет", "selfie": "селфи",
        "clothing": "одежда", "hat": "шляпа", "dress": "платье", "sunglasses": "очки", "smile": "улыбка",
        "outdoor": "на улице", "indoor": "в помещении", "structure": "здание", "building": "здание", "house": "дом",
        "plant": "растения", "tree": "деревья", "flower": "цветы", "grass": "трава", "garden": "сад", "forest": "лес",
        "sky": "небо", "cloudy": "облачно", "sunset_sunrise": "закат, рассвет", "night_sky": "ночное небо",
        "water": "вода", "waterfall": "водопад", "water_body": "водоём", "lake": "озеро", "sea": "море", "beach": "пляж",
        "river": "река", "mountain": "горы", "land": "пейзаж", "hill": "холм", "rocks": "камни",
        "animal": "животные", "dog": "собака", "cat": "кошка", "bird": "птица", "canine": "собака", "pet": "питомец",
        "food": "еда", "drink": "напитки", "table": "стол", "restaurant": "ресторан", "cafe": "кафе",
        "vehicle": "транспорт", "car": "машина", "road": "дорога", "street": "улица", "city": "город",
        "furniture": "мебель", "chair": "стул", "fence": "забор", "bridge": "мост", "railing": "перила",
        "document": "документ", "screenshot": "скриншот", "text": "текст", "art": "искусство", "decoration": "декор",
        "foliage": "листва", "wood_processed": "дерево", "optical_equipment": "фототехника", "agriculture": "поля, сады",
        "container": "ёмкости", "headgear": "головной убор", "mammal": "животные", "utensil": "посуда", "tableware": "посуда",
        "liquid": "напитки", "bottle": "бутылки", "luggage": "сумки", "waterways": "вода", "purse": "сумочка",
        "eyeglasses": "очки", "roof": "крыши", "machine": "техника",
        "wedding": "свадьба", "celebration": "праздник", "party": "вечеринка", "night": "ночь", "light": "свет",
    ]

    static func title(_ id: String) -> String {
        if I18n.lang == "ru", let r = ru[id] { return r }
        return id.replacingOccurrences(of: "_", with: " ")
    }
}

extension Library {
    /// Tags found in the folder, most frequent first.
    var tags: [(id: String, count: Int)] {
        var c: [String: Int] = [:]
        for p in photos { for t in p.cull?.tags ?? [] { c[t, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
}
