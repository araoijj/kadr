import CoreGraphics
import CoreImage
import CoreML
import Foundation

/// A removed object: a patch painted by LaMa, cached as a PNG with a feathered alpha; `rect` in fractions of
/// the uncropped frame (top-down). Stored in the photo's edits, so it's non-destructive and undoable.
struct Removal: Codable, Hashable, Sendable {
    var id: String
    var x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// "Remove Object": click → SAM 2.1 (Meta, Apache 2.0; Core ML by Apple) selects the object →
/// LaMa (Apache 2.0) paints it out. The patch is computed from the developed RAW base (before the profile
/// and edits), so colors match; the photo itself is never changed.
final class Retouch: @unchecked Sendable {
    static let shared = Retouch()
    static let files = ["SAM2_1SmallImageEncoderFLOAT16", "SAM2_1SmallPromptEncoderFLOAT16", "SAM2_1SmallMaskDecoderFLOAT16", "LaMa"]

    private let lock = NSLock()
    private var models: [String: MLModel] = [:]
    private var tried = false
    private var installedCache: Bool?
    private var embedding: (url: URL, out: MLFeatureProvider)?
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    var folder: URL { FaceMesh.shared.folder }

    var installed: Bool {
        lock.withLock {
            if let installedCache { return installedCache }
            let v = Self.files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0 + ".mlmodelc").path) }
            installedCache = v
            return v
        }
    }

    /// Installs every .mlpackage of the set found under `src` (compiling them).
    func install(from src: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let en = fm.enumerator(at: src, includingPropertiesForKeys: nil)
        while let u = en?.nextObject() as? URL {
            let name = u.deletingPathExtension().lastPathComponent
            guard Self.files.contains(name), u.pathExtension == "mlpackage" else { continue }
            en?.skipDescendants()
            let compiled = try MLModel.compileModel(at: u)
            let dst = folder.appendingPathComponent(name + ".mlmodelc")
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: compiled, to: dst)
            try? fm.removeItem(at: compiled)
        }
        lock.withLock { tried = false; models = [:]; installedCache = nil }
    }

    private func model(_ name: String) -> MLModel? {
        lock.withLock {
            if !tried {
                tried = true
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .all
                for n in Self.files { models[n] = try? MLModel(contentsOf: folder.appendingPathComponent(n + ".mlmodelc"), configuration: cfg) }
            }
            return models[name]
        }
    }

    // MARK: - Select (SAM)

    func hasEmbedding(_ url: URL) -> Bool { lock.withLock { embedding?.url == url } }

    /// Computes the photo's image embedding ahead of the first click (the slow part, up to ~10 s on first use).
    func prepare(_ url: URL) {
        guard !hasEmbedding(url), let enc = model(Self.files[0]), let prev = ImageStore.shared.preview(url),
              let px = try? MLFeatureValue(cgImage: prev, pixelsWide: 1024, pixelsHigh: 1024, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let out = try? enc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": px])) else { return }
        lock.withLock { embedding = (url, out) }
    }

    /// What SAM selected under the clicks, with what the user needs to judge it.
    struct Selection {
        var mask: CGImage          // preview-sized, white = object
        var area: Double           // share of the frame
        var score: Double          // SAM's own estimate of the mask quality (lowest over the clicks), 0…1
        var bbox: CGRect           // fractions, top-down
        var lastClickMissed: Bool  // the newest click found nothing (earlier clicks' mask is kept)
    }

    /// Mask of the object under the clicks (fractions of the frame, top-down) at the preview's size:
    /// of SAM's three candidates, the largest one with a decent score — the whole object, not a part of it.
    func segment(_ url: URL, points: [CGPoint]) -> Selection? {
        guard let enc = model(Self.files[0]), let pe = model(Self.files[1]), let dec = model(Self.files[2]),
              let prev = ImageStore.shared.preview(url), !points.isEmpty else { return nil }
        // The image embedding (the slow part, ~0.3 s) is computed once per photo.
        var e = lock.withLock { embedding?.url == url ? embedding?.out : nil }
        if e == nil {
            guard let px = try? MLFeatureValue(cgImage: prev, pixelsWide: 1024, pixelsHigh: 1024, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
                  let out = try? enc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": px])) else { return nil }
            lock.withLock { embedding = (url, out) }
            e = out
        }
        guard let e else { return nil }
        // One click at a time (the prompt encoder takes one point); masks of several clicks are united.
        var union: [Float]?
        var score = 1.0, lastMissed = false
        for (i, p) in points.enumerated() {
            guard let pts = try? MLMultiArray(shape: [1, 1, 2], dataType: .float32),
                  let lab = try? MLMultiArray(shape: [1, 1], dataType: .float32) else { return nil }
            pts[0] = NSNumber(value: Float(p.x * 1024)); pts[1] = NSNumber(value: Float(p.y * 1024)); lab[0] = 1
            var best = -1, bestArea = 0
            let n = 256 * 256
            if let po = try? pe.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": pts, "labels": lab])),
               let sp = po.featureValue(for: "sparse_embeddings"), let de = po.featureValue(for: "dense_embeddings"),
               let out = try? dec.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                   "image_embedding": e.featureValue(for: "image_embedding")!, "sparse_embedding": sp, "dense_embedding": de,
                   "feats_s0": e.featureValue(for: "feats_s0")!, "feats_s1": e.featureValue(for: "feats_s1")!])),
               let masks = out.featureValue(for: "low_res_masks")?.multiArrayValue,
               let scores = out.featureValue(for: "scores")?.multiArrayValue {
                for k in 0..<3 where scores[k].floatValue >= 0.5 {
                    var a = 0
                    for i in 0..<n where masks[k * n + i].floatValue > 0 { a += 1 }
                    if a > bestArea { bestArea = a; best = k }
                }
                if best >= 0 {
                    score = min(score, Double(scores[best].floatValue))
                    var m = union ?? [Float](repeating: -20, count: n)
                    for i in 0..<n { m[i] = max(m[i], masks[best * n + i].floatValue) }
                    union = m
                }
            }
            if i == points.count - 1 { lastMissed = best < 0 }
        }
        guard let m = union else { return nil }
        // SAM's 256×256 logits, interpolated to the preview's size before thresholding: smooth edges instead of
        // 256-px stair steps (at 24 MP one step is ~23 px — enough to leave a rim of the object behind).
        let w = prev.width, h = prev.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        var count = 0, x0 = w, y0 = h, x1 = -1, y1 = -1
        let sx = 256.0 / Double(w), sy = 256.0 / Double(h)
        for y in 0..<h {
            let fy = min(max((Double(y) + 0.5) * sy - 0.5, 0), 255)
            let iy = min(Int(fy), 254), ty = Float(fy - Double(iy))
            for x in 0..<w {
                let fx = min(max((Double(x) + 0.5) * sx - 0.5, 0), 255)
                let ix = min(Int(fx), 254), tx = Float(fx - Double(ix))
                let a = m[iy * 256 + ix], b = m[iy * 256 + ix + 1], c = m[(iy + 1) * 256 + ix], d = m[(iy + 1) * 256 + ix + 1]
                let v = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                if v > 0 {
                    bytes[y * w + x] = 255; count += 1
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
        }
        guard count > 0,
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return nil }
        return Selection(mask: img, area: Double(count) / Double(w * h), score: score,
                         bbox: CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h),
                                      width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h)),
                         lastClickMissed: lastMissed)
    }

    // MARK: - Remove (LaMa)

    private static var cacheDir: URL {
        let u = AppFolders.support.appendingPathComponent("Cache/Retouch", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// 8-bit PNG, or a half-float TIFF when the patch keeps RAW highlights above white.
    static func patchURL(_ id: String) -> URL {
        let tiff = cacheDir.appendingPathComponent(id + ".tiff")
        return FileManager.default.fileExists(atPath: tiff.path) ? tiff : cacheDir.appendingPathComponent(id + ".png")
    }

    /// Paints out the masked object. LaMa works on a square around it (1.8× the object, at least 512 px of the
    /// frame) at 800×800, so a large object comes out softer: it needs that much surrounding background to
    /// invent a believable one (splitting it into smaller squares was tried — sharper but blotchy).
    func remove(_ url: URL, mask: CGImage) -> [Removal] {
        guard let lama = model(Self.files[3]), let base = EditPipeline.source(url, maxSide: nil),
              let mb = Self.boundingBox(mask) else { return [] }
        let e = base.extent.integral
        let W = Double(e.width), H = Double(e.height)
        let grow = 0.008   // ~0.8% of the frame: covers the soft rim of the object without biting into neighbors
        let bb = CGRect(x: mb.minX - grow, y: mb.minY - grow, width: mb.width + 2 * grow, height: mb.height + 2 * grow)
        var side = max(bb.width * W, bb.height * H) * 1.8
        side = min(max(side, 512), min(W, H))
        let cx = bb.midX * W, cy = bb.midY * H
        let sq = CGRect(x: min(max(cx - side / 2, 0), W - side), y: min(max(cy - side / 2, 0), H - side), width: side, height: side).integral
        let frac = CGRect(x: sq.minX / W, y: sq.minY / H, width: sq.width / W, height: sq.height / H)

        // Base crop (top-down → Core Image's bottom-up) at 800×800.
        let size = 800.0, canvas = CGRect(x: 0, y: 0, width: size, height: size)
        let ciRect = CGRect(x: e.minX + sq.minX, y: e.minY + (H - sq.maxY), width: sq.width, height: sq.height)
        let k = size / sq.width
        let crop = base.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
        // RAW highlights above white: scaled down for LaMa (it sees 0…1) and back up, so the patch matches
        // the photo at any exposure instead of turning into a flat gray spot.
        let peak = Self.peak(crop, context)
        let scale = peak > 1 ? 1 / min(peak, 8) : 1
        let input = crop.applyingFilter("CIColorMatrix", parameters: Self.gain(scale)).applyingFilter("CIColorClamp")
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cropCG = context.createCGImage(input, from: canvas, format: .RGBA8, colorSpace: srgb),
              let maskCG = Self.maskCrop(mask, frac: frac, grow: grow, size: Int(size)) else { return [] }
        let img: MLFeatureValue, msk: MLFeatureValue
        do {
            img = try MLFeatureValue(cgImage: cropCG, pixelsWide: Int(size), pixelsHigh: Int(size), pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
            msk = try MLFeatureValue(cgImage: maskCG, pixelsWide: Int(size), pixelsHigh: Int(size), pixelFormatType: kCVPixelFormatType_OneComponent8, options: nil)
        } catch { return [] }
        guard let out = try? lama.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk])),
              let pb = out.featureValue(for: "output")?.imageBufferValue else { return [] }
        let painted = CIImage(cvPixelBuffer: pb, options: [.colorSpace: srgb])
            .applyingFilter("CIColorMatrix", parameters: Self.gain(1 / scale))
        // Alpha: the mask pulled in slightly before feathering, so the soft edge lies on painted pixels
        // (a feather reaching outside them leaves a blurry rim around the removed object).
        let alpha = CIImage(cgImage: maskCG).applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2.0])
            .applyingGaussianBlur(sigma: 2.5).cropped(to: canvas)
        let patch = painted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: alpha])
            .cropped(to: canvas)
        let id = UUID().uuidString
        do {
            if scale < 1 {   // values above white need a float file
                try context.writeTIFFRepresentation(of: patch, to: Self.cacheDir.appendingPathComponent(id + ".tiff"), format: .RGBAh,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            } else {
                try context.writePNGRepresentation(of: patch, to: Self.cacheDir.appendingPathComponent(id + ".png"), format: .RGBA8, colorSpace: srgb)
            }
        } catch { return [] }
        return [Removal(id: id, x: frac.minX, y: frac.minY, w: frac.width, h: frac.height)]
    }

    private static func gain(_ g: Double) -> [String: Any] {
        ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
         "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]
    }

    /// Brightest channel value in the 800×800 crop (1 = white).
    private static func peak(_ img: CIImage, _ ctx: CIContext) -> Double {
        guard let f = CIFilter(name: "CIAreaMaximum", parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: CGRect(x: 0, y: 0, width: 800, height: 800))]),
              let o = f.outputImage else { return 1 }
        var px = [Float](repeating: 0, count: 4)
        ctx.render(o, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(max(px[0], px[1], px[2]))
    }

    /// Patches over the base (before geometry and edits): each scaled into its rect.
    static func composite(_ base: CIImage, _ removals: [Removal]) -> CIImage {
        let e = base.extent
        var img = base
        for r in removals {
            guard let p = CIImage(contentsOf: patchURL(r.id)) else { continue }
            let pe = p.extent
            let dst = CGRect(x: e.minX + r.x * e.width, y: e.minY + (1 - r.y - r.h) * e.height, width: r.w * e.width, height: r.h * e.height)
            let placed = p.transformed(by: CGAffineTransform(scaleX: dst.width / pe.width, y: dst.height / pe.height))
                .transformed(by: CGAffineTransform(translationX: dst.minX, y: dst.minY))
            img = placed.composited(over: img)
        }
        return img.cropped(to: e)
    }

    // MARK: - Mask helpers

    /// Bounding box of the white area, fractions top-down.
    static func boundingBox(_ m: CGImage) -> CGRect? {
        let w = m.width, h = m.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(m, in: CGRect(x: 0, y: 0, width: w, height: h))
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where px[y * w + x] > 127 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= 0 else { return nil }
        return CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h), width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h))
    }

    /// The part of the full-frame mask inside `frac`, grown by `grow` (fraction of the frame), at size×size.
    /// Parts of `frac` outside the frame stay black.
    static func maskCrop(_ m: CGImage, frac: CGRect, grow: Double, size: Int) -> CGImage? {
        let W = Double(m.width), H = Double(m.height)
        guard let crop = m.cropping(to: CGRect(x: frac.minX * W, y: frac.minY * H, width: frac.width * W, height: frac.height * H).integral) else { return nil }
        // Dilation via Core Image (morphology max) so thin halos around the object go too.
        let r = grow * W * Double(size) / (frac.width * W)
        let ci = CIImage(cgImage: crop).transformed(by: CGAffineTransform(scaleX: Double(size) / Double(crop.width), y: Double(size) / Double(crop.height)))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, r)])
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        return CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: size, height: size), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}

