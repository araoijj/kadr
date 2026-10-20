import SwiftUI

struct ExportSheet: View {
    @Environment(Library.self) private var lib

    var body: some View {
        @Bindable var lib = lib
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Сохранить в папку").font(.title2.weight(.semibold))
            }

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
                    Text("Проявление — стандартное macOS, без правок Capture One. ~1–2 с на кадр.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .padding(24)
        .frame(width: 480)
        .onChange(of: lib.export) { _, s in s.save() }
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
