import SwiftUI

/// Основные инструменты в верхней панели: вид, кадрирование, шторка, сравнение, 100%, обработка.
/// Включённый инструмент подсвечен; в подсказке — клавиша.
struct ToolsBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        @Bindable var lib = lib
        let hasPhoto = lib.current != nil
        HStack(spacing: 2) {
            Picker("Вид", selection: Binding(get: { lib.loupe }, set: { v in
                if lib.cropMode { lib.finishCrop() }
                if lib.comparing { lib.stopCompare() }
                lib.loupe = v
            })) {
                Image(systemName: "square.grid.2x2").tag(false)
                Image(systemName: "rectangle").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .help("Сетка / Кадр (пробел)")

            Divider().frame(height: 18).padding(.horizontal, 6)

            tool("Кадрирование", "crop", on: lib.cropMode, key: "R", enabled: hasPhoto) {
                lib.cropMode ? lib.finishCrop() : lib.startCrop()
            }
            tool("До/после", "rectangle.split.2x1", on: lib.splitCompare, key: "Y",
                 enabled: hasPhoto && !(lib.current?.adj.isIdentity ?? true),
                 disabledHelp: "У кадра нет обработки — сравнивать не с чем") {
                lib.splitCompare.toggle()
                if lib.splitCompare { lib.loupe = true }
            }
            tool("Сравнить", "rectangle.on.rectangle", on: lib.comparing, key: "C",
                 enabled: lib.comparing || lib.canCompare,
                 disabledHelp: "Выделите 2–4 кадра (⌘-клик или рамкой) или встаньте на кадр серии") {
                lib.comparing ? lib.stopCompare() : lib.startCompare()
            }
            tool("100%", "plus.magnifyingglass", on: lib.zoom100, key: "Z", enabled: hasPhoto && !lib.cropMode) {
                lib.loupe = true
                lib.zoom100.toggle()
            }

            Divider().frame(height: 18).padding(.horizontal, 6)

            tool("Обработка", "slider.horizontal.3", on: lib.showInfo && lib.inspectorTab == .edit, key: "E", enabled: hasPhoto) {
                if lib.showInfo && lib.inspectorTab == .edit { lib.showInfo = false } else {
                    lib.showInfo = true
                    lib.inspectorTab = .edit
                }
            }
            tool("Журнал", "clock.arrow.circlepath", on: lib.showInfo && lib.inspectorTab == .history, key: "⌘Y", enabled: true) {
                if lib.showInfo && lib.inspectorTab == .history { lib.showInfo = false } else {
                    lib.showInfo = true
                    lib.inspectorTab = .history
                }
            }
        }
        .disabled(lib.folder == nil)
    }

    private func tool(_ title: String, _ icon: String, on: Bool, key: String, enabled: Bool,
                      disabledHelp: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(height: 16)
                Text(title).font(.system(size: 10, weight: on ? .semibold : .regular))
            }
            .frame(minWidth: 56)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.3) : .clear))
            .foregroundStyle(on ? Color.primary : enabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "\(title) (\(key))" : (disabledHelp ?? title))
    }
}
