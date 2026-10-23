import SwiftUI

/// Main tools in the top bar: view, the culling layer, crop, Before/After split, compare, 100%, edit.
/// The active tool is highlighted; a hover card (Tips.swift) says what each one is for and its key.
struct ToolsBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let hasPhoto = lib.current != nil
        HStack(spacing: 2) {
            // Two views. "Culling" is not a third one: it is a layer over either (the toggle next to them).
            HStack(spacing: 0) {
                tool(tr("Сетка"), "square.grid.2x2", on: !lib.loupe, key: tr("Пробел"), enabled: true,
                     text: tr("Все кадры папки плитками. Двойной клик или пробел открывает кадр крупно.")) {
                    leaveTools(); lib.loupe = false
                }
                tool(tr("Кадр"), "rectangle", on: lib.loupe, key: tr("Пробел"), enabled: true,
                     text: tr("Один снимок крупно, лента кадров снизу. Колёсико или Z — зум.")) {
                    leaveTools(); lib.loupe = true
                }
            }
            .padding(2)
            .background {
                // macOS 26+ wraps the toolbar item in a glass capsule already: a second plate inside it
                // was a background within a background.
                if #available(macOS 26, *) {} else { RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)) }
            }

            // No tournament button: the toolbar must not grow (with the inspector open it would squeeze the
            // sidebar below its minimum); T, the burst badge and the «Отбор» menu start one.
            tool(tr("Отбор"), "checkmark.rectangle.stack", on: lib.culling, key: "O", enabled: true,
                 text: tr("Слой поверх вида: ярлыки AI-анализа на кадрах, лица на 100%, прогресс просмотра.")) {
                lib.toggleCullingLayer()
            }

            Divider().frame(height: 18).padding(.horizontal, 4)

            tool(tr("Кадрирование"), "crop", on: lib.cropMode, key: "R", enabled: hasPhoto,
                 text: tr("Рамка и горизонт. Enter — готово, Esc — отмена. Исходный файл не меняется.")) {
                lib.cropMode ? lib.finishCrop() : lib.startCrop()
            }
            tool(tr("До/после"), "rectangle.split.2x1", on: lib.splitCompare, key: "Y",
                 enabled: hasPhoto && !(lib.current?.adj.isIdentity ?? true),
                 text: tr("Шторка: слева исходник, справа кадр с обработкой."),
                 disabledText: tr("У кадра нет обработки — сравнивать не с чем.")) {
                lib.splitCompare.toggle()
                if lib.splitCompare { lib.loupe = true }
            }
            tool(tr("Сравнить"), "rectangle.on.rectangle", on: lib.comparing, key: "C",
                 enabled: lib.comparing || lib.canCompare,
                 text: tr("Несколько кадров рядом, чтобы выбрать, какой оставить."),
                 disabledText: tr("Выделите 2–8 кадров (⌘-клик или рамкой) или встаньте на кадр серии.")) {
                lib.comparing ? lib.stopCompare() : lib.startCompare()
            }
            tool("100%", "plus.magnifyingglass", on: lib.zoom100, key: "Z", enabled: hasPhoto && !lib.cropMode,
                 text: tr("Пиксель в пиксель: проверить резкость и глаза.")) {
                lib.loupe = true
                lib.zoom100.toggle()
            }

            tool(tr("Во весь экран"), "arrow.up.left.and.arrow.down.right", on: lib.fullscreen, key: "F", enabled: hasPhoto,
                 text: tr("Снимок на весь экран без панелей. Esc — назад.")) {
                Fullscreen.shared.toggle(lib)
            }

            Divider().frame(height: 18).padding(.horizontal, 4)

            tool(tr("Обработка"), "slider.horizontal.3", on: lib.showInfo && lib.inspectorTab == .edit, key: "E", enabled: hasPhoto,
                 text: tr("Экспозиция, баланс белого, стили и LUT — в инспекторе справа.")) {
                if lib.showInfo && lib.inspectorTab == .edit { lib.showInfo = false } else {
                    lib.showInfo = true
                    lib.inspectorTab = .edit
                }
            }
            tool(tr("Журнал"), "clock.arrow.circlepath", on: lib.showInfo && lib.inspectorTab == .history, key: "⌘Y", enabled: true,
                 text: tr("Что вы делали с кадром; к любому шагу можно вернуться.")) {
                if lib.showInfo && lib.inspectorTab == .history { lib.showInfo = false } else {
                    lib.showInfo = true
                    lib.inspectorTab = .history
                }
            }
        }
        .disabled(lib.folder == nil)
    }

    /// Switching the view ends crop and compare, which only make sense in the view they started in.
    private func leaveTools() {
        if lib.cropMode { lib.finishCrop() }
        if lib.comparing { lib.stopCompare() }
    }

    private func tool(_ title: String, _ icon: String, on: Bool, key: String, enabled: Bool,
                      text: String, disabledText: String? = nil, action: @escaping () -> Void) -> some View {
        // Icon only, as in the Finder toolbar: the name, the key and the purpose are in the hover card.
        // Six tools with captions were 560 px, which forced the window wider than a laptop screen.
        // A disabled tool is dimmed but still hoverable (`.disabled` would swallow the hover): the card
        // then says why it is off.
        Button { if enabled { action() } } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 24)
            .padding(.horizontal, 1).padding(.vertical, 1)
            .background(Self.mark.fill(on ? Color.accentColor.opacity(0.3) : .clear))
            .foregroundStyle(on ? Color.primary : enabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(title, key: key, icon: icon, enabled ? text : (disabledText ?? text))
        // The hover card is not read by VoiceOver: the name is.
        .accessibilityLabel(title)
    }

    /// The active tool's mark: inside the glass capsule of macOS 26+ a capsule, not a box in a capsule.
    private static var mark: AnyShape {
        if #available(macOS 26, *) { AnyShape(Capsule()) } else { AnyShape(RoundedRectangle(cornerRadius: 6)) }
    }
}
