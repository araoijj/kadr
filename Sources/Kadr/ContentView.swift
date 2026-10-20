import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var lib
    @State private var monitor: Any?

    var body: some View {
        @Bindable var lib = lib
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                if lib.folder == nil {
                    EmptyState()
                } else if lib.loupe {
                    LoupeView()
                } else {
                    GridView()
                }
                if lib.multiSelected && lib.folder != nil { SelectionBar() }
                if let t = lib.toast { Toast(text: t) }
            }
            .inspector(isPresented: $lib.showInfo) {
                InfoPanel()
                    .inspectorColumnWidth(min: 240, ideal: 270, max: 340)
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $lib.showExport) { ExportSheet().environment(lib) }
        .navigationTitle(lib.folder?.lastPathComponent ?? "Кадр")
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            lib.open(isDir.boolValue ? u : u.deletingLastPathComponent())
            return true
        }
        .onAppear {
            // kadr /путь/к/папке — открыть сразу
            if lib.folder == nil, CommandLine.arguments.count > 1 {
                let u = URL(fileURLWithPath: CommandLine.arguments[1])
                if FileManager.default.fileExists(atPath: u.path) { lib.open(u) }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                MainActor.assumeIsolated {
                    KeyHandler.handle(e, lib) ? nil : e
                }
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var lib = lib
        ToolbarItem(placement: .navigation) {
            Button { lib.chooseFolder() } label: { Label("Открыть", systemImage: "folder") }
                .help("Открыть папку (⌘O)")
        }
        ToolbarItem(placement: .principal) {
            if lib.folder != nil {
                Picker("Вид", selection: $lib.loupe) {
                    Image(systemName: "square.grid.2x2").tag(false)
                    Image(systemName: "rectangle").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .help("Сетка / Просмотр (пробел)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if lib.folder != nil {
                if lib.analyzed < lib.photos.count {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Анализ \(lib.analyzed)/\(lib.photos.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if !lib.loupe {
                    Slider(value: $lib.thumbSize, in: 120...420)
                        .frame(width: 110)
                        .help("Размер превью")
                }
                Button { lib.showExport = true } label: {
                    Label("Сохранить в папку", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Сохранить отобранные в папку (⌘S). S — текущий кадр сразу")
                Menu {
                    Button("Перенести отклонённые в «_Отклонённые»", systemImage: "trash") { lib.moveRejected() }
                    Button("Сохранить в папку…", systemImage: "square.and.arrow.down") { lib.showExport = true }
                    Button("Открыть показанные в Capture One", systemImage: "camera.aperture") { lib.openVisibleInCaptureOne() }
                    Divider()
                    Button("Показать в Finder", systemImage: "magnifyingglass") { lib.revealCurrent() }
                } label: {
                    Label("Действия", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

enum Theme {
    static let canvas = Color(red: 0.085, green: 0.088, blue: 0.095)
    static let cell = Color.white.opacity(0.04)
    static let star = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let reject = Color(red: 0.93, green: 0.33, blue: 0.31)
}

// MARK: - Пустой экран

struct EmptyState: View {
    @Environment(Library.self) private var lib
    @State private var hover = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Перетащите папку со съёмкой")
                    .font(.title2.weight(.semibold))
                Text("RAW Sony, Canon, Nikon, Fuji и JPEG. Оценки сохраняются в XMP — их сразу видит Capture One.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button("Выбрать папку…") { lib.chooseFolder() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            KeyHints().padding(.top, 18)
        }
        .padding(60)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(.white.opacity(0.12))
        )
        .padding(40)
    }
}

struct KeyHints: View {
    private let hints: [(String, String)] = [
        ("← →", "листать"), ("1–5", "звёзды"), ("0", "снять оценку"), ("X", "отклонить"),
        ("6–9", "цвет"), ("Пробел", "сетка / кадр"), ("Z", "зум 100%"), ("I", "инфо"),
        ("S", "кадр в папку"), ("⌘S", "сохранить отобранные"),
        ("⌘ / ⇧ + клик", "выделить несколько"), ("⌘A", "выделить всё"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            ForEach(0..<hints.count / 2, id: \.self) { r in
                GridRow {
                    hint(hints[r * 2])
                    hint(hints[r * 2 + 1])
                }
            }
        }
    }

    private func hint(_ h: (String, String)) -> some View {
        HStack(spacing: 8) {
            Text(h.0)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            Text(h.1).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        VStack {
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 24)
            Spacer()
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
