import SwiftUI

struct ExportSheet: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Сохранить в папку").font(.title2.weight(.semibold))
            }
            .padding(24)
            Divider()
            // Настроек много — прокручиваются, кнопки всегда видны внизу.
            ScrollView { settings.padding(24) }
                .frame(maxHeight: 560)
            Divider()
            footer.padding(24)
        }
        .frame(width: 500)
        .onChange(of: lib.export) { _, s in s.save() }
    }

    private var settings: some View {
        @Bindable var lib = lib
        return VStack(alignment: .leading, spacing: 20) {

            section("Что сохранить") {
                Picker("", selection: $lib.export.scope) {
                    Text("Отобранные — с оценкой или цветом (\(lib.photos(for: .rated).count))").tag(ExportSettings.Scope.rated)
                    Text("Показанные сейчас: «\(lib.filter.title)» (\(lib.photos(for: .visible).count))").tag(ExportSettings.Scope.visible)
                    Text(lib.multiSelected ? "Выделенные (\(lib.targets.count))" : "Только текущий снимок").tag(ExportSettings.Scope.selected)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            section("Формат") {
                Picker("", selection: $lib.export.format) {
                    Text("Оригиналы RAW + XMP").tag(ExportSettings.Format.original)
                    Text("JPEG (проявить RAW)").tag(ExportSettings.Format.jpeg)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if lib.export.format == .original {
                    Toggle("Перенести, а не копировать", isOn: $lib.export.move)
                        .help("Файлы исчезнут из текущей папки")
                } else {
                    HStack {
                        Text("Размер")
                        Picker("", selection: $lib.export.longSide) {
                            Text("Полный (50 Мп)").tag(0)
                            Text("4000 px").tag(4000)
                            Text("2560 px — для сайта").tag(2560)
                            Text("1600 px — для соцсетей").tag(1600)
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                    HStack {
                        Text("Качество")
                        Slider(value: $lib.export.jpegQuality, in: 0.6...1.0)
                        Text("\(Int(lib.export.jpegQuality * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                    }
                    Toggle("С обработкой и стилями из «Кадра»", isOn: $lib.export.applyEdits)
                    Text("Проявление движком macOS; правки Capture One не переносятся. ~1–2 с на кадр.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            section("Имя файла") {
                HStack {
                    TextField("{name}", text: $lib.export.nameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Menu("Вставить") {
                        Button("{name} — исходное имя") { lib.export.nameTemplate += "{name}" }
                        Button("{folder} — имя съёмки") { lib.export.nameTemplate += "{folder}" }
                        Button("{date} — дата съёмки") { lib.export.nameTemplate += "{date}" }
                        Button("{n} — номер 001, 002…") { lib.export.nameTemplate += "{n}" }
                        Divider()
                        Button("Как в камере") { lib.export.nameTemplate = "{name}" }
                        Button("Съёмка_номер") { lib.export.nameTemplate = "{folder}_{n}" }
                        Button("Дата_номер") { lib.export.nameTemplate = "{date}_{n}" }
                    }
                    .fixedSize()
                }
                Text("Пример: \(namePreview)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if lib.export.format == .jpeg {
                section("Водяной знак") {
                    Toggle("Добавить текст на фото", isOn: $lib.export.watermarkOn)
                    if lib.export.watermarkOn {
                        TextField("© Ваше имя", text: $lib.export.watermarkText)
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
                            Text("Размер")
                            Slider(value: $lib.export.watermarkSize, in: 1...8)
                            Text("Прозрачность")
                            Slider(value: $lib.export.watermarkOpacity, in: 0.15...1)
                        }
                        .font(.callout)
                    }
                }
            }

            section("Куда") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(destinationText)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(lib.export.destination == nil ? .secondary : .primary)
                    Spacer()
                    Button("Выбрать…") { lib.chooseExportFolder() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                Toggle("Создать подпапку «\(lib.folder?.lastPathComponent ?? "съёмка")»", isOn: $lib.export.subfolder)
                Text("Совет: клавиша S отправляет текущий кадр в эту папку сразу, без окна.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lib.exporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(lib.exportDone), total: Double(max(lib.exportTotal, 1)))
                    Text("Сохраняю \(lib.exportDone) из \(lib.exportTotal)…")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                if lib.exporting {
                    Button("Остановить") { lib.cancelExport() }
                } else {
                    Button("Отмена") { lib.showExport = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Сохранить \(lib.photos(for: lib.export.scope).count)") { lib.runExport() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(lib.export.destination == nil || lib.photos(for: lib.export.scope).isEmpty)
                }
            }
        }
    }

    private var namePreview: String {
        let p = lib.photos(for: lib.export.scope).first ?? lib.current
        guard let p else { return "—" }
        let item = ExportItem(url: p.url, adj: p.adj, date: p.exif.date, index: 1)
        let ext = lib.export.format == .jpeg ? "jpg" : p.url.pathExtension
        return Exporter.baseName(item, template: lib.export.nameTemplate, folder: lib.folder?.lastPathComponent) + "." + ext
    }

    private var destinationText: String {
        guard let d = lib.export.destination else { return "Папка не выбрана" }
        return d.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
