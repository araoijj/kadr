import SwiftUI

/// Key equivalents of the menu items. The menus take them from here and the cheat sheet prints them from
/// the same values (`text`), so a key changed in a menu can't be left behind in the sheet.
enum Keys {
    static let open = KeyboardShortcut("o")
    static let importCard = KeyboardShortcut("i")
    static let undo = KeyboardShortcut("z")
    static let redo = KeyboardShortcut("z", modifiers: [.command, .shift])
    static let history = KeyboardShortcut("y")
    static let zoomIn = KeyboardShortcut("=")
    static let zoomOut = KeyboardShortcut("-")
    static let zoomFit = KeyboardShortcut("0")
    static let zoom100 = KeyboardShortcut("1")
    static let sourcesPanel = KeyboardShortcut("1", modifiers: [.command, .option])
    static let filtersPanel = KeyboardShortcut("2", modifiers: [.command, .option])
    static let resetFilters = KeyboardShortcut("f", modifiers: [.command, .option])
    static let shortcuts = KeyboardShortcut("/", modifiers: .command)
    static let match = KeyboardShortcut("m", modifiers: [.command, .option])
    static let copyEdits = KeyboardShortcut("c", modifiers: [.command, .shift])
    static let pasteEdits = KeyboardShortcut("v", modifiers: [.command, .shift])
    static let resetEdits = KeyboardShortcut("r", modifiers: [.command, .option])
    static let moveRejected = KeyboardShortcut(.delete, modifiers: .command)
    static let export = KeyboardShortcut("s", modifiers: .command)
    static let captureOne = KeyboardShortcut("o", modifiers: [.command, .shift])
    static let selectAll = KeyboardShortcut("a")              // KeyHandler's: a menu item would take ⌘A from text fields
    static let selectSeries = KeyboardShortcut("a", modifiers: [.command, .shift])
    static let startAI = KeyboardShortcut("a", modifiers: [.command, .option])
    static let reveal = KeyboardShortcut("r", modifiers: [.command, .shift])

    /// "⌥⌘F", as menus print it: modifiers in the system order, then the key.
    static func text(_ k: KeyboardShortcut) -> String {
        var s = ""
        if k.modifiers.contains(.control) { s += "⌃" }
        if k.modifiers.contains(.option) { s += "⌥" }
        if k.modifiers.contains(.shift) { s += "⇧" }
        if k.modifiers.contains(.command) { s += "⌘" }
        switch k.key {
        case .delete: s += "⌫"
        case .return: s += "↩"
        case .escape: s += "Esc"
        case "=": s += "+"           // ⌘= is ⌘+ on the keycap
        case "-": s += "−"
        default: s += String(k.key.character).uppercased()
        }
        return s
    }

    /// Several shortcuts in one cell: "⌘Z / ⇧⌘Z / ⌘Y".
    static func text(_ ks: KeyboardShortcut...) -> String { ks.map(text).joined(separator: " / ") }
}

/// Every keyboard shortcut in one table: the cheat sheet lists all of it and the empty window's hints show
/// the rows' `hints`. Bare keys are KeyHandler's (KadrApp.swift); keys with ⌘ come from `Keys`.
enum ShortcutTable {
    struct Row {
        let keys: String
        let action: String
        /// The empty window's short hints for this row, with their own keys (a hint may show only part of
        /// them, as before: X of P / X / U); empty — only in the cheat sheet.
        var hints: [(keys: String, text: String)] = []
    }

    struct Group {
        let title: String
        let rows: [Row]
    }

