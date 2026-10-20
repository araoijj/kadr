import AppKit
import SwiftUI

/// Режим «Отбор»: большой кадр, прогресс, решения, очередь и турнир — ручной отбор.
/// AI-отбор (причины брака, AI-очереди, лица в 100%) — после запуска AI-анализа и при включённых подсказках.
struct CullView: View {
    @Environment(Library.self) private var lib
    @State private var barHeight: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            // Панель подстраивается под ширину центра, а не задаёт её: иначе вместе с «Инфо»
            // она распирает окно и боковые панели уезжают за край.
            Color.clear.frame(maxWidth: .infinity).frame(height: barHeight)
                .overlay(alignment: .topLeading) {
                    CullTopBar()
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                }
                .clipped()
            Divider()
            GeometryReader { g in
            HStack(spacing: 0) {
                ZStack {
                    if let p = lib.current {
                        ZoomableLoupe(photo: p)
                        CullOverlay(photo: p)
                    } else {
                        ContentUnavailableView(tr("Очередь пуста"), systemImage: "checkmark.circle",
                                               description: Text(tr("В этой очереди не осталось кадров — выберите другую сверху.")))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Лица — только если кадру остаётся место (узкое окно: лица смотрятся зумом).
                if lib.aiOn, g.size.width >= 640, let p = lib.current, !(p.cull?.faces.isEmpty ?? true) {
                    Divider()
                    FacesColumn(photo: p).frame(width: 210)
                }
            }
            }
            Filmstrip()
        }
        .sheet(isPresented: Binding(get: { lib.showCullSummary }, set: { lib.showCullSummary = $0 })) {
            CullSummary().environment(lib)
        }
    }
}