// MARK: - Library: the Remove Object mode

/// Feedback on a selection: what was selected, how reliable it is, and why it may not work.
struct RemoveStatus: Equatable {
    enum Level { case ok, warn, fail }
    var level: Level
    var text: String
    var blocksApply = false

    /// Above this share of the frame LaMa can't invent a believable background.
    static let maxArea = 0.35
    /// Above this the patch is visibly softer than the photo.
    static let largeArea = 0.12

    static func assess(_ s: Retouch.Selection?) -> RemoveStatus {
        guard let s else {
            return RemoveStatus(level: .fail, text: tr("AI не нашёл здесь отдельного объекта. Кликните ближе к его центру. Лучше всего выделяются люди, машины, мусор, знаки; фон, небо, трава, тени и отражения — плохо."))
        }
        let pct = s.area < 0.01 ? "<1" : "\(Int((s.area * 100).rounded()))"
        if s.area > maxArea {
            return RemoveStatus(level: .fail, text: tr("Выделено \(pct)% кадра — слишком много: такую область AI не дорисует правдоподобно. Сбросьте выделение (Esc) и кликните по самому объекту."), blocksApply: true)
        }
        if s.lastClickMissed {
            return RemoveStatus(level: .warn, text: tr("Последний клик не нашёл объекта — выделение осталось прежним. Кликните по самой заметной части."))
        }
        if s.area > largeArea {
            return RemoveStatus(level: .warn, text: tr("Большая область (\(pct)% кадра): дорисованное будет мягче и может быть заметно. Лучше всего получаются небольшие объекты."))
        }
        if s.score < 0.7 {
            return RemoveStatus(level: .warn, text: tr("AI не уверен в границах (\(Int(s.score * 100))%) — проверьте красную заливку. Пропущенную часть добавьте кликом."))
        }
        return RemoveStatus(level: .ok, text: tr("Выделено \(pct)% кадра, уверенность \(Int(s.score * 100))%. Enter — убрать. Тень или отражение объекта кликните отдельно."))
    }
}

