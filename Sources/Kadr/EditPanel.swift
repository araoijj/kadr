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
            .tabs()
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
    // As-shot white balance and RAW engine defaults of the current frame: reading them opens the RAW
    // (tens of ms), so it happens in the task below, off the main thread; this only triggers the redraw.
    @State private var rawInfoFor: URL?

    var body: some View {
        let _ = rawInfoFor   // read here, so filling the cache redraws the panel
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(tr("Настройки")).tag(0)
                Text(tr("Стили")).tag(1)
                Text("LUT").tag(2)
            }
            .tabs()
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
        .task(id: lib.current?.url) {
            guard let url = lib.current?.url else { return }
            if ImageStore.shared.cachedRawDefaults(url) == nil || ImageStore.shared.cachedAsShotK(url) == nil {
                await Task.detached(priority: .userInitiated) {
                    _ = ImageStore.shared.asShotK(url)
                    _ = ImageStore.shared.rawDefaults(url)
                }.value
            }
            rawInfoFor = url   // also when another path filled the cache after this body ran
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
            if lib.removeMode {
                // Active tool: a filled button and a line saying what clicks on the photo do now.
                Button { lib.finishRemove() } label: {
                    Label(tr("Выйти из «Убрать объект» (Esc)"), systemImage: "eraser.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Text(tr("Режим включён: клик по фото выделяет объект, Enter — убрать."))
                    .font(.caption).foregroundStyle(Color.accentColor)
            } else {
                Button { lib.startRemove() } label: {
                    Label(tr("Убрать объект (AI)"), systemImage: "eraser").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!Retouch.shared.installed || lib.current == nil)
                .help(Retouch.shared.installed ? tr("Клик по лишнему объекту — AI выделит и закрасит его. Убранное хранится отдельно, ⌘Z возвращает.")
                                                : tr("Модели «Убрать объект» не установлены (Настройки → AI)"))
            }
            if !p.adj.removals.isEmpty {
                HStack {
                    Text(tr("Убрано объектов: \(p.adj.removals.count)")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Вернуть все")) { var a = p.adj; a.removals = []; lib.setAdjustments(a) }.controlSize(.small)
                }
                if p.adj.removals.contains(where: { $0.isStale(p.url, p.adj.raw) }) {
                    Label(tr("Объекты убраны до смены настроек RAW — заплатки могут не совпасть с кадром. Верните и уберите заново."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            // AI noise reduction: computed once per photo (~1 min), then a strength slider.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(tr("AI-шумоподавление"), systemImage: "sparkles").font(.headline)
                    Spacer()
                    // State at a glance: what this photo has right now.
                    Text(denoiseState(p)).font(.caption.weight(.semibold))
                        .foregroundStyle(p.adj.aiDenoise > 0 && Denoiser.shared.hasResult(p.url, p.adj.raw) ? Color.accentColor : .secondary)
                }
                if lib.denoiseRunning {
                    ProgressView(value: (Double(lib.denoiseDone) + lib.denoiseFraction) / Double(max(lib.denoiseTotal, 1)))
                    HStack {
                        Text(tr("Кадр \(lib.denoiseDone + 1) из \(lib.denoiseTotal)…")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Стоп")) { lib.stopDenoise() }.controlSize(.small)
                    }
                } else if Denoiser.shared.hasResult(p.url, p.adj.raw) {
                    Toggle(tr("Применить к этому кадру"), isOn: Binding(get: { p.adj.aiDenoise > 0 }, set: { on in
                        var a = p.adj; a.aiDenoise = on ? 70 : 0; lib.setAdjustments(a)
                    }))
                    .toggleStyle(.switch)
                    HStack {
                        Slider(value: Binding(get: { p.adj.aiDenoise }, set: { v in var a = p.adj; a.aiDenoise = v.rounded(); lib.setAdjustments(a) }), in: 0...100)
                        Text("\(Int(p.adj.aiDenoise))").font(.caption.monospacedDigit()).frame(width: 28)
                    }
                    .disabled(p.adj.aiDenoise == 0)
                } else if Denoiser.shared.installed {
                    Button { lib.denoiseTargets() } label: {
                        Label(lib.multiSelected ? tr("Убрать шум у выделенных (\(lib.targets.count))") : tr("Убрать шум"), systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    Text(tr("Запускается только этой кнопкой. Модель SCUNet на видеокарте: ~1 минута на кадр 24 Мп, потом — мгновенно. Света из RAW не теряются."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(tr("Модель шумоподавления не установлена (Настройки → AI)")).font(.caption).foregroundStyle(.secondary)
                }
            }
            section(tr("Профиль"), .profile, p) {
                // Short names: a segmented control never shrinks below its labels, and the long ones
                // pushed the whole panel wider than a narrow inspector.
                ChoiceSegments(selection: Binding(get: { p.adj.profile }, set: { v in var a = p.adj; a.profile = v; lib.setAdjustments(a) }),
                               options: [(Adjustments.Profile.camera, tr("Камера")), (.standard, "macOS")])
                .help(tr("Камера — цвета как в JPEG камеры; macOS — проявление RAW движком macOS как есть"))
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
            section(tr("Проявка и детали"), .detail, p) {
                DetailPreview(photo: p)
                if let d = rawDefaults(p) {
                    rawControls(p, d)
                }
                slider(tr("Резкость"), "righttriangle", \.sharpen, p, range: 0...100)
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
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : Theme.fill))
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
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : Theme.fill))
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
            Spacer(minLength: 4)
            // Caption when there is room, the icon alone in a narrow inspector.
            ViewThatFits(in: .horizontal) {
                resetButton(caption: true)
                resetButton(caption: false)
            }
        }
    }

    private func resetButton(caption: Bool) -> some View {
        Button(role: .destructive) { lib.resetAdjustments() } label: {
            if caption { Label(tr("Исходник"), systemImage: "arrow.counterclockwise").fixedSize() }
            else { Image(systemName: "arrow.counterclockwise") }
        }
        .help(tr("Вернуть кадр как снято: сбросить всю обработку и кадрирование (⌥⌘R)"))
        .disabled(lib.targets.allSatisfy(\.adj.isIdentity))
        .controlSize(.regular)
    }

    // MARK: - Components

    /// Section with a header; if it has edits, shows a "Reset section" button.
    /// "Off", "Computing…", "Computed, off" or "On · 70" — for the denoise header.
    private func denoiseState(_ p: Photo) -> String {
        if lib.denoiseRunning { return tr("считается…") }
        guard Denoiser.shared.hasResult(p.url, p.adj.raw) else { return tr("не применено") }
        return p.adj.aiDenoise > 0 ? tr("включено · \(Int(p.adj.aiDenoise))") : tr("посчитано, выключено")
    }

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
                    Slider(value: binding, in: range).tint(.clear)
                } else if range.lowerBound < 0 {
                    BipolarSlider(value: binding, range: range)   // 0 in the middle: no fill at 0
                } else {
                    Slider(value: binding, in: range)
                }
            }
        }
    }

    /// Settings of the macOS RAW engine. They need the RAW to be developed again (~0.2–0.5 s),
    /// so the sliders apply on release instead of on every move.
    @ViewBuilder
    private func rawControls(_ p: Photo, _ d: RawDevelop.Defaults) -> some View {
        let set: (WritableKeyPath<RawDevelop, Double?>, Double?) -> Void = { key, v in
            var a = p.adj
            a.raw[keyPath: key] = v
            lib.setAdjustments(a)
        }
        if d.nrSupported {
            EngineSlider(title: tr("Шум: яркость"), icon: "aqi.low", value: p.adj.raw.lumaNR, defaultValue: d.lumaNR) { set(\.lumaNR, $0) }
            EngineSlider(title: tr("Шум: цвет"), icon: "aqi.medium", value: p.adj.raw.colorNR, defaultValue: d.colorNR) { set(\.colorNR, $0) }
        }
        if d.detailSupported {
            EngineSlider(title: tr("Детализация"), icon: "circle.grid.cross", value: p.adj.raw.detail, defaultValue: d.detail) { set(\.detail, $0) }
        }
        if d.moireSupported {
            EngineSlider(title: tr("Муар"), icon: "water.waves", value: p.adj.raw.moire, defaultValue: d.moire) { set(\.moire, $0) }
        }
        EngineSlider(title: tr("Кривая движка"), icon: "point.topleft.down.to.point.bottomright.curvepath", value: p.adj.raw.curve, defaultValue: d.curve) { set(\.curve, $0) }
            .help(tr("Сила стандартной тональной кривой macOS. Меньше — мягче контраст и больше запаса в светах и тенях, удобно тянуть дальше «Светом»."))
        EngineSlider(title: tr("Подъём теней"), icon: "moon.haze", value: p.adj.raw.shadowLift, defaultValue: d.shadowLift, range: 0...200) { set(\.shadowLift, $0) }
            .disabled((p.adj.raw.curve ?? d.curve) == 0)
        if d.lensSupported {
            Toggle(tr("Коррекция объектива"), isOn: Binding(get: { p.adj.raw.lens ?? d.lens }, set: { v in
                var a = p.adj; a.raw.lens = v == d.lens ? nil : v; lib.setAdjustments(a)
            }))
            .help(tr("Дисторсия и виньетирование по данным объектива из файла"))
        }
        if d.highlightRecoverySupported {
            Toggle(tr("Восстановление светов"), isOn: Binding(get: { p.adj.raw.highlightRecovery ?? d.highlightRecovery }, set: { v in
                var a = p.adj; a.raw.highlightRecovery = v == d.highlightRecovery ? nil : v; lib.setAdjustments(a)
            }))
            .help(tr("Достраивает пересвеченные участки по уцелевшим каналам"))
        }
        Text(tr("Шум, детализация, муар и резкость видны только в масштабе 1:1 — в окошке выше (его можно двигать) или с зумом 100% (Z). Ползунки проявки применяются, когда отпускаете их."))
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Only from the cache, filled by the panel's task.
    private func rawDefaults(_ p: Photo) -> RawDevelop.Defaults? {
        return ImageStore.shared.cachedRawDefaults(p.url) ?? nil
    }

    /// White balance in kelvins, as in Lightroom and Capture One. The starting point is "as shot" from the RAW.
    /// Until the RAW has been read the slider waits, disabled: a drag from a guessed start would set a wrong shift.
    private func kelvinSlider(_ p: Photo) -> some View {
        let known = ImageStore.shared.cachedAsShotK(p.url)
        let asShot = known ?? 5500
        let k = asShot + p.adj.wbShift
        let changed = p.adj.wbShift != 0
        let isRaw = ImageStore.rawExtensions.contains(p.url.pathExtension.lowercased())
        let range = min(2000, k)...max(12000, k)
        let binding = Binding<Double>(get: { k }, set: { v in
            guard known != nil else { return }
            var a = p.adj
            a.wbShift = ((v - asShot) / 50).rounded() * 50   // 50 K step
            lib.setAdjustments(a)
        })
        func fmt(_ v: Double) -> String { "\(Int(v.rounded()).formatted(.number.grouping(.never))) K" }
        let shot = known.map(fmt) ?? "…"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium").frame(width: 18).foregroundStyle(changed ? Color.accentColor : .secondary)
                Text(tr("Температура")).foregroundStyle(changed ? .primary : .secondary)
                    .onTapGesture(count: 2) { binding.wrappedValue = asShot }
                Spacer()
                Text(known == nil ? "…" : fmt(k)).font(.callout.monospacedDigit().weight(changed ? .semibold : .regular))
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
            .disabled(known == nil)
            HStack {
                Text(isRaw ? tr("Как снято: \(shot)") : tr("Не RAW: сдвиг от 5500 K")).font(.caption2).foregroundStyle(.secondary)
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
    /// What the field shows: collection names are stored untranslated ("Мои стили" is also the
    /// key `Style.collectionOrder` sorts by), so the field holds the translated name and saving maps it back.
    @State private var collection = tr("Мои стили")
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
                        ForEach(lib.userCollections, id: \.self) { c in Button(tr(c)) { collection = tr(c) } }
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
                    lib.createStyle(name: name, groups: groups,
                                    collection: lib.userCollections.first { tr($0) == collection } ?? collection)
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
            Theme.cell
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
            image = await Task.detached(priority: .utility) { await Renderer.shared.thumbnail(url, a, size: 220) }.value
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
            .background(Capsule().fill(saved != nil ? Color.accentColor.opacity(0.4) : Theme.key))
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

/// Slider for a RAW engine setting: shows the value live while dragging and applies it on release
/// (each change develops the RAW again). nil is the engine's default for this file.
struct EngineSlider: View {
    let title: String
    let icon: String
    let value: Double?
    let defaultValue: Double
    var range: ClosedRange<Double> = 0...100
    let commit: (Double?) -> Void
    @State private var live: Double?

    var body: some View {
        let v = live ?? value ?? defaultValue
        let changed = value != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(changed ? Color.accentColor : .secondary)
                Text(title).foregroundStyle(changed ? .primary : .secondary)
                    .onTapGesture(count: 2) { commit(nil) }
                Spacer()
                Text("\(Int(v.rounded()))").font(.callout.monospacedDigit().weight(changed ? .semibold : .regular))
                    .foregroundStyle(changed ? .primary : .secondary)
                Button { commit(nil) } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(changed ? 1 : 0).disabled(!changed)
                    .help(tr("Как у движка по умолчанию: \(Int(defaultValue.rounded()))"))
            }
            Slider(value: Binding(get: { v }, set: { live = $0.rounded() }), in: range) { editing in
                guard !editing, let l = live else { return }
                live = nil
                commit(l == defaultValue.rounded() ? nil : l)
            }
        }
    }
}

/// A 1:1 window for noise, detail and sharpening, as in Lightroom's Detail panel: in a frame that fits
/// the screen they are scaled away. Drag to look at another part of the frame.
struct DetailPreview: View {
    let photo: Photo
    @Environment(Library.self) private var lib
    @State private var center = CGPoint(x: 0.5, y: 0.5)   // frame fractions, y top-down
    @State private var dragStart: CGPoint?
    @State private var image: CGImage?
    @State private var busy = false
    private let height: CGFloat = 170

    private struct Key: Hashable {
        let url: URL, adj: Adjustments, x: Double, y: Double, w: Double, h: Double, pw: Double, ph: Double
    }

    var body: some View {
        GeometryReader { g in
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let px = CGSize(width: (g.size.width * scale).rounded(), height: (height * scale).rounded())
            let full = lib.pixelSize(photo)
            let iw = max(1, full.width * photo.adj.cropW), ih = max(1, full.height * photo.adj.cropH)
            let rw = min(1, px.width / iw), rh = min(1, px.height / ih)
            let rx = min(max(center.x - rw / 2, 0), 1 - rw), ry = min(max(center.y - rh / 2, 0), 1 - rh)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.35)
                if let image {
                    Image(decorative: image, scale: scale).interpolation(.none)
                }
                Text("1:1").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 2)
                    .overlayCapsule().padding(6)
                if busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(width: g.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let s = dragStart ?? CGPoint(x: rx + rw / 2, y: ry + rh / 2)
                    if dragStart == nil { dragStart = s }
                    center = CGPoint(x: s.x - v.translation.width * scale / iw, y: s.y - v.translation.height * scale / ih)
                }
                .onEnded { _ in
                    dragStart = nil
                    center = CGPoint(x: rx + rw / 2, y: ry + rh / 2)
                })
            .help(tr("Фрагмент в масштабе 1:1. Тяните, чтобы посмотреть другую часть кадра."))
            .task(id: Key(url: photo.url, adj: photo.adj, x: rx, y: ry, w: rw, h: rh, pw: px.width, ph: px.height)) {
                busy = true
                if let r = await Renderer.shared.renderRegion(photo.url, photo.adj, region: CGRect(x: rx, y: ry, width: rw, height: rh),
                                                              pixels: px, channel: "detail") {
                    image = r
                }
                busy = false
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onChange(of: photo.url) { center = CGPoint(x: 0.5, y: 0.5); image = nil }
    }
}
