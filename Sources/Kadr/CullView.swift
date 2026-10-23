import AppKit
import SwiftUI

/// The "Culling" layer over the loupe and the grid (ToolsBar toggle, O): the AI verdict on the frame,
/// faces at 100%, the summary. Progress and counts live in the FilterBar while the layer is on;
/// the AI controls (hints, strictness, actions) in the sidebar's «Фильтры» tab.
/// One row over the frame: decision, reject reasons with their fixes, the score. The loupe places it
/// under its burst badge.
struct CullOverlay: View {
    let photo: Photo
    @Environment(Library.self) private var lib

    var body: some View {
        let v = lib.verdict(photo)
        HStack(alignment: .top, spacing: 6) {
            if photo.rejected {
                tag(tr("Брак"), "xmark.circle.fill", Theme.reject)
            } else if photo.rating > 0 {
                tag(tr("Оставлено") + " " + String(repeating: "★", count: photo.rating), "checkmark.circle.fill", .green)
            }
            if lib.aiOn {
                // The best of a burst is the keeper: what the analysis found there is advice, not a defect.
                // «Best in series» itself is said by the loupe's burst badge right above.
                ForEach(v.reasons) { r in
                    tag(r.title, r.icon, photo.isBestInSeries ? .secondary : r.isDefect ? .orange : .yellow)
                        .help(lib.explain(r, photo))
                }
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
                    .overlayCapsule()
                    .help(AIModule.scoreHelp)
            }
        }
    }

    private func tag(_ t: String, _ icon: String, _ c: Color) -> some View {
        Label(t, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlayCapsule()
    }
}

/// Faces in the current frame at 100%, so eye sharpness is visible right away without zooming.
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
            // The numbers behind the verdict, like Lightroom's Culling Info.
            HStack(spacing: 8) {
                if let b = face.blink { stat("eye", String(format: "%.2f", b), tr("Моргание (MediaPipe): закрыты ≥ 0.4")) }
                if let sm = face.smile { stat("face.smiling", String(format: "%.2f", sm), tr("Улыбка (MediaPipe): явная ≥ 0.6")) }
                if let s = face.sharpness, let m = lib.medianFaceSharpness(photo), m > 0 {
                    stat("scope", "\(Int((s / m * 100).rounded()))%", tr("Резкость лица относительно обычной для сцены"))
                }
            }
        }
        .task(id: ThumbKey(url: photo.url, adj: photo.adj)) {
            // Face in the edited image's coordinates (straightened and cropped); a square around the face at ~100% (380 px on Retina).
            let a = photo.adj
            // The face rect is in the camera-cropped frame: read the preview's shape first (off the main thread),
            // or pixelSize falls back to EXIF and a 4:3 RAW gets the square off the face.
            let url = photo.url
            if ImageStore.shared.previewAspect(url) == nil {
                _ = await Task.detached(priority: .userInitiated) { ImageStore.shared.preview(url) }.value
            }
            // Square in pixels (a 3:2 frame makes it a rectangle in fractions), within the image bounds.
            let ps = lib.pixelSize(photo)
            let W = ps.width * a.cropW, H = ps.height * a.cropH
            let f = EditPipeline.outputRect(face.rect, a, size: ps)
            let sidePx = min(max(f.width * W, f.height * H) * 1.5, W, H)
            let rw = sidePx / W, rh = sidePx / H
            let r = CGRect(x: min(max(f.midX - rw / 2, 0), 1 - rw), y: min(max(f.midY - rh / 2, 0), 1 - rh), width: rw, height: rh)
            let px = Library.cullFacePixels
            image = await Renderer.shared.renderRegion(photo.url, a, region: r, pixels: CGSize(width: px, height: px), channel: "face-\(index)")
        }
    }

    private func stat(_ icon: String, _ value: String, _ help: String) -> some View {
        Label(value, systemImage: icon).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).help(help)
    }
}

/// Culling summary: how many were kept and rejected, and what to do next.
struct CullSummary: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let d = lib.decided
        let reasons = CullReason.allCases.map { r in (r, lib.count(.reason(r))) }.filter { $0.1 > 0 }
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
            // Said outright, so an empty «Служебный кадр» or a flat score isn't taken for "nothing found".
            if lib.aiOn, lib.aiEnabled.contains(.aesthetics), !AIModule.supported.contains(.aesthetics) {
                Label(AIModule.unsupportedNote, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
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