extension Library {
    func startRemove() {
        guard let p = current else { return }
        guard Retouch.shared.installed else { flash(tr("Модели «Убрать объект» не установлены (Настройки → AI)")); return }
        if cropMode { finishCrop() }
        removeMode = true; loupe = true; setZoom(nil)
        clearRemoveSelection()
        removeFor = p.id
        // The tool is on: get the photo ready now, so the first click answers in a fraction of a second.
        guard !Retouch.shared.hasEmbedding(p.url) else { return }
        let url = p.url, id = p.id
        removeBusy = true; removeBusyText = tr("AI изучает кадр… (в первый раз — до 10 с)")
        Task.detached(priority: .userInitiated) {
            Retouch.shared.prepare(url)
            await MainActor.run { [weak self] in
                guard let self, self.removeFor == id else { return }
                self.removeBusy = false; self.removeBusyText = nil
            }
        }
    }

    /// Click: one more point on the object (fractions of the uncropped frame).
    func removeTap(_ pt: CGPoint) {
        guard let p = current else { return }
        guard !removeBusy else { flash(tr("Подождите — AI ещё считает")); return }
        removePoints.append(pt)
        let url = p.url, pts = removePoints, id = p.id
        removeBusy = true
        removeBusyText = Retouch.shared.hasEmbedding(url) ? tr("Выделяю…") : tr("AI изучает кадр… (в первый раз — до 10 с)")
        Task.detached(priority: .userInitiated) {
            let sel = Retouch.shared.segment(url, points: pts)
            await MainActor.run { [weak self] in
                guard let self, self.currentID == id else { return }
                self.removeBusy = false; self.removeBusyText = nil
                self.removeStatus = RemoveStatus.assess(sel)
                if let sel {
                    self.removeMask = sel.mask; self.removeArea = sel.area
                    if sel.lastClickMissed { self.removePoints.removeLast() }   // a miss adds nothing: don't keep its dot
                }
                else if self.removeMask == nil { self.removePoints = [] }   // nothing selected yet: drop the missed point
                else { self.removePoints.removeLast() }                       // keep the earlier selection as it was
            }
        }
    }

