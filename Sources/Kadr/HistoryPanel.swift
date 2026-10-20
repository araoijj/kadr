import SwiftUI

/// "History" tab: newest steps on top; click to go to the state after that step.
struct HistoryPanel: View {
    @Environment(Library.self) private var lib
    @State private var onlyCurrent = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { lib.undo() } label: { Label(tr("Отменить"), systemImage: "arrow.uturn.backward") }
                    .disabled(!lib.canUndo).help(lib.undoTitle.map { tr("Отменить: \($0) (⌘Z)") } ?? tr("Нечего отменять"))
                Button { lib.redo() } label: { Label(tr("Вернуть"), systemImage: "arrow.uturn.forward") }
                    .disabled(!lib.canRedo).help(lib.redoTitle.map { tr("Вернуть: \($0) (⇧⌘Z)") } ?? tr("Нечего возвращать"))
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 8)
            Toggle(tr("Только текущий кадр"), isOn: $onlyCurrent)
                .toggleStyle(.checkbox).font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let cur = lib.currentID?.path
                    let rows = Array(lib.history.enumerated()).reversed()
                        .filter { item in !onlyCurrent || (cur.map { item.element.changes[$0] != nil } ?? false) }
                    if rows.isEmpty {
                        Text(lib.history.isEmpty ? tr("Изменений пока нет. Здесь появится каждое действие: ползунки, стили, кадрирование, оценки.") : tr("У этого кадра изменений нет."))
                            .font(.caption).foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(rows, id: \.element.id) { i, e in row(i, e) }
                    // The bottom row is the state before all history steps.
                    Button { lib.jumpHistory(to: 0) } label: {
                        HStack {
                            Image(systemName: lib.historyPos == 0 ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(lib.historyPos == 0 ? Color.accentColor : .secondary)
                            Text(tr("Исходное состояние")).font(.callout)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(lib.history.isEmpty)
                }
                .padding(.vertical, 6)
            }
            Divider()
            Text(tr("Хранится \(lib.history.count) из \(HistoryStore.limit) шагов · журнал папки сохраняется между запусками"))
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func row(_ i: Int, _ e: HistoryEntry) -> some View {
        let applied = i < lib.historyPos
        let isCurrent = i == lib.historyPos - 1
        return Button { lib.jumpHistory(to: i + 1) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : applied ? "circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.accentColor : applied ? Color.secondary : Color.secondary.opacity(0.4))
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.callout.weight(isCurrent ? .semibold : .regular))
                    Text(subtitle(e)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .opacity(applied ? 1 : 0.45)
            .padding(.horizontal, 16).padding(.vertical, 5)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(applied ? tr("Вернуться к состоянию после этого шага") : tr("Отменённый шаг — клик вернёт его"))
    }

    private func subtitle(_ e: HistoryEntry) -> String {
        let time = e.date.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(e.date) ? .omitted : .abbreviated, time: .shortened).locale(I18n.locale))
        let names = e.photoNames
        let who = names.count == 1 ? names[0] : tr("\(names.count) кадров")
        return "\(time) · \(who)"
    }
}
