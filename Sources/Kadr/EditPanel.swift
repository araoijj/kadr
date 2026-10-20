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
                Text("Журнал").tag(Library.InspectorTab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            HistogramView(photo: lib.current)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            switch lib.inspectorTab {
            case .info: InfoPanel()
            case .edit: EditPanel()
            case .history: HistoryPanel()
            }
        }
    }
}

struct EditPanel: View {
    @Environment(Library.self) private var lib
    @State private var newStyle = false
    @State private var renaming: Style?
    @State private var renameText = ""
    @AppStorage("ep.open") private var openGroupsRaw = "Мои стили|Базовые"
    @AppStorage("ep.tab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Настройки").tag(0)
                Text("Стили").tag(1)
                Text("LUT").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollView {
                if let p = lib.current {
                    VStack(alignment: .leading, spacing: 20) {
                        if lib.multiSelected {
                            Label("Стили, вставка и сброс — для \(lib.targets.count) выделенных. Ползунки — для текущего кадра.",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        switch tab {
                        case 1: stylesTab(p)
                        case 2: lutTab(p)
                        default: sliders(p)
                        }
                    }
                    .padding(16)
                } else {
                    Text("Нет выбранного снимка").foregroundStyle(.secondary).padding()
                }
            }
            Divider()
            if let p = lib.current { actions(p).padding(12) }
        }
        .sheet(isPresented: $newStyle) { NewStyleSheet().environment(lib) }
        .alert("Переименовать стиль", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Готово") { if let st = renaming { lib.renameStyle(st, to: renameText) }; renaming = nil }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Настройки

    private func sliders(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Кадр").font(.headline)
                    if p.adj.hasGeometry { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Spacer()
                    if p.adj.hasGeometry {
                        Button("Сбросить") { lib.resetCrop() }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                Button { lib.cropMode ? lib.finishCrop() : lib.startCrop() } label: {
                    Label(lib.cropMode ? "Готово (Enter)" : "Кадрировать и выровнять (R)", systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text(p.adj.hasCrop ? "Формат: \(CropFormat.byID(p.adj.cropAspect)?.title ?? "свободный")" + (p.adj.angle != 0 ? String(format: " · горизонт %+.1f°", p.adj.angle) : "")
                     : "Форматы Instagram: пост 4:5, квадрат, сторис 9:16, горизонтальный 1.91:1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            section("Профиль", .profile, p) {
                Picker("", selection: Binding(get: { p.adj.profile }, set: { v in var a = p.adj; a.profile = v; lib.setAdjustments(a) })) {
                    Text("Как в камере").tag(Adjustments.Profile.camera)
                    Text("Стандартный macOS").tag(Adjustments.Profile.standard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(p.adj.profile == .camera
                     ? "Цвета подобраны по JPEG камеры — правки начинаются с привычной картинки."
                     : "Проявление RAW движком macOS: свои цвета, могут отличаться от камеры.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            section("Свет", .light, p) {
                slider("Экспозиция", "sun.max", \.exposure, p, range: -5...5, step: 0.05) { String(format: "%+.2f EV", $0) }
                slider("Контраст", "circle.lefthalf.filled", \.contrast, p)
                slider("Света", "sun.max.fill", \.highlights, p)
                slider("Тени", "moon.fill", \.shadows, p)
                slider("Чёткость", "triangle", \.clarity, p)
                slider("Матовость", "cloud.fog", \.fade, p, range: 0...100)
            }
            section("Цвет", .color, p) {
                kelvinSlider(p)
                slider("Оттенок", "drop", \.tint, p, range: -150...150, gradient: [.green, .gray, .pink])
                slider("Красочность", "paintpalette", \.vibrance, p)
                slider("Насыщенность", "drop.fill", \.saturation, p, gradient: [.gray, .red])
            }
            section("Тонирование", .toning, p) {
                hueSlider("Тени", hue: \.shadowHue, sat: \.shadowSat, p)
                hueSlider("Света", hue: \.highlightHue, sat: \.highlightSat, p)
            }
            section("Эффекты", .effects, p) {
                slider("Виньетка", "circle.dashed", \.vignette, p, gradient: [.black, .gray, .white])
                slider("Зерно", "circle.grid.3x3", \.grain, p, range: 0...100)
            }
        }
    }

    // MARK: - Стили

    private var openGroups: Set<String> { Set(openGroupsRaw.split(separator: "|").map(String.init)) }

    private func toggleGroup(_ g: String) {
        var s = openGroups
        if s.contains(g) { s.remove(g) } else { s.insert(g) }
        openGroupsRaw = s.sorted().joined(separator: "|")
    }

    private func stylesTab(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { newStyle = true } label: {
                Label("Новый стиль из текущих настроек…", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(p.adj.isIdentity)
            .help(p.adj.isIdentity ? "Сначала настройте кадр ползунками" : "Сохранить настройки кадра как свой пресет")

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
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(g.styles) { st in styleChip(st, p) }
                        }
                    }
                }
            }
            HStack {
                Button("Экспорт своих…") { lib.exportStyles() }
                Button("Импорт…") { lib.importStyles() }
            }
            .controlSize(.small)
        }
    }

    private func styleChip(_ st: Style, _ p: Photo) -> some View {
        let active = st.groups.count < StyleGroup.allCases.count ? p.adj.matches(st.adj, groups: st.groups) && !p.adj.isIdentity : p.adj == st.adj
        // Превью — стиль на чистом кадре: не зависит от ползунков, иначе каждое их движение
        // перерисовывало бы все превью и забивало процессор.
        var result = Adjustments()
        result.merge(st.adj, groups: st.groups)
        return Button { lib.applyStyle(st) } label: {
            VStack(spacing: 4) {
                StylePreview(photo: p, adj: result)
                HStack(spacing: 3) {
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    Text(st.name).lineLimit(1)
                }
                .font(.caption)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : .white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(st.missingLUT)
        .opacity(st.missingLUT ? 0.4 : 1)
        .help(st.missingLUT ? "Скачайте коллекцию плёнки" :
              st.groups.count < StyleGroup.allCases.count ? "Меняет только: " + st.groups.map(\.title).sorted().joined(separator: ", ") : "Применить к выделенным")
        .contextMenu {
            Button("Применить") { lib.applyStyle(st) }
            if !st.builtIn {
                Divider()
                Button("Обновить из текущего кадра") { lib.updateStyle(st) }
                Button("Переименовать…") { renameText = st.name; renaming = st }
                Button("Удалить стиль", role: .destructive) { lib.deleteStyle(st) }
            }
        }
    }

    // MARK: - LUT

    private func lutTab(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lut = p.adj.lut {
                HStack {
                    Text(LUTStore.displayName(lut)).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Убрать") { var a = p.adj; a.lut = nil; lib.setAdjustments(a) }.controlSize(.small)
                }
                slider("Сила", "slider.horizontal.below.square.filled.and.square", \.lutAmount, p, range: 0...200, defaultValue: 100) { "\(Int($0))%" }
                HStack {
                    Text("0 — без LUT, 100 — как задумано, 200 — усиленно").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    LUTPeek()
                }
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
        var preview = Adjustments()   // LUT на чистом кадре, в полную силу — не зависит от ползунков
        preview.lut = name
        return Button {
            var a = p.adj
            a.lut = active ? nil : name
            if !active && a.lutAmount == 0 { a.lutAmount = 100 }
            lib.setAdjustments(a)
        } label: {
            VStack(spacing: 4) {
                StylePreview(photo: p, adj: preview)
                HStack(spacing: 3) {
                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    Text(LUTStore.displayName(name)).lineLimit(1)
                }
                .font(.caption2)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : .white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5))
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

    // MARK: - Действия (всегда внизу панели)

    private func actions(_ p: Photo) -> some View {
        @Bindable var lib = lib
        return HStack(spacing: 6) {
            Toggle(isOn: $lib.showOriginal) { Image(systemName: "rectangle.lefthalf.inset.filled") }
                .toggleStyle(.button)
                .help("Показать снимок камеры без обработки (клавиша \\)")
            Button { lib.copyAdjustments() } label: { Image(systemName: "doc.on.doc") }
                .help("Копировать обработку (⌘⇧C)")
            Button { lib.pasteAdjustments() } label: { Image(systemName: "doc.on.clipboard") }
                .disabled(lib.copiedAdj == nil)
                .help("Вставить обработку на выделенные (⌘⇧V)")
            Button { newStyle = true } label: { Image(systemName: "plus.square.on.square") }
                .disabled(p.adj.isIdentity)
                .help("Сохранить как стиль")
            Spacer()
            Button(role: .destructive) { lib.resetAdjustments() } label: { Label("Исходник", systemImage: "arrow.counterclockwise").fixedSize() }
                .help("Вернуть кадр как снято: сбросить всю обработку и кадрирование (⌥⌘R)")
                .disabled(lib.targets.allSatisfy(\.adj.isIdentity))
        }
        .controlSize(.regular)
    }

    // MARK: - Компоненты

    /// Раздел с заголовком; если в нём есть правки — кнопка «сбросить раздел».
    private func section<C: View>(_ title: String, _ group: StyleGroup, _ p: Photo, @ViewBuilder _ content: () -> C) -> some View {
        let changed = p.adj.changedGroups.contains(group)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                if changed { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("В разделе есть правки") }
                Spacer()
                if changed {
                    Button("Сбросить") {
                        var a = p.adj
                        a.merge(Adjustments(), groups: [group])
                        lib.setAdjustments(a)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
            }
            content()
        }
    }

    /// Ползунок: значок, название, значение, кнопка сброса; двойной клик по названию — тоже сброс.
    private func slider(_ title: String, _ icon: String, _ key: WritableKeyPath<Adjustments, Double>, _ p: Photo,
                        range: ClosedRange<Double> = -100...100, step: Double = 1, defaultValue: Double = 0,
                        gradient: [Color]? = nil, format: ((Double) -> String)? = nil) -> some View {
        let value = p.adj[keyPath: key]
        let changed = value != defaultValue
        let binding = Binding<Double>(get: { value }, set: { v in
            var a = p.adj
            a[keyPath: key] = (v / step).rounded() * step
            lib.setAdjustments(a)
        })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(changed ? Color.accentColor : .secondary)
                Text(title)
                    .font(.body)
                    .foregroundStyle(changed ? .primary : .secondary)
                    .onTapGesture(count: 2) { binding.wrappedValue = defaultValue }
                Spacer()
                Text(format?(value) ?? (value == 0 ? "0" : String(format: range.lowerBound < 0 ? "%+.0f" : "%.0f", value)))
                    .font(.callout.monospacedDigit().weight(changed ? .semibold : .regular))
                    .foregroundStyle(changed ? .primary : .secondary)
                Button { binding.wrappedValue = defaultValue } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
                .help("Сбросить")
            }
            ZStack {
                if let gradient {
                    LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 4).clipShape(Capsule()).opacity(0.7).padding(.horizontal, 2)
                }
                Slider(value: binding, in: range)
                    .tint(gradient == nil ? .accentColor : .clear)
            }
        }
    }

    /// Баланс белого в кельвинах, как в Lightroom и Capture One. Исходная точка — «как снято» из RAW.
    private func kelvinSlider(_ p: Photo) -> some View {
        let asShot = ImageStore.shared.asShotK(p.url)
        let k = asShot + p.adj.wbShift
        let changed = p.adj.wbShift != 0
        let isRaw = ImageStore.rawExtensions.contains(p.url.pathExtension.lowercased())
        let range = min(2000, k)...max(12000, k)
        let binding = Binding<Double>(get: { k }, set: { v in
            var a = p.adj
            a.wbShift = ((v - asShot) / 50).rounded() * 50   // шаг 50 K
            lib.setAdjustments(a)
        })
        func fmt(_ v: Double) -> String { "\(Int(v.rounded()).formatted(.number.grouping(.never))) K" }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").frame(width: 18).foregroundStyle(changed ? Color.accentColor : .secondary)
                Text("Температура").foregroundStyle(changed ? .primary : .secondary)
                    .onTapGesture(count: 2) { binding.wrappedValue = asShot }
                Spacer()
                Text(fmt(k)).font(.callout.monospacedDigit().weight(changed ? .semibold : .regular))
                    .foregroundStyle(changed ? .primary : .secondary)
                Button { binding.wrappedValue = asShot } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(changed ? 1 : 0).disabled(!changed)
                    .help("Как снято")
            }
            ZStack {
                LinearGradient(colors: [.blue, .gray, .orange], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4).clipShape(Capsule()).opacity(0.7).padding(.horizontal, 2)
                Slider(value: binding, in: range).tint(.clear)
            }
            HStack {
                Text(isRaw ? "Как снято: \(fmt(asShot))" : "Не RAW: сдвиг от 5500 K").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if changed {
                    Text(String(format: "%+.0f K", p.adj.wbShift)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Тонирование: оттенок (цветная полоса) и сила.
    private func hueSlider(_ title: String, hue: WritableKeyPath<Adjustments, Double>, sat: WritableKeyPath<Adjustments, Double>, _ p: Photo) -> some View {
        let h = p.adj[keyPath: hue], s = p.adj[keyPath: sat]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(hue: h / 360, saturation: max(0.15, s / 100), brightness: 0.9)).frame(width: 14, height: 14)
                Text(title).font(.body).foregroundStyle(s == 0 ? .secondary : .primary)
                Spacer()
                Text(s == 0 ? "выкл" : "\(Int(h))° · сила \(Int(s))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button { var a = p.adj; a[keyPath: sat] = 0; lib.setAdjustments(a) } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(s == 0 ? 0 : 1).disabled(s == 0)
            }
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1 / 6).map { Color(hue: $0, saturation: 0.75, brightness: 0.95) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 6).clipShape(Capsule()).padding(.horizontal, 2)
                Slider(value: Binding(get: { h }, set: { v in
                    var a = p.adj
                    a[keyPath: hue] = v.rounded()
                    if a[keyPath: sat] == 0 { a[keyPath: sat] = 30 }
                    lib.setAdjustments(a)
                }), in: 0...360)
                .tint(.clear)
            }
            HStack(spacing: 6) {
                Text("Сила").font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Slider(value: Binding(get: { s }, set: { v in var a = p.adj; a[keyPath: sat] = v.rounded(); lib.setAdjustments(a) }), in: 0...100)
            }
        }
    }
}

/// Окно «Новый стиль» — как «Новый пресет» в Lightroom: название, коллекция и какие разделы сохранять.
struct NewStyleSheet: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var collection = "Мои стили"
    @State private var groups: Set<StyleGroup> = []

    var body: some View {
        let changed = lib.current?.adj.changedGroups ?? []
        VStack(alignment: .leading, spacing: 18) {
            Text("Новый стиль").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Название").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Например, «Мой свадебный»", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Коллекция").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField("Мои стили", text: $collection).textFieldStyle(.roundedBorder)
                    Menu("Выбрать") {
                        ForEach(lib.userCollections, id: \.self) { c in Button(c) { collection = c } }
                    }
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Что сохранить в стиль").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(StyleGroup.allCases) { g in
                    Toggle(isOn: Binding(get: { groups.contains(g) }, set: { if $0 { groups.insert(g) } else { groups.remove(g) } })) {
                        HStack {
                            Text(g.title)
                            if changed.contains(g) { Text("изменено").font(.caption).foregroundStyle(Color.accentColor) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text("Невыбранные разделы стиль не трогает: например, стиль только с «Цвет» сохранит вашу экспозицию.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить стиль") {
                    lib.createStyle(name: name, groups: groups, collection: collection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || groups.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { groups = changed.isEmpty ? Set(StyleGroup.allCases) : changed }
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
        .frame(height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: photo.map { ThumbKey(url: $0.url, adj: adj) }) {
            guard let url = photo?.url else { return }
            let a = adj
            if let c = Renderer.shared.cachedThumbnail(url, a, size: 220) { image = c; return }
            image = await Task.detached(priority: .utility) { Renderer.shared.thumbnail(url, a, size: 220) }.value
        }
    }
}

/// Зажмите, чтобы увидеть кадр без LUT, — отпустите, чтобы вернуть.
struct LUTPeek: View {
    @Environment(Library.self) private var lib
    @State private var saved: Adjustments?

    var body: some View {
        Text("Сравнить")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(saved != nil ? Color.accentColor.opacity(0.4) : .white.opacity(0.1)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard saved == nil, let a = lib.current?.adj else { return }
                    saved = a
                    var b = a; b.lutAmount = 0
                    lib.withoutHistory { lib.setAdjustments(b) }
                }
                .onEnded { _ in
                    if let a = saved { lib.withoutHistory { lib.setAdjustments(a) } }
                    saved = nil
                })
            .help("Зажмите — без LUT")
    }
}
