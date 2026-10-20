import SwiftUI

struct ExportSheet: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(tr("Сохранить в папку")).font(.title2.weight(.semibold))
            }
            .padding(24)
            Divider()
            // Настроек много — прокручиваются, кнопки всегда видны внизу.
            ScrollView { settings.padding(24) }
                .frame(maxHeight: max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 260))
            Divider()
            footer.padding(24)
        }
        .frame(width: 500)
        .onChange(of: lib.export) { _, s in s.save() }
    }

    private var settings: some View {
        @Bindable var lib = lib
        return VStack(alignment: .leading, spacing: 20) {

            section(tr("Что сохранить")) {
                Picker("", selection: $lib.export.scope) {
                    Text(tr("Отобранные — с оценкой или цветом (\(lib.photos(for: .rated).count))")).tag(ExportSettings.Scope.rated)
                    Text(tr("Показанные сейчас: «\(lib.filter.title)» (\(lib.photos(for: .visible).count))")).tag(ExportSettings.Scope.visible)
                    Text(lib.multiSelected ? tr("Выделенные (\(lib.targets.count))") : tr("Только текущий снимок")).tag(ExportSettings.Scope.selected)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Три независимых решения: формат файла → размер в пикселях → качество сжатия.
            // Ни один пункт не меняет другой «за спиной».
            section(tr("Формат файла")) {
                Picker("", selection: $lib.export.format) {
                    Text(tr("Оригиналы RAW + XMP")).tag(ExportSettings.Format.original)
                    Text(tr("JPEG (проявить RAW)")).tag(ExportSettings.Format.jpeg)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if lib.export.format == .original {
                    Toggle(tr("Перенести, а не копировать"), isOn: $lib.export.move)
                        .help(tr("Файлы исчезнут из текущей папки"))
                    SizeEstimate()
                }
            }

            if lib.export.format == .jpeg {
                section(tr("Размер")) {
                    VStack(spacing: 6) {
                        ForEach(SizeChoice.allCases) { c in sizeRow(c) }
                    }
                    if lib.export.preset == .story {
                        Toggle(tr("Кадры не 9:16 — обрезать по центру (иначе вписать без обрезки)"), isOn: $lib.export.presetCrop)
                    }
                    if lib.export.preset == .instagram || lib.export.preset == .story { PlanSummary() }
                }

                section(tr("Качество")) { quality }

                section(tr("Обработка")) {
                    Toggle(tr("С обработкой, стилями и кадрированием из «Кадра»"), isOn: $lib.export.applyEdits)
                    Text(tr("Проявление движком macOS; правки Capture One не переносятся. ~1–2 с на кадр."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            section(tr("Имя файла")) {
                HStack {
                    TextField("{name}", text: $lib.export.nameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Menu(tr("Вставить")) {
                        Button(tr("{name} — исходное имя")) { lib.export.nameTemplate += "{name}" }
                        Button(tr("{folder} — имя съёмки")) { lib.export.nameTemplate += "{folder}" }
                        Button(tr("{date} — дата съёмки")) { lib.export.nameTemplate += "{date}" }
                        Button(tr("{n} — номер 001, 002…")) { lib.export.nameTemplate += "{n}" }
                        Divider()
                        Button(tr("Как в камере")) { lib.export.nameTemplate = "{name}" }
                        Button(tr("Съёмка_номер")) { lib.export.nameTemplate = "{folder}_{n}" }
                        Button(tr("Дата_номер")) { lib.export.nameTemplate = "{date}_{n}" }
                    }
                    .fixedSize()
                }
                Text(tr("Пример: \(namePreview)"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if lib.export.format == .jpeg {
                section(tr("Водяной знак")) {
                    Toggle(tr("Добавить текст на фото"), isOn: $lib.export.watermarkOn)
                    if lib.export.watermarkOn {
                        TextField(tr("© Ваше имя"), text: $lib.export.watermarkText)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Picker("", selection: $lib.export.watermarkPosition) {
                                ForEach(Watermark.Position.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Spacer()
                        }
                        HStack {
                            Text(tr("Величина текста")).frame(width: 120, alignment: .leading)
                            Slider(value: $lib.export.watermarkSize, in: 1...8)
                            Text(String(format: tr("%.0f%% кадра"), lib.export.watermarkSize)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70)
                        }
                        HStack {
                            Text(tr("Непрозрачность")).frame(width: 120, alignment: .leading)
                            Slider(value: $lib.export.watermarkOpacity, in: 0.15...1)
                            Text("\(Int((lib.export.watermarkOpacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 70)
                        }
                        .font(.callout)
                    }
                }
            }

            section(tr("Куда")) {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(destinationText)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(lib.export.destination == nil ? .secondary : .primary)
                    Spacer()
                    Button(tr("Выбрать…")) { lib.chooseExportFolder() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                Toggle(tr("Создать подпапку «\(lib.folder?.lastPathComponent ?? "съёмка")»"), isOn: $lib.export.subfolder)
                Text(tr("Совет: клавиша S отправляет текущий кадр в эту папку сразу, без окна."))
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lib.exporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(lib.exportDone), total: Double(max(lib.exportTotal, 1)))
                    Text(tr("Сохраняю \(lib.exportDone) из \(lib.exportTotal)…"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                if lib.exporting {
                    Button(tr("Остановить")) { lib.cancelExport() }
                } else {
                    Button(tr("Отмена")) { lib.showExport = false }
                        .keyboardShortcut(.cancelAction)
                    Button(tr("Сохранить \(lib.photos(for: lib.export.scope).count)")) { lib.runExport() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(lib.export.destination == nil || lib.photos(for: lib.export.scope).isEmpty)
                }
            }
        }
    }

    /// Единственная настройка сжатия: качество JPEG. Размер в пикселях — в пункте «Размер».
    private var quality: some View {
        @Bindable var lib = lib
        let q = Int((lib.export.jpegQuality * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Slider(value: $lib.export.jpegQuality, in: 0.6...1.0)
                Text("\(q)%").font(.body.monospacedDigit().weight(.semibold)).frame(width: 46, alignment: .trailing)
            }
            HStack {
                Text(tr("экономно")).frame(maxWidth: .infinity, alignment: .leading)
                Text(tr("хорошо")).frame(maxWidth: .infinity, alignment: .center)
                Text(tr("максимум")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.trailing, 52)
            SizeEstimate()
            Text(q >= 95 ? tr("Почти без потерь — файлы крупные.") : q >= 85 ? tr("Без видимых потерь — обычный выбор.") : q >= 75 ? tr("Чуть заметно на градиентах неба и кожи.") : tr("Заметные артефакты — только для превью."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Строка выбора размера (один выбор из списка).
    private func sizeRow(_ c: SizeChoice) -> some View {
        let on = SizeChoice.current(lib.export) == c
        return Button { c.apply(&lib.export) } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.callout.weight(on ? .semibold : .regular))
                    Text(c.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.18) : .white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var namePreview: String {
        let p = lib.photos(for: lib.export.scope).first ?? lib.current
        guard let p else { return "—" }
        let item = ExportItem(url: p.url, adj: p.adj, date: p.exif.date, index: 1)
        let ext = lib.export.format == .jpeg ? "jpg" : p.url.pathExtension
        return Exporter.baseName(item, template: lib.export.nameTemplate, folder: lib.folder?.lastPathComponent) + "." + ext
    }

    private var destinationText: String {
        guard let d = lib.export.destination else { return tr("Папка не выбрана") }
        return d.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Сводка: во что превратится каждый кадр при выбранном пресете. Видно заранее — без двойной настройки.
struct PlanSummary: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let list = lib.photos(for: lib.export.scope)
        let plans = list.compactMap { p -> ExportPlan? in
            let a = lib.imageAspect(p) * p.adj.cropW / p.adj.cropH
            return ExportPlan.make(aspect: a, userCropped: p.adj.hasCrop, lib.export)
        }
        let groups = Dictionary(grouping: plans, by: { $0 }).map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Что получится (\(list.count) кадров)")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(groups, id: \.0) { plan, n in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: plan.crop == nil ? "checkmark.circle.fill" : "crop")
                        .foregroundStyle(plan.crop == nil ? Color.green : Color.orange)
                    Text("\(n) × " + String(plan.width) + "×" + String(plan.height)).font(.callout.monospacedDigit().weight(.medium))
                    Text(plan.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            if plans.contains(where: { $0.crop != nil }) {
                Text(tr("Чтобы выбрать, что останется в кадре, кадрируйте эти снимки сами (R) — пресет возьмёт вашу рамку."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }
}

/// Размер выгружаемого JPEG — один выбор вместо «пресетов» и отдельного «размера».
enum SizeChoice: String, CaseIterable, Identifiable {
    case instagram, story, px2560, px1600, full
    var id: String { rawValue }

    var title: String {
        switch self {
        case .instagram: tr("Instagram лента")
        case .story: tr("Сторис / Reels")
        case .px2560: "2560 px"
        case .px1600: "1600 px"
        case .full: tr("Полный размер")
        }
    }

    var subtitle: String {
        switch self {
        case .instagram: tr("1080 по ширине; формат — из вашего кадрирования (4:5, 1:1, 1.91:1)")
        case .story: "1080 × 1920"
        case .px2560: tr("по длинной стороне — сайт, Telegram, ВКонтакте")
        case .px1600: tr("по длинной стороне — мессенджеры, почта")
        case .full: tr("как снято — для печати и архива")
        }
    }

    static func current(_ s: ExportSettings) -> SizeChoice {
        switch s.preset {
        case .instagram: return .instagram
        case .story: return .story
        case .web: return .px2560
        case .custom: return s.longSide == 0 ? .full : s.longSide <= 1600 ? .px1600 : .px2560
        }
    }

    func apply(_ s: inout ExportSettings) {
        switch self {
        case .instagram: s.preset = .instagram
        case .story: s.preset = .story
        case .px2560: s.preset = .custom; s.longSide = 2560
        case .px1600: s.preset = .custom; s.longSide = 1600
        case .full: s.preset = .custom; s.longSide = 0
        }
    }
}
