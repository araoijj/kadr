import SwiftUI

/// Right panel: "Info" and "Edit" tabs.
struct Inspector: View {
    @Environment(Library.self) private var lib

    var body: some View {
        @Bindable var lib = lib
        VStack(spacing: 0) {
            Picker("", selection: $lib.inspectorTab) {
                Text(tr("Инфо")).tag(Library.InspectorTab.info)
                Text(tr("Обработка")).tag(Library.InspectorTab.edit)
                Text(tr("Журнал")).tag(Library.InspectorTab.history)
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
                Text(tr("Настройки")).tag(0)
                Text(tr("Стили")).tag(1)
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
                            Label(tr("Стили, вставка и сброс — для \(lib.targets.count) выделенных. Ползунки — для текущего кадра."),
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
                    Text(tr("Нет выбранного снимка")).foregroundStyle(.secondary).padding()
                }
            }
            Divider()
            if let p = lib.current { actions(p).padding(12) }
        }
        .sheet(isPresented: $newStyle) { NewStyleSheet().environment(lib) }
        .alert(tr("Переименовать стиль"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(tr("Название"), text: $renameText)
            Button(tr("Готово")) { if let st = renaming { lib.renameStyle(st, to: renameText) }; renaming = nil }
            Button(tr("Отмена"), role: .cancel) { renaming = nil }
        }
    }

    // MARK: - Settings

    private func sliders(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if lib.multiSelected {
                Toggle(isOn: Binding(get: { lib.syncEdits }, set: { lib.syncEdits = $0 })) {
                    Text(tr("Применять ко всем выделенным (\(lib.targets.count))")).font(.callout.weight(.semibold))
                }
                .toggleStyle(.switch)
                .help(tr("Ползунки, стиль и LUT меняют все выделенные кадры — только то, что вы двигаете. Кадрирование — у каждого своё."))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tr("Кадр")).font(.headline)
                    if p.adj.hasGeometry { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                    Spacer()
                    if p.adj.hasGeometry {
                        Button(tr("Сбросить")) { lib.resetCrop() }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                Button { lib.cropMode ? lib.finishCrop() : lib.startCrop() } label: {
                    Label(lib.cropMode ? tr("Готово (Enter)") : tr("Кадрировать и выровнять (R)"), systemImage: "crop")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text(p.adj.hasCrop ? tr("Формат: \(CropFormat.byID(p.adj.cropAspect)?.title ?? "свободный")") + (p.adj.angle != 0 ? String(format: tr(" · горизонт %+.1f°"), p.adj.angle) : "")
                     : tr("Форматы Instagram: пост 4:5, квадрат, сторис 9:16, горизонтальный 1.91:1."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { lib.removeMode ? lib.finishRemove() : lib.startRemove() } label: {
                Label(lib.removeMode ? tr("Готово") : tr("Убрать объект (AI)"), systemImage: "eraser").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!Retouch.shared.installed)
            .help(Retouch.shared.installed ? tr("Клик по лишнему объекту — AI выделит и закрасит его. Убранное хранится отдельно, ⌘Z возвращает.")
                                            : tr("Модели «Убрать объект» не установлены (Настройки → AI)"))
            if !p.adj.removals.isEmpty {
                HStack {
                    Text(tr("Убрано объектов: \(p.adj.removals.count)")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Вернуть все")) { var a = p.adj; a.removals = []; lib.setAdjustments(a) }.controlSize(.small)
                }
            }
            // AI noise reduction: computed once per photo (~1 min), then a strength slider.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(tr("AI-шумоподавление"), systemImage: "sparkles").font(.headline)
                    Spacer()
                }
                if lib.denoiseRunning {
                    ProgressView(value: (Double(lib.denoiseDone) + lib.denoiseFraction) / Double(max(lib.denoiseTotal, 1)))
                    HStack {
                        Text(tr("Кадр \(lib.denoiseDone + 1) из \(lib.denoiseTotal)…")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Стоп")) { lib.stopDenoise() }.controlSize(.small)
                    }
                } else if Denoiser.shared.hasResult(p.url) {
                    HStack {
                        Slider(value: Binding(get: { p.adj.aiDenoise }, set: { v in var a = p.adj; a.aiDenoise = v.rounded(); lib.setAdjustments(a) }), in: 0...100)
                        Text("\(Int(p.adj.aiDenoise))").font(.caption.monospacedDigit()).frame(width: 28)
                    }
                } else if Denoiser.shared.installed {
                    Button { lib.denoiseTargets() } label: {
                        Label(lib.multiSelected ? tr("Убрать шум у выделенных (\(lib.targets.count))") : tr("Убрать шум"), systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    Text(tr("Модель SCUNet на видеокарте: ~1 минута на кадр 24 Мп, потом — мгновенно. Света из RAW не теряются."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(tr("Модель шумоподавления не установлена (Настройки → AI)")).font(.caption).foregroundStyle(.secondary)
                }
            }
            section(tr("Профиль"), .profile, p) {
                Picker("", selection: Binding(get: { p.adj.profile }, set: { v in var a = p.adj; a.profile = v; lib.setAdjustments(a) })) {
                    Text(tr("Как в камере")).tag(Adjustments.Profile.camera)
                    Text(tr("Стандартный macOS")).tag(Adjustments.Profile.standard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(p.adj.profile == .camera
                     ? tr("Цвета подобраны по JPEG камеры — правки начинаются с привычной картинки.")
                     : tr("Проявление RAW движком macOS: свои цвета, могут отличаться от камеры."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            section(tr("Свет"), .light, p) {
                slider(tr("Экспозиция"), "sun.max", \.exposure, p, range: -5...5, step: 0.05) { String(format: "%+.2f EV", $0) }
                slider(tr("Контраст"), "circle.lefthalf.filled", \.contrast, p)
                slider(tr("Света"), "sun.max.fill", \.highlights, p)
                slider(tr("Тени"), "moon.fill", \.shadows, p)
                slider(tr("Чёткость"), "triangle", \.clarity, p)
                slider(tr("Матовость"), "cloud.fog", \.fade, p, range: 0...100)
            }
            section(tr("Цвет"), .color, p) {
                kelvinSlider(p)
                slider(tr("Оттенок"), "drop", \.tint, p, range: -150...150, gradient: [.green, .gray, .pink])
                slider(tr("Красочность"), "paintpalette", \.vibrance, p)
                slider(tr("Насыщенность"), "drop.fill", \.saturation, p, gradient: [.gray, .red])
            }
            section(tr("Тонирование"), .toning, p) {
                hueSlider(tr("Тени"), hue: \.shadowHue, sat: \.shadowSat, p)
                hueSlider(tr("Света"), hue: \.highlightHue, sat: \.highlightSat, p)
            }
            section(tr("Эффекты"), .effects, p) {
                slider(tr("Виньетка"), "circle.dashed", \.vignette, p, gradient: [.black, .gray, .white])
                slider(tr("Зерно"), "circle.grid.3x3", \.grain, p, range: 0...100)
            }
        }
    }

    // MARK: - Styles

    private var openGroups: Set<String> { Set(openGroupsRaw.split(separator: "|").map(String.init)) }

    private func toggleGroup(_ g: String) {
        var s = openGroups
        if s.contains(g) { s.remove(g) } else { s.insert(g) }
        openGroupsRaw = s.sorted().joined(separator: "|")
    }

    private func stylesTab(_ p: Photo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { newStyle = true } label: {
                Label(tr("Новый стиль из текущих настроек…"), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(p.adj.isIdentity)
            .help(p.adj.isIdentity ? tr("Сначала настройте кадр ползунками") : tr("Сохранить настройки кадра как свой пресет"))

            ForEach(lib.styleGroups, id: \.name) { g in
                VStack(alignment: .leading, spacing: 8) {
                    Button { toggleGroup(g.name) } label: {
                        HStack {
                            Image(systemName: openGroups.contains(g.name) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.bold)).frame(width: 12)
                            Text(tr(g.name)).font(.subheadline.weight(.semibold))
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
                Button(tr("Экспорт своих…")) { lib.exportStyles() }
                Button(tr("Импорт…")) { lib.importStyles() }
            }
            .controlSize(.small)
        }
    }

    private func styleChip(_ st: Style, _ p: Photo) -> some View {
        let active = st.groups.count < StyleGroup.allCases.count ? p.adj.matches(st.adj, groups: st.groups) && !p.adj.isIdentity : p.adj == st.adj
        // Previews apply the style to the unedited frame and ignore the sliders; otherwise every slider move
        // would redraw all previews and hog the CPU.
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
        .help(st.missingLUT ? tr("Скачайте коллекцию плёнки") :
              st.groups.count < StyleGroup.allCases.count ? tr("Меняет только: ") + st.groups.map(\.title).sorted().joined(separator: ", ") : tr("Применить к выделенным"))
        .contextMenu {
            Button(tr("Применить")) { lib.applyStyle(st) }
            if !st.builtIn {
                Divider()
                Button(tr("Обновить из текущего кадра")) { lib.updateStyle(st) }
                Button(tr("Переименовать…")) { renameText = st.name; renaming = st }
                Button(tr("Удалить стиль"), role: .destructive) { lib.deleteStyle(st) }
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
                    Button(tr("Убрать")) { var a = p.adj; a.lut = nil; lib.setAdjustments(a) }.controlSize(.small)
                }
                slider(tr("Сила"), "slider.horizontal.below.square.filled.and.square", \.lutAmount, p, range: 0...200, defaultValue: 100) { "\(Int($0))%" }
                HStack {
                    Text(tr("0 — без LUT, 100 — как задумано, 200 — усиленно")).font(.caption2).foregroundStyle(.secondary)
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
                Button(tr("Загрузить свои LUT…")) { lib.importLUTs() }
                Button(tr("Папка LUT")) { lib.revealLUTFolder() }
            }
            .controlSize(.small)
            Text(tr("Подходят .cube и HaldCLUT .png (например, коллекция RawTherapee Film Simulation)."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func lutChip(_ name: String, _ p: Photo) -> some View {
        let active = p.adj.lut == name
        var preview = Adjustments()   // LUT on the unedited frame at full strength, independent of the sliders
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
            Text(tr("51 эмуляция плёнки: Kodak Portra, Ektar, Gold, Fuji Pro 400H, Velvia, Provia, Ilford HP5, Tri-X… Автор \(c.author), лицензия \(c.license) — бесплатно. ~65 МБ."))
                .font(.caption).foregroundStyle(.secondary)
            if dl.busy {
                ProgressView(value: Double(dl.done), total: Double(max(dl.total, 1)))
                Text(tr("Скачиваю \(dl.done) из \(dl.total)…")).font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(tr("Скачать")) { lib.downloadCollection(c) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Link(tr("Страница проекта"), destination: c.page).font(.caption)
                }
                if let m = dl.message { Text(m).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }

    // MARK: - Actions (always at the bottom of the panel)

    private func actions(_ p: Photo) -> some View {
        @Bindable var lib = lib
        return HStack(spacing: 6) {
            Toggle(isOn: $lib.showOriginal) { Image(systemName: "rectangle.lefthalf.inset.filled") }
                .toggleStyle(.button)
                .help(tr("Показать снимок камеры без обработки (клавиша \\)"))
            Button { lib.copyAdjustments() } label: { Image(systemName: "doc.on.doc") }
                .help(tr("Копировать обработку (⌘⇧C)"))
            Button { lib.matchToCurrent() } label: { Image(systemName: "equal.square") }
                .help(tr("Выровнять экспозицию и баланс выделенных (или серии) по этому кадру (⌥⌘M)"))
            Button { lib.pasteAdjustments() } label: { Image(systemName: "doc.on.clipboard") }
                .disabled(lib.copiedAdj == nil)
                .help(tr("Вставить обработку на выделенные (⌘⇧V)"))
            Button { newStyle = true } label: { Image(systemName: "plus.square.on.square") }
                .disabled(p.adj.isIdentity)
                .help(tr("Сохранить как стиль"))
            Spacer()
            Button(role: .destructive) { lib.resetAdjustments() } label: { Label(tr("Исходник"), systemImage: "arrow.counterclockwise").fixedSize() }
                .help(tr("Вернуть кадр как снято: сбросить всю обработку и кадрирование (⌥⌘R)"))
                .disabled(lib.targets.allSatisfy(\.adj.isIdentity))
        }
        .controlSize(.regular)
    }

    // MARK: - Components

    /// Section with a header; if it has edits, shows a "Reset section" button.
    private func section<C: View>(_ title: String, _ group: StyleGroup, _ p: Photo, @ViewBuilder _ content: () -> C) -> some View {
        let changed = p.adj.changedGroups.contains(group)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                if changed { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help(tr("В разделе есть правки")) }
                Spacer()
                if changed {
                    Button(tr("Сбросить")) {
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

    /// Slider: icon, name, value, reset button; double-clicking the name also resets.
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
                .help(tr("Сбросить"))
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

    /// White balance in kelvins, as in Lightroom and Capture One. The starting point is "as shot" from the RAW.
    private func kelvinSlider(_ p: Photo) -> some View {
        let asShot = ImageStore.shared.asShotK(p.url)
        let k = asShot + p.adj.wbShift
        let changed = p.adj.wbShift != 0
        let isRaw = ImageStore.rawExtensions.contains(p.url.pathExtension.lowercased())
        let range = min(2000, k)...max(12000, k)
        let binding = Binding<Double>(get: { k }, set: { v in
            var a = p.adj
            a.wbShift = ((v - asShot) / 50).rounded() * 50   // 50 K step
            lib.setAdjustments(a)
        })
        func fmt(_ v: Double) -> String { "\(Int(v.rounded()).formatted(.number.grouping(.never))) K" }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").frame(width: 18).foregroundStyle(changed ? Color.accentColor : .secondary)
                Text(tr("Температура")).foregroundStyle(changed ? .primary : .secondary)
                    .onTapGesture(count: 2) { binding.wrappedValue = asShot }
                Spacer()
                Text(fmt(k)).font(.callout.monospacedDigit().weight(changed ? .semibold : .regular))
                    .foregroundStyle(changed ? .primary : .secondary)
                Button { binding.wrappedValue = asShot } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(changed ? 1 : 0).disabled(!changed)
                    .help(tr("Как снято"))
            }
            ZStack {
                LinearGradient(colors: [.blue, .gray, .orange], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4).clipShape(Capsule()).opacity(0.7).padding(.horizontal, 2)
                Slider(value: binding, in: range).tint(.clear)
            }
            HStack {
                Text(isRaw ? tr("Как снято: \(fmt(asShot))") : tr("Не RAW: сдвиг от 5500 K")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if changed {
                    Text(String(format: "%+.0f K", p.adj.wbShift)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Toning: hue (color strip) and strength.
    private func hueSlider(_ title: String, hue: WritableKeyPath<Adjustments, Double>, sat: WritableKeyPath<Adjustments, Double>, _ p: Photo) -> some View {
        let h = p.adj[keyPath: hue], s = p.adj[keyPath: sat]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(hue: h / 360, saturation: max(0.15, s / 100), brightness: 0.9)).frame(width: 14, height: 14)
                Text(title).font(.body).foregroundStyle(s == 0 ? .secondary : .primary)
                Spacer()
                Text(s == 0 ? tr("выкл") : tr("\(Int(h))° · сила \(Int(s))")).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
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
                Text(tr("Сила")).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                Slider(value: Binding(get: { s }, set: { v in var a = p.adj; a[keyPath: sat] = v.rounded(); lib.setAdjustments(a) }), in: 0...100)
            }
        }
    }
}

/// "New style" sheet, like "New Preset" in Lightroom: name, collection and which sections to save.
struct NewStyleSheet: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var collection = "Мои стили"
    @State private var groups: Set<StyleGroup> = []

    var body: some View {
        let changed = lib.current?.adj.changedGroups ?? []
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Новый стиль")).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Название")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                TextField(tr("Например, «Мой свадебный»"), text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Коллекция")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField(tr("Мои стили"), text: $collection).textFieldStyle(.roundedBorder)
                    Menu(tr("Выбрать")) {
                        ForEach(lib.userCollections, id: \.self) { c in Button(tr(c)) { collection = c } }
                    }
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Что сохранить в стиль")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(StyleGroup.allCases) { g in
                    Toggle(isOn: Binding(get: { groups.contains(g) }, set: { if $0 { groups.insert(g) } else { groups.remove(g) } })) {
                        HStack {
                            Text(g.title)
                            if changed.contains(g) { Text(tr("изменено")).font(.caption).foregroundStyle(Color.accentColor) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Text(tr("Невыбранные разделы стиль не трогает: например, стиль только с «Цвет» сохранит вашу экспозицию."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(tr("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Сохранить стиль")) {
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

/// Thumbnail of the current frame with the recipe applied, to preview how the style will look.
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

/// Hold to see the frame without the LUT; release to bring it back.
struct LUTPeek: View {
    @Environment(Library.self) private var lib
    @State private var saved: Adjustments?

    var body: some View {
        Text(tr("Сравнить"))
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
            .help(tr("Зажмите — без LUT"))
    }
}
