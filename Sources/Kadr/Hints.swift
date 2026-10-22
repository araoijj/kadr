import SwiftUI

/// Short "how this tool works" cards. Shown when a tool opens until closed;
/// "?" in the tool's bar brings the card back, and Settings → General turns all of them off or on again.
enum Hints {
    static let enabledKey = "pref.hints"
    static let closedKey = "hints.closed"      // ids closed with "Понятно", comma-separated
    static let forcedKey = "hints.forced"      // id reopened with "?" — shown even when hints are off

    static func reopen(_ id: String) {
        let d = UserDefaults.standard
        let closed = (d.string(forKey: closedKey) ?? "").split(separator: ",").map(String.init).filter { $0 != id }
        d.set(closed.joined(separator: ","), forKey: closedKey)
        d.set(id, forKey: forcedKey)
    }

    static func resetAll() {
        UserDefaults.standard.set("", forKey: closedKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    struct Content {
        let title: String
        let icon: String
        let lines: [String]
    }

    static func content(_ id: String) -> Content? {
        switch id {
        case "compare":
            Content(title: tr("Сравнение: как выбрать, что оставить"), icon: "rectangle.split.2x1", lines: [
                tr("✓ в углу кадра (или P, пробел) — оставить, ✗ (или X) — в брак. Можно отметить несколько."),
                tr("Enter — применить. Если стоят только ✓, все остальные кадры сравнения уходят в брак; если есть ✗ — остальные не трогаются."),
                tr("Клик по кадру делает его активным (цветная рамка): 1–5 и X ставят оценку ему, ← → переключают."),
                tr("Двойной клик или Z — зум 100% сразу во всех кадрах, тянуть мышью — сдвиг."),
                tr("Кадров может быть сколько угодно: размер плиток — ползунок в панели или клавиши + и −, лишнее прокручивается."),
                tr("Ошиблись — ⌘Z возвращает всё как было."),
            ])
        case "tournament":
            Content(title: tr("Турнир: лучший кадр из длинной серии"), icon: "trophy", lines: [
                tr("Кадры сравниваются парами: ← — лучше левый, → — лучше правый."),
                tr("Победитель остаётся слева и встречается со следующим кадром серии."),
                tr("В конце можно отметить победителя ★ и отклонить остальные — или ничего не менять."),
            ])
        case "cull":
            Content(title: tr("Отбор за минуту"), icon: "checkmark.rectangle.stack", lines: [
                tr("P — оставить (★), X — брак, U — снять решение. После решения открывается следующий кадр."),
                tr("← → — просто дальше: кадр остаётся «без решения», к нему можно вернуться через фильтр «Без решения»."),
                tr("1–5 — звёзды, пробел — сетка или кадр, Z — 100%, C — сравнить серию, T — турнир, H — скрыть брак, ⌘Z — отменить."),
                tr("Слой «Отбор» (O) добавляет ярлыки AI-анализа, лица на 100% и прогресс просмотра; что листать — в панели «Фильтры» (⌥⌘2)."),
            ])
        case "crop":
            Content(title: tr("Кадрирование"), icon: "crop", lines: [
                tr("Тяните углы и края рамки, внутри рамки — сдвиг."),
                tr("A или «Авто» — рамку предложит AI. Формат и горизонт — на панели снизу."),
                tr("Enter — готово, Esc — отмена. Исходный файл не меняется."),
            ])
        case "split":
            Content(title: tr("До/после"), icon: "rectangle.split.2x1", lines: [
                tr("Тяните разделитель: слева «до», справа «после»."),
                tr("Y — выключить, \\ — показать исходник целиком."),
            ])
        default:
            nil
        }
    }
}

/// The hint card for one tool. Put it at the top of the tool's view.
struct ToolHint: View {
    let id: String
    @AppStorage(Hints.enabledKey) private var enabled = true
    @AppStorage(Hints.closedKey) private var closedRaw = ""
    @AppStorage(Hints.forcedKey) private var forced = ""

    private var closed: Bool { closedRaw.split(separator: ",").contains { $0 == id } }

    var body: some View {
        if (enabled || forced == id) && !closed, let c = Hints.content(id) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill").foregroundStyle(Theme.star).font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Label(c.title, systemImage: c.icon).font(.callout.weight(.semibold))
                    ForEach(c.lines, id: \.self) { l in
                        Text("•  " + l).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        Button(tr("Понятно")) { close() }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button(tr("Больше не показывать подсказки")) { enabled = false; close() }
                            .buttonStyle(.link).font(.caption)
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
                Button { close() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Закрыть подсказку"))
            }
            .padding(12)
            .frame(minWidth: 380, maxWidth: 560)   // a min width keeps wrapped lines from blowing up the window's min height
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.star.opacity(0.5)))
            .padding(10)
            .transition(.opacity)
        }
    }

    private func close() {
        var ids = closedRaw.split(separator: ",").map(String.init)
        if !ids.contains(id) { ids.append(id) }
        withAnimation(.easeOut(duration: 0.15)) {
            closedRaw = ids.joined(separator: ",")
            if forced == id { forced = "" }
        }
    }
}

/// "?" for a tool's bar: shows its hint card again.
struct HintButton: View {
    let id: String

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { Hints.reopen(id) } } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help(tr("Как работает этот инструмент"))
    }
}
