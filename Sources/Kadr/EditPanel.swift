import SwiftUI

/// Правая панель: вкладки «Инфо» и «Обработка».
struct Inspector: View {
    @Environment(Library.self) private var lib

    var body: some View {
        @Bindable var lib = lib
        VStack(spacing: 0) {
            Picker("", selection: $lib.inspectorTab) {
                Text("Инфо").tag(Library.InspectorTab.info)
                Text("Обработка").tag(Library.InspectorTab.edit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch lib.inspectorTab {
            case .info: InfoPanel()
            case .edit: EditPanel()
            }
        }
    }
}

struct EditPanel: View {
    @Environment(Library.self) private var lib
    @State private var naming = false
    @State private var styleName = ""

    var body: some View {
        ScrollView {
            if let p = lib.current {
                VStack(alignment: .leading, spacing: 20) {
                    if lib.multiSelected {
                        Label("Стили, вставка и сброс — для \(lib.targets.count) выделенных. Ползунки — для текущего кадра.",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    styles
                    group("Свет") {
                        slider("Экспозиция", \.exposure, p, range: -3...3, step: 0.05) { String(format: "%+.2f EV", $0) }
                        slider("Контраст", \.contrast, p)
                        slider("Света", \.highlights, p)
                        slider("Тени", \.shadows, p)
                        slider("Матовость", \.fade, p, range: 0...100)
                    }
                    group("Цвет") {
                        slider("Температура", \.temperature, p, tint: [.blue, .orange])
                        slider("Оттенок", \.tint, p, tint: [.green, .pink])
                        slider("Красочность", \.vibrance, p)
                        slider("Насыщенность", \.saturation, p)
                    }
                    lutSection(p)
                    actions(p)
                }
                .padding(16)
            } else {
                Text("Нет выбранного снимка").foregroundStyle(.secondary).padding()
            }
        }
        .alert("Сохранить как стиль", isPresented: $naming) {
            TextField("Название", text: $styleName)
            Button("Сохранить") { lib.saveStyle(named: styleName) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущие настройки кадра станут стилем, его можно применить к любым снимкам.")
        }
    }

    // MARK: - Стили

    private var styles: some View {
        group("Стили") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(lib.styles) { st in
                    let active = lib.current?.adj == st.adj
                    Button { lib.applyStyle(st) } label: {
                        Text(st.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(active ? Color.accentColor.opacity(0.3) : .white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !st.builtIn { Button("Удалить стиль", role: .destructive) { lib.deleteStyle(st) } }
                    }
                }
            }
            Button {
                styleName = ""
                naming = true
            } label: {
                Label("Сохранить текущую как стиль…", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(lib.current?.adj.isIdentity ?? true)
        }
    }

    // MARK: - LUT

    private func lutSection(_ p: Photo) -> some View {
        group("LUT") {
            Picker("", selection: Binding(get: { p.adj.lut }, set: { v in var a = p.adj; a.lut = v; lib.setAdjustments(a) })) {
                Text("Нет").tag(String?.none)
                ForEach(lib.luts, id: \.self) { name in
                    Text(name.replacingOccurrences(of: ".cube", with: "", options: .caseInsensitive)).tag(String?.some(name))
                }
            }
            .labelsHidden()
            if p.adj.lut != nil {
                slider("Сила", \.lutAmount, p, range: 0...100, defaultValue: 100)
            }
            HStack {
                Button("Загрузить .cube…") { lib.importLUTs() }
                Button("Папка LUT") { lib.revealLUTFolder() }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Действия

    private func actions(_ p: Photo) -> some View {
        @Bindable var lib = lib
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { lib.copyAdjustments() } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    .help("⌘⇧C")
                Button { lib.pasteAdjustments() } label: { Label("Вставить", systemImage: "doc.on.clipboard") }
                    .disabled(lib.copiedAdj == nil)
                    .help("⌘⇧V — на все выделенные")
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Button(role: .destructive) { lib.resetAdjustments() } label: { Label("Сбросить", systemImage: "arrow.counterclockwise") }
                    .disabled(lib.targets.allSatisfy(\.adj.isIdentity))
                Toggle(isOn: $lib.showOriginal) { Text("До") }
                    .toggleStyle(.button)
                    .help("Показать без обработки (клавиша \\)")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Компоненты

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    /// Ползунок. Двойной клик по названию — сброс.
    private func slider(_ title: String, _ key: WritableKeyPath<Adjustments, Double>, _ p: Photo,
                        range: ClosedRange<Double> = -100...100, step: Double = 1, defaultValue: Double = 0,
                        tint: [Color]? = nil, format: ((Double) -> String)? = nil) -> some View {
        let value = p.adj[keyPath: key]
        let binding = Binding<Double>(get: { value }, set: { v in
            var a = p.adj
            a[keyPath: key] = (v / step).rounded() * step
            lib.setAdjustments(a)
        })
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(value == defaultValue ? .secondary : .primary)
                    .onTapGesture(count: 2) { binding.wrappedValue = defaultValue }
                    .help("Двойной клик — сбросить")
                Spacer()
                Text(format?(value) ?? (value == 0 ? "0" : String(format: range.lowerBound < 0 ? "%+.0f" : "%.0f", value)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range)
                .controlSize(.small)
                .tint(tint?.last ?? .accentColor)
        }
    }
}
