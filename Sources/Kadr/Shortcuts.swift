import SwiftUI

/// Keyboard cheat sheet: "?" or Help → Keyboard Shortcuts.
struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        (tr("Отбор"), [
            ("P / X / U", tr("оставить / брак / снять решение")),
            ("1–5 / 0", tr("звёзды / снять оценку")),
            ("6–9", tr("цветная метка")),
            ("O", tr("режим «Отбор»")),
            ("T", tr("турнир: ← / → — лучший кадр")),
            ("C", tr("сравнить выделенные")),
            ("⌥⌘A", tr("запустить AI-анализ")),
            ("⌘⌫", tr("перенести брак в «_Отклонённые»")),
        ]),
        (tr("Просмотр"), [
            ("← → ↑ ↓", tr("листать; с ⇧ — расширить выделение")),
            (tr("Пробел / Enter"), tr("сетка ↔ кадр")),
            ("Z", tr("100% / вписать")),
            ("⌘+ / ⌘− / ⌘0", tr("увеличить / уменьшить / вписать")),
            ("I", tr("панель «Инфо»")),
            ("⌘A / ⇧⌘A", tr("выделить всё / серию")),
        ]),
        (tr("Обработка"), [
            ("E", tr("панель «Обработка»")),
            ("R", tr("кадрирование; Enter — готово, Esc — отмена")),
            ("A", tr("в кадрировании — AI-предложение рамки")),
            ("Y", tr("шторка «до / после»")),
            ("\\", tr("показать исходник")),
            ("⇧⌘C / ⇧⌘V", tr("копировать / вставить обработку")),
            ("⌘Z / ⇧⌘Z / ⌘Y", tr("отменить / вернуть / журнал")),
        ]),
        (tr("Файлы"), [
            ("S", tr("отправить в папку сохранения")),
            ("⌘S", tr("сохранить в папку…")),
            ("⌘I", tr("импорт с карты памяти")),
            ("⇧⌘O", tr("открыть в Capture One")),
            ("?", tr("эта шпаргалка")),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Горячие клавиши")).font(.title2.weight(.semibold))
            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
                GridRow {
                    group(groups[0]); group(groups[1])
                }
                GridRow {
                    group(groups[2]); group(groups[3])
                }
            }
            HStack {
                Text(tr("Русская раскладка тоже работает: З / Ч / Г вместо P / X / U.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 720)
    }

    private func group(_ g: (String, [(String, String)])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.0).font(.headline)
            ForEach(g.1, id: \.0) { k, v in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(k).font(.callout.monospaced().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        .frame(minWidth: 110, alignment: .leading)
                    Text(v).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
