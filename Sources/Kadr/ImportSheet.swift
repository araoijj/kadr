import SwiftUI

struct ImportSheet: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let imp = lib.importer
        @Bindable var b = imp
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sdcard")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(tr("Импорт с карты памяти")).font(.title2.weight(.semibold))
            }
            .padding(24)
            Divider()

            VStack(alignment: .leading, spacing: 20) {
                section(tr("Откуда")) {
                    HStack {
                        Picker("", selection: Binding(get: { imp.source }, set: { if let u = $0 { imp.scan(u) } })) {
                            if imp.source == nil { Text(tr("Выберите карту")).tag(URL?.none) }
                            ForEach(lib.browser.volumes, id: \.self) { v in
                                Text(FolderBrowser.displayName(v) + (CardImporter.isCameraCard(v) ? tr("  — карта камеры") : ""))
                                    .tag(URL?.some(v))
                            }
                            if let s = imp.source, !lib.browser.volumes.contains(s) {
                                Text(s.lastPathComponent).tag(URL?.some(s))
                            }
                        }
                        .labelsHidden()
                        Button(tr("Другая папка…")) { chooseSource() }
                    }
                    summary
                }

                section(tr("Куда")) {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(imp.baseFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button(tr("Выбрать…")) { chooseBase() }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
                    TextField(tr("Название съёмки, например «Свадьба Ивановых»"), text: $b.shootName)
                        .textFieldStyle(.roundedBorder)
                    Toggle(tr("Раскладывать по дням съёмки"), isOn: $b.splitByDay)
                    if !imp.days.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array((imp.splitByDay ? imp.days : [imp.days[0]]).prefix(4)), id: \.self) { d in
                                Label(imp.folderName(for: d), systemImage: "folder")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if imp.splitByDay && imp.days.count > 4 {
                                Text(tr("…и ещё \(imp.days.count - 4)")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                section(tr("Параметры")) {
                    Toggle(tr("Только новые — пропустить уже импортированные"), isOn: $b.onlyNew)
                    Toggle(tr("Извлечь карту после импорта"), isOn: $b.ejectAfter)
                }

                if imp.copying {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(imp.bytesDone), total: Double(max(imp.bytesTotal, 1)))
                        Text(tr("\(bytes(imp.bytesDone)) из \(bytes(imp.bytesTotal))"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let r = imp.result {
                    Label(r, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Text(tr("Файлы копируются, карта не меняется. Размер каждой копии сверяется."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if imp.copying {
                    Button(tr("Остановить")) { imp.cancel() }
                } else {
                    Button(imp.result == nil ? tr("Отмена") : tr("Закрыть")) { lib.showImport = false }
                        .keyboardShortcut(.cancelAction)
                    Button(tr("Импортировать \(imp.toCopy.count)")) {
                        imp.start { folder in lib.scan(folder) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(imp.toCopy.isEmpty || imp.scanning)
                }
            }
            .padding(24)
        }
        .frame(width: 540)
        .onAppear {
            if imp.source == nil, let card = lib.browser.volumes.first(where: CardImporter.isCameraCard) { imp.scan(card) }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let imp = lib.importer
        if imp.scanning {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("Читаю карту…")).foregroundStyle(.secondary) }
        } else if imp.source != nil {
            if imp.files.isEmpty {
                Text(tr("Снимков не найдено")).foregroundStyle(.secondary)
            } else {
                let size = imp.files.reduce(Int64(0)) { $0 + $1.size }
                let first = imp.files.first!.date, last = imp.files.last!.date
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("\(imp.files.count) файлов · \(bytes(size)) · \(range(first, last))"))
                    let fresh = imp.newFiles.count
                    Text(fresh == imp.files.count ? tr("Все новые") : fresh == 0 ? tr("Всё уже импортировано раньше") : tr("Новых: \(fresh), уже импортировано: \(imp.files.count - fresh)"))
                        .foregroundStyle(fresh == 0 ? .orange : .secondary)
                }
                .font(.callout)
            }
        }
    }

    private func range(_ a: Date, _ b: Date) -> String {
        Calendar.current.isDate(a, inSameDayAs: b)
            ? a.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(I18n.locale))
            : "\(a.formatted(.dateTime.day().month(.abbreviated).locale(I18n.locale))) – \(b.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(I18n.locale)))"
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func chooseSource() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = tr("Папка или карта, откуда импортировать")
        if p.runModal() == .OK, let u = p.url { lib.importer.scan(u) }
    }

    private func chooseBase() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = lib.importer.baseFolder
        p.message = tr("Куда складывать съёмки")
        if p.runModal() == .OK, let u = p.url { lib.importer.baseFolder = u }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// "Card inserted" banner at the top of the window.
struct CardBanner: View {
    @Environment(Library.self) private var lib

    var body: some View {
        if let card = lib.cardBanner {
            Bar(tint: Color.accentColor.opacity(0.14)) {
                HStack(spacing: 12) {
                    Image(systemName: "sdcard.fill").foregroundStyle(Color.accentColor)
                    Text(tr("Подключена карта «\(FolderBrowser.displayName(card))»")).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(tr("Импортировать…")) {
                        lib.importer.scan(card)
                        lib.showImport = true
                        lib.cardBanner = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button { lib.cardBanner = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Закрыть"))
                }
            }
        }
    }
}