    /// Enter: paint the selected object out (~1–5 s); the mode stays for the next object.
    func applyRemove() {
        guard let p = current, let mask = removeMask, !removeBusy else { return }
        if removeStatus?.blocksApply == true { flash(removeStatus!.text); return }
        let url = p.url, id = p.id, large = removeArea > RemoveStatus.largeArea
        removeBusy = true; removeBusyText = tr("Убираю объект…")
        Task.detached(priority: .userInitiated) {
            let parts = Retouch.shared.remove(url, mask: mask)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.removeBusy = false; self.removeBusyText = nil
                guard self.currentID == id, !parts.isEmpty, var a = self.current?.adj else {
                    if parts.isEmpty { self.removeStatus = RemoveStatus(level: .fail, text: tr("Не удалось убрать объект. Попробуйте выделить его заново.")) }
                    return
                }
                a.removals += parts
                self.setAdjustments(a)
                self.clearRemoveSelection()
                self.removeStatus = large
                    ? RemoveStatus(level: .warn, text: tr("Объект убран. Область большая — проверьте результат: \\ показывает исходник, ⌘Z возвращает."))
                    : RemoveStatus(level: .ok, text: tr("Объект убран — ⌘Z, чтобы вернуть. Можно выделять следующий."))
            }
        }
    }

    func clearRemoveSelection() { removePoints = []; removeMask = nil; removeStatus = nil; removeArea = 0 }

    func finishRemove() { removeMode = false; clearRemoveSelection() }
}

