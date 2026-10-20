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
    @AppStorage("ep.open") private var openGroupsRaw = "Базовые"
    @AppStorage("ep.tab") private var tab = 0

    var body: some View {
        ScrollView {
            if let p = lib.current {
                VStack(alignment: .leading, spacing: 18) {
                    if lib.multiSelected {
                        Label("Стили, вставка и сброс — для \(lib.targets.count) выделенных. Ползунки — для текущего кадра.",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    Picker("", selection: $tab) {
                        Text("Настройки").tag(0)
                        Text("Стили").tag(1)
                        Text("LUT").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch tab {
                    case 1: stylesTab
                    case 2: lutTab(p)
                    default: sliders(p)
                    }
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
            Text("Текущие настройки кадра станут стилем в коллекции «Мои стили».")
        }
    }

    // MARK: - Настройки

    private func sliders(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Профиль") {
                Picker("", selection: Binding(get: { p.adj.profile }, set: { v in var a = p.adj; a.profile = v; lib.setAdjustments(a) })) {
                    Text("Как в камере").tag(Adjustments.Profile.camera)
                    Text("Стандартный macOS").tag(Adjustments.Profile.standard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(p.adj.profile == .camera
                     ? "Цвета подобраны по JPEG камеры — правки начинаются с привычной картинки."
                     : "Проявление RAW движком macOS: свои цвета, может отличаться от камеры.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            group("Свет") {
                slider("Экспозиция", \.exposure, p, range: -3...3, step: 0.05) { String(format: "%+.2f EV", $0) }
                slider("Контраст", \.contrast, p)
                slider("Света", \.highlights, p)
                slider("Тени", \.shadows, p)
                slider("Чёткость", \.clarity, p)
                slider("Матовость", \.fade, p, range: 0...100)
            }
            group("Цвет") {
                slider("Температура", \.temperature, p, tint: .orange)
                slider("Оттенок", \.tint, p, tint: .pink)
                slider("Красочность", \.vibrance, p)
                slider("Насыщенность", \.saturation, p)
            }
            group("Тонирование") {
                hueSlider("Тени", hue: \.shadowHue, sat: \.shadowSat, p)
                hueSlider("Света", hue: \.highlightHue, sat: \.highlightSat, p)
            }
            group("Эффекты") {
                slider("Виньетка", \.vignette, p)
                slider("Зерно", \.grain, p, range: 0...100)
            }
        }
    }

    // MARK: - Стили

    private var openGroups: Set<String> {
        get { Set(openGroupsRaw.split(separator: "|").map(String.init)) }
    }

    private func toggleGroup(_ g: String) {
        var s = openGroups
        if s.contains(g) { s.remove(g) } else { s.insert(g) }
        openGroupsRaw = s.sorted().joined(separator: "|")
    }

    private var stylesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lib.styleGroups, id: \.name) { g in
                VStack(alignment: .leading, spacing: 8) {
                    Button { toggleGroup(g.name) } label: {
                        HStack {
                            Image(systemName: openGroups.contains(g.name) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.bold)).frame(width: 12)
                            Text(g.name).font(.subheadline.weight(.semibold))
                            Text("\(g.styles.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if openGroups.contains(g.name) {
                        if g.name == "Плёнка" && g.styles.contains(where: \.missingLUT) {
                            collectionCard(.t3mujin)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(g.styles) { st in styleChip(st) }
                        }
                    }
                }
            }
            Button {
                styleName = ""
                naming = true
            } label: {
                Label("Сохранить текущие настройки как стиль…", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(lib.current?.adj.isIdentity ?? true)
        }
    }

    private func styleChip(_ st: Style) -> some View {
        let active = lib.current?.adj == st.adj
        return Button { lib.applyStyle(st) } label: {
            VStack(spacing: 4) {
                StylePreview(photo: lib.current, adj: st.adj)
                Text(st.name).font(.caption).lineLimit(1)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : .white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(st.missingLUT)
        .opacity(st.missingLUT ? 0.4 : 1)
        .help(st.missingLUT ? "Скачайте коллекцию плёнки" : "Применить к выделенным")
        .contextMenu {
            if !st.builtIn { Button("Удалить стиль", role: .destructive) { lib.deleteStyle(st) } }
        }
    }

    // MARK: - LUT

    private func lutTab(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if p.adj.lut != nil {
                HStack {
                    Text(LUTStore.displayName(p.adj.lut!)).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Убрать") { var a = p.adj; a.lut = nil; lib.setAdjustments(a) }.controlSize(.small)
                }
                slider("Сила", \.lutAmount, p, range: 0...100, defaultValue: 100)
            }
            ForEach(LUTCollection.all, id: \.folder) { c in
                if c.installedCount == 0 { collectionCard(c) }
            }
            let groups = Dictionary(grouping: lib.luts, by: LUTStore.group)
            ForEach(groups.keys.sorted(), id: \.self) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(g).font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(groups[g] ?? [], id: \.self) { name in lutChip(name, p) }
                    }
                }
            }
            HStack {
                Button("Загрузить свои LUT…") { lib.importLUTs() }
                Button("Папка LUT") { lib.revealLUTFolder() }
            }
            .controlSize(.small)
            Text("Подходят .cube и HaldCLUT .png (например, коллекция RawTherapee Film Simulation).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func lutChip(_ name: String, _ p: Photo) -> some View {
        let active = p.adj.lut == name
        var preview = Adjustments()
        preview.lut = name
        return Button {
            var a = p.adj
            a.lut = active ? nil : name
            if !active && a.lutAmount == 0 { a.lutAmount = 100 }
            lib.setAdjustments(a)
        } label: {
            VStack(spacing: 4) {
                StylePreview(photo: p, adj: preview)
                Text(LUTStore.displayName(name)).font(.caption2).lineLimit(1)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : .white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(LUTStore.displayName(name))
    }

    private func collectionCard(_ c: LUTCollection) -> some View {
        let dl = lib.collections
        return VStack(alignment: .leading, spacing: 6) {
            Label(c.title, systemImage: "film").font(.callout.weight(.semibold))
            Text("51 эмуляция плёнки: Kodak Portra, Ektar, Gold, Fuji Pro 400H, Velvia, Provia, Ilford HP5, Tri-X… Автор \(c.author), лицензия \(c.license) — бесплатно. ~65 МБ.")
                .font(.caption).foregroundStyle(.secondary)
            if dl.busy {
                ProgressView(value: Double(dl.done), total: Double(max(dl.total, 1)))
                Text("Скачиваю \(dl.done) из \(dl.total)…").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Скачать") { lib.downloadCollection(c) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Link("Страница проекта", destination: c.page).font(.caption)
                }
                if let m = dl.message { Text(m).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }

    // MARK: - Действия

    private func actions(_ p: Photo) -> some View {
        @Bindable var lib = lib
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
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
                    .help("Показать снимок камеры без обработки (клавиша \\)")
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
                        tint: Color? = nil, format: ((Double) -> String)? = nil) -> some View {
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
                .tint(tint ?? .accentColor)
        }
    }

    /// Тонирование: оттенок (цветная полоса) и сила.
    private func hueSlider(_ title: String, hue: WritableKeyPath<Adjustments, Double>, sat: WritableKeyPath<Adjustments, Double>, _ p: Photo) -> some View {
        let h = p.adj[keyPath: hue], s = p.adj[keyPath: sat]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout).foregroundStyle(s == 0 ? .secondary : .primary)
                    .onTapGesture(count: 2) { var a = p.adj; a[keyPath: sat] = 0; lib.setAdjustments(a) }
                Circle().fill(Color(hue: h / 360, saturation: max(0.15, s / 100), brightness: 0.9)).frame(width: 10, height: 10)
                Spacer()
                Text(s == 0 ? "выкл" : "\(Int(h))° · \(Int(s))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1 / 6).map { Color(hue: $0, saturation: 0.7, brightness: 0.9) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4).clipShape(Capsule()).padding(.horizontal, 6)
                Slider(value: Binding(get: { h }, set: { v in
                    var a = p.adj
                    a[keyPath: hue] = v.rounded()
                    if a[keyPath: sat] == 0 { a[keyPath: sat] = 25 }
                    lib.setAdjustments(a)
                }), in: 0...360)
                .controlSize(.small)
                .tint(.clear)
            }
            Slider(value: Binding(get: { s }, set: { v in var a = p.adj; a[keyPath: sat] = v.rounded(); lib.setAdjustments(a) }), in: 0...100)
                .controlSize(.small)
        }
    }
}

/// Миниатюра текущего кадра с рецептом — видно, как ляжет стиль.
struct StylePreview: View {
    let photo: Photo?
    let adj: Adjustments
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.04)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: photo.map { ThumbKey(url: $0.url, adj: adj) }) {
            guard let url = photo?.url else { return }
            let a = adj
            if let c = Renderer.shared.cachedThumbnail(url, a, size: 220) { image = c; return }
            image = await Task.detached(priority: .utility) { Renderer.shared.thumbnail(url, a, size: 220) }.value
        }
    }
}