    static var groups: [Group] {
        [
            Group(title: tr("Отбор"), rows: [
                Row(keys: "P / X / U", action: tr("оставить / брак / снять решение"), hints: [("X", tr("отклонить"))]),
                Row(keys: "⌫", action: tr("брак / вернуть из брака")),
                Row(keys: "1–5 / 0", action: tr("звёзды / снять оценку"), hints: [("1–5", tr("звёзды")), ("0", tr("снять оценку"))]),
                Row(keys: "6–9", action: tr("цветная метка"), hints: [("6–9", tr("цвет"))]),
                Row(keys: "H", action: tr("скрыть / показать брак")),
                Row(keys: "O", action: tr("слой «Отбор»: ярлыки AI, лица, прогресс")),
                Row(keys: "T", action: tr("турнир: ← / → — лучший кадр")),
                Row(keys: "C", action: tr("сравнить выделенные"), hints: [("C", tr("сравнить кадры"))]),
                // KeyHandler's compare-mode keys.
                Row(keys: tr("P, Пробел / X"), action: tr("в сравнении: отметить «оставить» / «брак»")),
                Row(keys: "Enter", action: tr("в сравнении: применить отметки")),
                Row(keys: "Z / + / −", action: tr("в сравнении: зум / размер кадров")),
                Row(keys: "C / Esc", action: tr("выйти из сравнения")),
                Row(keys: Keys.text(Keys.startAI), action: tr("запустить AI-анализ")),
                Row(keys: Keys.text(Keys.moveRejected), action: tr("перенести брак в «_Отклонённые»")),
                Row(keys: Keys.text(Keys.resetFilters), action: tr("сбросить все фильтры")),
            ]),
            Group(title: tr("Просмотр"), rows: [
                Row(keys: "← → ↑ ↓", action: tr("листать; с ⇧ — расширить выделение"), hints: [("← →", tr("листать"))]),
                Row(keys: tr("⌘ / ⇧ + клик"), action: tr("выделить несколько"), hints: [(tr("⌘ / ⇧ + клик"), tr("выделить несколько"))]),
                Row(keys: Keys.text(Keys.selectAll, Keys.selectSeries), action: tr("выделить всё / серию"), hints: [(Keys.text(Keys.selectAll), tr("выделить всё"))]),
                Row(keys: tr("Пробел / Enter"), action: tr("сетка ↔ кадр"), hints: [(tr("Пробел"), tr("сетка / кадр"))]),
                Row(keys: "G", action: tr("к сетке")),
                Row(keys: "Esc", action: tr("назад: из 100%, из серии, к сетке; снять выделение")),
                Row(keys: "Z", action: tr("100% / вписать"), hints: [("Z", tr("зум 100%"))]),
                Row(keys: Keys.text(Keys.zoomIn, Keys.zoomOut, Keys.zoomFit, Keys.zoom100), action: tr("увеличить / уменьшить / вписать / 100%")),
                Row(keys: "+ / −", action: tr("увеличить / уменьшить без ⌘")),
                Row(keys: "F", action: tr("во весь экран; F или Esc — выйти")),
                Row(keys: "I", action: tr("панель «Инфо»"), hints: [("I", tr("инфо"))]),
                Row(keys: Keys.text(Keys.sourcesPanel, Keys.filtersPanel), action: tr("панель: источники / фильтры")),
            ]),
            Group(title: tr("Обработка"), rows: [
                Row(keys: "E", action: tr("панель «Обработка»"), hints: [("E", tr("обработка"))]),
                Row(keys: "R", action: tr("кадрирование; Enter — готово, Esc — отмена")),
                Row(keys: "A", action: tr("в кадрировании — AI-предложение рамки")),
                Row(keys: "Enter / Esc", action: tr("«Убрать объект»: убрать выделенное / снять выделение, выйти")),
                Row(keys: "Y", action: tr("шторка «до / после»")),
                Row(keys: "\\", action: tr("показать исходник"), hints: [("\\", tr("до / после"))]),
                Row(keys: Keys.text(Keys.copyEdits, Keys.pasteEdits), action: tr("копировать / вставить обработку")),
                Row(keys: Keys.text(Keys.resetEdits), action: tr("сбросить обработку")),
                Row(keys: Keys.text(Keys.match), action: tr("выровнять экспозицию и баланс по текущему")),
                Row(keys: Keys.text(Keys.undo, Keys.redo, Keys.history), action: tr("отменить / вернуть / журнал")),
            ]),
            Group(title: tr("Файлы"), rows: [
                Row(keys: "S", action: tr("отправить в папку сохранения"), hints: [("S", tr("кадр в папку"))]),
                Row(keys: Keys.text(Keys.export), action: tr("сохранить в папку…"), hints: [(Keys.text(Keys.export), tr("сохранить отобранные"))]),
                Row(keys: Keys.text(Keys.open), action: tr("открыть папку…")),
                Row(keys: Keys.text(Keys.importCard), action: tr("импорт с карты памяти"), hints: [(Keys.text(Keys.importCard), tr("импорт с карты"))]),
                Row(keys: Keys.text(Keys.captureOne), action: tr("открыть в Capture One")),
                Row(keys: Keys.text(Keys.reveal), action: tr("показать в Finder")),
                Row(keys: "? / " + Keys.text(Keys.shortcuts), action: tr("эта шпаргалка")),
            ]),
        ]
    }

    /// The hints the empty window shows, in the table's order.
    static var hints: [(keys: String, text: String)] {
        groups.flatMap(\.rows).flatMap(\.hints)
    }
}

/// Keyboard cheat sheet: "?" or Help → Keyboard Shortcuts.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.screen) private var screen
    @State private var tableHeight: CGFloat = 0

    var body: some View {
        let groups = ShortcutTable.groups
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Горячие клавиши")).font(.title2.weight(.semibold))
            // Scrolls only when the library window is too short for the whole table; otherwise as tall as the
            // table. The window, not the screen: a sheet taller than its window hangs off the window's bottom.
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
                    GridRow {
                        group(groups[0]); group(groups[1])
                    }
                    GridRow {
                        group(groups[2]); group(groups[3])
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tableHeight = $0 }
            }
            .frame(height: tableHeight > 0 ? min(tableHeight, max(240, (KeyHandler.window?.frame.height ?? screen.height) - 200)) : nil)
            HStack {
                Text(tr("Русская раскладка тоже работает: З / Ч / Г вместо P / X / U.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 760)
    }

    private func group(_ g: ShortcutTable.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.title).font(.headline)
            ForEach(g.rows, id: \.keys) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.keys).font(.callout.monospaced().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.key, in: RoundedRectangle(cornerRadius: 4))
                        .frame(minWidth: 110, alignment: .leading)
                    // Wraps instead of truncating: the grid sizes a row before it knows the column's final width.
                    Text(r.action).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The empty window's short list of keys: the table's rows that have a hint, two to a line.
struct KeyHints: View {
    var body: some View {
        let hints = ShortcutTable.hints
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: hints.count, by: 2)), id: \.self) { i in
                GridRow {
                    hint(hints[i])
                    if i + 1 < hints.count { hint(hints[i + 1]) }
                }
            }
        }
    }

    private func hint(_ h: (keys: String, text: String)) -> some View {
        HStack(spacing: 8) {
            Text(h.keys)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.key))
            Text(h.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