struct CullTopBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        // Сверху — ручной отбор (прогресс, решения, очередь, турнир), ниже — отдельная полоса AI-отбора.
        // Широкое окно — две строки, узкое — три: иначе панель распирает окно.
        ViewThatFits(in: .horizontal) {
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    progress(width: 180)
                    counters
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        queuePicker.pickerStyle(.segmented).fixedSize()
                        queuePicker.pickerStyle(.menu).fixedSize()
                    }
                    tournament
                    summary
                }
                HStack(spacing: 12) {
                    aiStrip(compact: false)
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        Text(tr("P — оставить · X — брак · U — снять · ← → — листать · 1–5 — звёзды"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Text(tr("P · X · U · ← →")).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    progress(width: 110)
                    counters
                }
                HStack(spacing: 8) {
                    queuePicker.pickerStyle(.menu).fixedSize()
                    tournament
                    Spacer(minLength: 0)
                    summary
                }
                .controlSize(.small)
                aiStrip(compact: true).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.2))
    }

    private func progress(width: CGFloat) -> some View {
        let total = lib.photos.count
        let seen = lib.photos.filter { lib.viewed.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 3) {
            Text(tr("Просмотрено \(seen) из \(total)")).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
            ProgressView(value: Double(seen), total: Double(max(total, 1))).frame(width: width)
        }
    }

    private var counters: some View {
        let d = lib.decided
        return HStack(spacing: 14) {
            counter(tr("Оставлено"), d.kept, .green)
            counter(tr("Брак"), d.rejected, Theme.reject)
            counter(tr("Без решения"), d.undecided, .secondary)
        }
        .fixedSize()
    }

    /// AI-отбор: запуск по кнопке, прогресс, затем подсказки, строгость и AI-действия.
    /// Пока не запущен — отбор полностью ручной, без значков брака.
    @ViewBuilder private func aiStrip(compact: Bool) -> some View {
        @Bindable var lib = lib
        HStack(spacing: 10) {
            Label("AI", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor).fixedSize()
            if lib.analyzed < lib.photos.count {
                Text(tr("доступен после индексации папки")).font(.caption).foregroundStyle(.secondary).fixedSize()
            } else if lib.aiRunning {
                ProgressView(value: Double(lib.aiDone), total: Double(max(lib.aiTotal, 1))).frame(width: compact ? 90 : 140)
                Text(tr("AI-анализ \(lib.aiDone)/\(lib.aiTotal)")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                Button(tr("Стоп")) { lib.stopAI() }.fixedSize()
            } else if !lib.aiReady {
                Button { lib.startAI() } label: { Label(tr("Запустить AI-анализ"), systemImage: "sparkles") }
                    .fixedSize()
                    .help(tr("Найдёт смаз, моргание, пересвет и лучшие кадры в сериях. Нагружает Mac: ~1 минута на 1000 кадров (⌥⌘A)."))
                if !compact {
                    Text(tr("смаз · моргание · пересвет · лучшие в сериях")).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            } else {
                Toggle(tr("Подсказки"), isOn: $lib.cullHints)
                    .toggleStyle(.switch).fixedSize()
                    .help(tr("Показывать находки AI-анализа: значки брака, AI-очереди и лица"))
                if lib.cullHints {
                    if compact {
                        Slider(value: $lib.cullStrictness, in: 0...1).frame(width: 90)
                            .help(tr("Строгость поиска брака: мягко — только явный, строго — всё сомнительное"))
                    } else {
                        strictness(labels: true)
                    }
                    actions
                }
                if lib.aiPending > 0 {
                    Button(tr("Досчитать (\(lib.aiPending))")) { lib.startAI() }.fixedSize()
                        .help(tr("Новые кадры или кадры, посчитанные до установки сетки лица"))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func strictness(labels: Bool) -> some View {
        @Bindable var lib = lib
        return HStack(spacing: 6) {
            Text(tr("мягко")).font(.caption).foregroundStyle(.secondary).fixedSize()
            Slider(value: $lib.cullStrictness, in: 0...1).frame(width: labels ? 130 : 100)
            Text(tr("строго")).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .help(tr("Строгость поиска брака: мягко — только явный, строго — всё сомнительное"))
    }

    private var actions: some View {
        Menu(tr("AI-действия")) {
            Button(tr("Отклонить предложенный брак…")) { lib.acceptSuggestions() }
            Button(tr("Оставить лучшие в сериях, остальные в брак…")) { lib.keepBestInSeries() }
        }
        .fixedSize()
    }

    private var tournament: some View {
        Button { lib.startTournament() } label: { Label(tr("Турнир"), systemImage: "trophy") }
            .fixedSize()
            .help(tr("Турнир по серии или выделенным (T)"))
    }

    private var summary: some View {
        Button(tr("Итог…")) { lib.showCullSummary = true }.fixedSize()
    }

    private var queuePicker: some View {
        let total = lib.photos.count
        return Picker("", selection: Binding(get: { lib.filter }, set: { lib.filter = $0; lib.move(0) })) {
            Text(tr("Все") + " \(total)").tag(PhotoFilter.all)
            Text(tr("Без решения") + " \(lib.count(.undecided))").tag(PhotoFilter.undecided)
            if lib.aiOn {
                Text(tr("Возможный брак") + " \(lib.count(.suspects))").tag(PhotoFilter.suspects)
                Text(tr("Быстрый проход") + " \(lib.count(.leaders))").tag(PhotoFilter.leaders)
            }
        }
        .labelsHidden()
        .help(tr("Очередь: какие кадры листать"))
    }

    private func counter(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(n)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Поверх кадра: решение, причины брака, оценка, «Выровнять».
struct CullOverlay: View {
    let photo: Photo
    @Environment(Library.self) private var lib

    var body: some View {
        let v = lib.verdict(photo)
        VStack {
            HStack(alignment: .top, spacing: 6) {
                if photo.rejected {
                    tag(tr("Брак"), "xmark.circle.fill", Theme.reject)
                } else if photo.rating > 0 {
                    tag(tr("Оставлено") + " " + String(repeating: "★", count: photo.rating), "checkmark.circle.fill", .green)
                }
                if lib.aiOn {
                    ForEach(v.reasons) { r in tag(r.title, r.icon, r.isDefect ? .orange : .yellow) }
                    if photo.isBestInSeries { tag(tr("Лучший в серии"), "sparkles", Theme.star) }
                    if v.reasons.contains(.underexposed) {
                        Button { lib.brightenDark() } label: { tag(tr("Осветлить"), "sun.max", .accentColor) }
                            .buttonStyle(.plain)
                    }
                    if v.reasons.contains(.tilted) {
                        Button { lib.straightenByHorizon() } label: { tag(tr("Выровнять"), "level", .accentColor) }
                            .buttonStyle(.plain).allowsHitTesting(true)
                    }
                }
                Spacer()
                if lib.aiOn, photo.cull != nil {
                    Text(tr("Оценка \(v.score)"))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .help(tr("Техника и эстетика кадра, 0–100. Подсказка, а не приговор."))
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private func tag(_ t: String, _ icon: String, _ c: Color) -> some View {
        Label(t, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())
    }
}

/// Лица текущего кадра в 100% — резкость глаз видна сразу, без зума.
struct FacesColumn: View {
    let photo: Photo
    @Environment(Library.self) private var lib

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("Лица · 100%")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array((photo.cull?.faces ?? []).prefix(4).enumerated()), id: \.offset) { i, f in
                    FaceCrop(photo: photo, face: f, index: i)
                }
            }
            .padding(10)
        }
        .background(.black.opacity(0.15))
    }
}

struct FaceCrop: View {
    @Environment(Library.self) private var lib
    let photo: Photo
    let face: FaceInfo
    let index: Int
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.white.opacity(0.05)
                if let image { Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(width: 190, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                let shut = face.eyesShut(lib.cullStrictness)
                let squint = !shut && (face.squint ?? 0) >= 0.45
                Image(systemName: shut ? "eye.slash.fill" : squint ? "eye.trianglebadge.exclamationmark" : "eye.fill")
                    .foregroundStyle(shut ? .orange : squint ? .yellow : .green)
                Text(shut ? (face.blink != nil ? tr("глаза закрыты") : tr("глаза закрыты?")) : squint ? tr("прищур") : tr("глаза открыты"))
                    .font(.caption)
                    .help(face.blink.map { b in tr("Моргание \(String(format: "%.2f", b)) · прищур \(String(format: "%.2f", face.squint ?? 0)) (MediaPipe)") }
                        ?? tr("По контуру глаз от macOS. Точнее — с сеткой лица MediaPipe (Настройки → Память и скорость)."))
                Spacer()
                if let q = face.quality { Text("\(Int(q * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).help(tr("Качество лица по оценке macOS")) }
            }
        }
        .task(id: ThumbKey(url: photo.url, adj: photo.adj)) {
            // Лицо в координатах кадрированного снимка; квадрат вокруг лица в ~100% (380 px на Retina).
            let a = photo.adj
            // Квадрат в пикселях (кадр 3:2 — в долях это прямоугольник), внутри границ снимка.
            let ps = lib.pixelSize(photo)
            let W = ps.width * a.cropW, H = ps.height * a.cropH
            var f = face.rect
            f = CGRect(x: (f.minX - a.cropX) / a.cropW, y: (f.minY - a.cropY) / a.cropH, width: f.width / a.cropW, height: f.height / a.cropH)
            let sidePx = min(max(f.width * W, f.height * H) * 1.5, W, H)
            let rw = sidePx / W, rh = sidePx / H
            let r = CGRect(x: min(max(f.midX - rw / 2, 0), 1 - rw), y: min(max(f.midY - rh / 2, 0), 1 - rh), width: rw, height: rh)
            let px = Library.cullFacePixels
            image = await Renderer.shared.renderRegion(photo.url, a, region: r, pixels: CGSize(width: px, height: px), channel: "face-\(index)")
        }
    }
}

/// Итог отбора: сколько оставлено и отклонено, и что сделать дальше.
struct CullSummary: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let d = lib.decided
        let reasons = CullReason.allCases.map { r in (r, lib.photos.filter { lib.verdict($0).reasons.contains(r) }.count) }.filter { $0.1 > 0 }
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Итог отбора")).font(.title2.weight(.semibold))
            HStack(spacing: 24) {
                big(d.kept, tr("оставлено"), .green)
                big(d.rejected, tr("в браке"), Theme.reject)
                big(d.undecided, tr("без решения"), .secondary)
            }
            if lib.aiOn && !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Что нашёл анализ")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(reasons, id: \.0) { r, n in
                        Label("\(r.title): \(n)", systemImage: r.icon).font(.callout)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button(tr("Перенести брак в «_Отклонённые»…")) { dismiss(); lib.moveRejected() }.disabled(d.rejected == 0)
                Button(tr("Сохранить оставленные в папку…")) {
                    dismiss(); lib.export.scope = .rated; lib.showExport = true
                }
                .disabled(d.kept == 0)
                Button(tr("Показать только оставленные")) { dismiss(); lib.filter = .picked; lib.move(0) }.disabled(d.kept == 0)
                if d.undecided > 0 {
                    Button(tr("Продолжить: кадры без решения (\(d.undecided))")) { dismiss(); lib.filter = .undecided; lib.move(0) }
                }
            }
            HStack { Spacer(); Button(tr("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func big(_ n: Int, _ t: String, _ c: Color) -> some View {
        VStack(alignment: .leading) {
            Text("\(n)").font(.largeTitle.monospacedDigit().weight(.semibold)).foregroundStyle(c)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }
}
