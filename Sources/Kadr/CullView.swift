import AppKit
import SwiftUI

/// Режим «Отбор»: большой кадр, прогресс, очередь, причины брака и лица в 100%.
/// «Подсказки» выключаются — тогда это чистый ручной отбор: кадр, лента, P / X / U и звёзды.
struct CullView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(spacing: 0) {
            CullTopBar()
            Divider()
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
                if lib.cullHints, let p = lib.current, !(p.cull?.faces.isEmpty ?? true) {
                    Divider()
                    FacesColumn(photo: p).frame(width: 210)
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
        @Bindable var lib = lib
        let d = lib.decided
        let total = lib.photos.count
        let seen = lib.photos.filter { lib.viewed.contains($0.id) }.count
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Просмотрено \(seen) из \(total)")).font(.callout.weight(.semibold)).monospacedDigit()
                    ProgressView(value: Double(seen), total: Double(max(total, 1))).frame(width: 180)
                }
                counter(tr("Оставлено"), d.kept, .green)
                counter(tr("Брак"), d.rejected, Theme.reject)
                counter(tr("Без решения"), d.undecided, .secondary)
                Spacer()
                Picker("", selection: Binding(get: { lib.filter }, set: { lib.filter = $0; lib.move(0) })) {
                    Text(tr("Все") + " \(total)").tag(PhotoFilter.all)
                    Text(tr("Без решения") + " \(lib.count(.undecided))").tag(PhotoFilter.undecided)
                    if lib.cullHints {
                        Text(tr("Возможный брак") + " \(lib.count(.suspects))").tag(PhotoFilter.suspects)
                        Text(tr("Быстрый проход") + " \(lib.count(.leaders))").tag(PhotoFilter.leaders)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(tr("Очередь: какие кадры листать"))
            }
            HStack(spacing: 12) {
                Toggle(tr("Подсказки"), isOn: $lib.cullHints)
                    .toggleStyle(.switch).controlSize(.small)
                    .help(tr("Выключите — и отбор полностью ручной: без значков, очередей и автоанализа на экране"))
                if lib.cullHints {
                    HStack(spacing: 6) {
                        Text(tr("мягко")).font(.caption).foregroundStyle(.secondary)
                        Slider(value: $lib.cullStrictness, in: 0...1).frame(width: 130).controlSize(.small)
                        Text(tr("строго")).font(.caption).foregroundStyle(.secondary)
                    }
                    .help(tr("Строгость поиска брака: мягко — только явный, строго — всё сомнительное"))
                    Menu(tr("Действия")) {
                        Button(tr("Отклонить предложенный брак…")) { lib.acceptSuggestions() }
                        Button(tr("Оставить лучшие в сериях, остальные в брак…")) { lib.keepBestInSeries() }
                        Divider()
                        Button(tr("Турнир по серии или выделенным (T)")) { lib.startTournament() }
                    }
                    .fixedSize()
                }
                Spacer()
                Text(tr("P — оставить · X — брак · U — снять · ← → — листать · 1–5 — звёзды"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(tr("Итог…")) { lib.showCullSummary = true }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.2))
    }

    private func counter(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color)
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
                if lib.cullHints {
                    ForEach(v.reasons) { r in tag(r.title, r.icon, r.isDefect ? .orange : .yellow) }
                    if photo.isBestInSeries { tag(tr("Лучший в серии"), "sparkles", Theme.star) }
                    if v.reasons.contains(.tilted) {
                        Button { lib.straightenByHorizon() } label: { tag(tr("Выровнять"), "level", .accentColor) }
                            .buttonStyle(.plain).allowsHitTesting(true)
                    }
                }
                Spacer()
                if lib.cullHints, photo.cull != nil {
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
                let e = face.eyes ?? 0.3
                Image(systemName: e < 0.2 ? "eye.slash.fill" : "eye.fill").foregroundStyle(e < 0.2 ? .orange : .green)
                Text(e < 0.2 ? tr("глаза закрыты?") : tr("глаза открыты")).font(.caption)
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
            if lib.cullHints && !reasons.isEmpty {
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