import SwiftUI

/// The photo uncropped, with the selected object highlighted; clicks add points.
struct RemoveView: View {
    @Environment(Library.self) private var lib
    let photo: Photo

    var body: some View {
        GeometryReader { geo in
            let s = lib.pixelSize(photo)
            let k = max(0.0001, min((geo.size.width - 40) / s.width, (geo.size.height - 40) / s.height))   // a tiny pane would go negative
            let shown = CGSize(width: s.width * k, height: s.height * k)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            ZStack(alignment: .topLeading) {
                Group {
                    var a = photo.adj
                    let _ = { a.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); a.angle = 0 }()
                    if a.isIdentity { SharpPreview(photo: photo) } else { EditedImage(photo: photo, adj: a) }
                }
                .frame(width: shown.width, height: shown.height)
                .offset(x: origin.x, y: origin.y)
                // The frame marks the mode: clicks here select objects, they don't zoom or pick photos.
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: shown.width + 6, height: shown.height + 6)
                    .offset(x: origin.x - 3, y: origin.y - 3)
                    .allowsHitTesting(false)
                if let m = lib.removeMask {
                    Rectangle().fill(Color.red.opacity(0.45))
                        .mask(Image(decorative: m, scale: 1).resizable().luminanceToAlpha())
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                }
                ForEach(Array(lib.removePoints.enumerated()), id: \.offset) { _, p in
                    Circle().fill(.white).frame(width: 9, height: 9).overlay(Circle().stroke(.red, lineWidth: 2))
                        .offset(x: origin.x + p.x * shown.width - 4.5, y: origin.y + p.y * shown.height - 4.5)
                        .allowsHitTesting(false)
                }
                if lib.removeBusy {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        if let t = lib.removeBusyText {
                            Text(t).font(.callout.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: Capsule())
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                let p = CGPoint(x: (loc.x - origin.x) / shown.width, y: (loc.y - origin.y) / shown.height)
                guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                lib.removeTap(p)
            }
        }
    }
}

struct RemoveBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Narrow column: icon buttons and a title that truncates, instead of labels wrapping letter by letter.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title.fixedSize()
                    Spacer(minLength: 8)
                    Button(tr("Сбросить выделение")) { lib.clearRemoveSelection() }.disabled(clearDisabled).fixedSize()
                    Button(tr("Убрать (Enter)")) { lib.applyRemove() }.buttonStyle(.borderedProminent)
                        .disabled(applyDisabled).fixedSize()
                    Button(tr("Выйти из режима")) { lib.finishRemove() }.fixedSize()
                    HintButton(id: "remove")
                }
                HStack(spacing: 8) {
                    title.lineLimit(1)
                    Spacer(minLength: 4)
                    Button { lib.clearRemoveSelection() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(clearDisabled).help(tr("Сбросить выделение"))
                    Button { lib.applyRemove() } label: { Image(systemName: "checkmark") }.buttonStyle(.borderedProminent)
                        .disabled(applyDisabled).help(tr("Убрать (Enter)"))
                    Button { lib.finishRemove() } label: { Image(systemName: "xmark") }.help(tr("Выйти из режима"))
                    HintButton(id: "remove")
                }
            }
            status
        }
        .controlSize(.small)
        .frame(maxWidth: 760)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
    }

    private var title: some View {
        Label(tr("Режим «Убрать объект»"), systemImage: "eraser").font(.callout.weight(.semibold))
            .foregroundStyle(Color.accentColor)
    }

    private var clearDisabled: Bool { lib.removePoints.isEmpty || lib.removeBusy }
    private var applyDisabled: Bool { lib.removeMask == nil || lib.removeBusy || lib.removeStatus?.blocksApply == true }

    /// What is happening and why: busy, the verdict on the selection, or how to start.
    @ViewBuilder private var status: some View {
        if lib.removeBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(lib.removeBusyText ?? tr("AI считает…"))
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let st = lib.removeStatus {
            Label {
                Text(st.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: st.level == .ok ? "checkmark.circle.fill" : st.level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(st.level == .ok ? Color.green : st.level == .warn ? Color.orange : Color.red)
            }
            .font(.caption)
        } else {
            Text(tr("Кликните по объекту — AI выделит его целиком, ещё клик добавит часть. Лучше всего получаются небольшие отдельные предметы на простом фоне: прохожий, мусор, провод, знак. Большие области, сложный фон и объекты, перекрывающие людей, дорисовываются хуже."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
