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

    /// Mask of the object under the clicks (fractions of the frame, top-down) at the preview's size:
    /// of SAM's three candidates, the largest one with a decent score — the whole object, not a part of it.
    func segment(_ url: URL, points: [CGPoint]) -> CGImage? {
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
        for p in points {
            guard let pts = try? MLMultiArray(shape: [1, 1, 2], dataType: .float32),
                  let lab = try? MLMultiArray(shape: [1, 1], dataType: .float32) else { return nil }
            pts[0] = NSNumber(value: Float(p.x * 1024)); pts[1] = NSNumber(value: Float(p.y * 1024)); lab[0] = 1
            guard let po = try? pe.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": pts, "labels": lab])),
                  let sp = po.featureValue(for: "sparse_embeddings"), let de = po.featureValue(for: "dense_embeddings"),
                  let out = try? dec.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "image_embedding": e.featureValue(for: "image_embedding")!, "sparse_embedding": sp, "dense_embedding": de,
                    "feats_s0": e.featureValue(for: "feats_s0")!, "feats_s1": e.featureValue(for: "feats_s1")!])),
                  let masks = out.featureValue(for: "low_res_masks")?.multiArrayValue,
                  let scores = out.featureValue(for: "scores")?.multiArrayValue else { continue }
            let n = 256 * 256
            var best = -1, bestArea = 0
            for k in 0..<3 where scores[k].floatValue >= 0.5 {
                var a = 0
                for i in 0..<n where masks[k * n + i].floatValue > 0 { a += 1 }
                if a > bestArea { bestArea = a; best = k }
            }
            guard best >= 0 else { continue }
            var m = union ?? [Float](repeating: -1, count: n)
            for i in 0..<n { m[i] = max(m[i], masks[best * n + i].floatValue) }
            union = m
        }
        guard let m = union else { return nil }
        // 256×256 logits → grayscale mask stretched to the preview's size.
        var bytes = m.map { UInt8($0 > 0 ? 255 : 0) }
        guard let ctx = CGContext(data: &bytes, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let small = ctx.makeImage(),
              let big = CGContext(data: nil, width: prev.width, height: prev.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        big.interpolationQuality = .high
        big.draw(small, in: CGRect(x: 0, y: 0, width: prev.width, height: prev.height))
        return big.makeImage()
    }

    // MARK: - Remove (LaMa)

    private static var cacheDir: URL {
        let u = AppFolders.support.appendingPathComponent("Cache/Retouch", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func patchURL(_ id: String) -> URL { cacheDir.appendingPathComponent(id + ".png") }

    /// Paints out the masked object. Works on a square around it (1.8× the object, at least 512 px of the frame),
    /// at full resolution of the RAW base; LaMa sees it at 800×800.
    func remove(_ url: URL, mask: CGImage) -> Removal? {
        guard let lama = model(Self.files[3]), let base = EditPipeline.source(url, maxSide: nil) else { return nil }
        let e = base.extent.integral
        let W = Double(e.width), H = Double(e.height)
        // Mask bounding box in fractions, then the working square in pixels of the base.
        guard let mb = Self.boundingBox(mask) else { return nil }
        let grow = 0.012   // ~1.2% of the frame: SAM's edge is tight, halos would stay
        let bb = CGRect(x: mb.minX - grow, y: mb.minY - grow, width: mb.width + 2 * grow, height: mb.height + 2 * grow)
        var side = max(bb.width * W, bb.height * H) * 1.8
        side = min(max(side, 512), min(W, H))
        let cx = bb.midX * W, cy = bb.midY * H
        let sq = CGRect(x: min(max(cx - side / 2, 0), W - side), y: min(max(cy - side / 2, 0), H - side), width: side, height: side).integral
        let frac = CGRect(x: sq.minX / W, y: sq.minY / H, width: sq.width / W, height: sq.height / H)

        // Base crop (top-down → Core Image's bottom-up), clamped to 0…1, at 800×800 in sRGB.
        let ciRect = CGRect(x: e.minX + sq.minX, y: e.minY + (H - sq.maxY), width: sq.width, height: sq.height)
        let k = 800 / sq.width
        let crop = base.applyingFilter("CIColorClamp").cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cropCG = context.createCGImage(crop, from: CGRect(x: 0, y: 0, width: 800, height: 800), format: .RGBA8, colorSpace: srgb) else { return nil }
        guard let maskCG = Self.maskCrop(mask, frac: frac, grow: grow, size: 800) else { return nil }
        let img: MLFeatureValue, msk: MLFeatureValue
        do {
            img = try MLFeatureValue(cgImage: cropCG, pixelsWide: 800, pixelsHigh: 800, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
            msk = try MLFeatureValue(cgImage: maskCG, pixelsWide: 800, pixelsHigh: 800, pixelFormatType: kCVPixelFormatType_OneComponent8, options: nil)
        } catch { return nil }
        let out: MLFeatureProvider
        do { out = try lama.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk])) }
        catch { return nil }
        guard let pb = out.featureValue(for: "output")?.imageBufferValue else { return nil }
        // Patch = LaMa's result only where the (feathered) mask is, transparent elsewhere.
        let painted = CIImage(cvPixelBuffer: pb)
        let alpha = CIImage(cgImage: maskCG).applyingGaussianBlur(sigma: 3).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 800))
        let patch = painted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: alpha])
        let id = UUID().uuidString
        do {
            try context.writePNGRepresentation(of: patch.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 800)), to: Self.patchURL(id),
                                               format: .RGBA8, colorSpace: srgb)
        } catch { return nil }
        return Removal(id: id, x: frac.minX, y: frac.minY, w: frac.width, h: frac.height)
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

extension Library {
    func startRemove() {
        guard let p = current else { return }
        guard Retouch.shared.installed else { flash(tr("Модели «Убрать объект» не установлены (Настройки → AI)")); return }
        if cropMode { finishCrop() }
        removeMode = true; loupe = true; setZoom(nil)
        removePoints = []; removeMask = nil
        removeFor = p.id
    }

    /// Click: one more point on the object (fractions of the uncropped frame).
    func removeTap(_ pt: CGPoint) {
        guard let p = current, !removeBusy else { return }
        removePoints.append(pt)
        let url = p.url, pts = removePoints, id = p.id
        removeBusy = true
        Task.detached(priority: .userInitiated) {
            let m = Retouch.shared.segment(url, points: pts)
            await MainActor.run { [weak self] in
                guard let self, self.currentID == id else { return }
                self.removeMask = m; self.removeBusy = false
                if m == nil { self.flash(tr("Не удалось выделить — кликните в другое место объекта")) }
            }
        }
    }

    /// Enter: paint the selected object out (~1–2 s); the mode stays for the next object.
    func applyRemove() {
        guard let p = current, let mask = removeMask, !removeBusy else { return }
        let url = p.url, id = p.id
        removeBusy = true
        Task.detached(priority: .userInitiated) {
            let r = Retouch.shared.remove(url, mask: mask)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.removeBusy = false
                guard self.currentID == id, let r, var a = self.current?.adj else {
                    if r == nil { self.flash(tr("Не удалось убрать объект")) }
                    return
                }
                a.removals.append(r)
                self.setAdjustments(a)
                self.removePoints = []; self.removeMask = nil
                self.flash(tr("Объект убран — ⌘Z, чтобы вернуть"))
            }
        }
    }

    func clearRemoveSelection() { removePoints = []; removeMask = nil }

    func finishRemove() { removeMode = false; removePoints = []; removeMask = nil }
}

import SwiftUI

/// The photo uncropped, with the selected object highlighted; clicks add points.
struct RemoveView: View {
    @Environment(Library.self) private var lib
    let photo: Photo

    var body: some View {
        GeometryReader { geo in
            let s = lib.pixelSize(photo)
            let k = min((geo.size.width - 40) / s.width, (geo.size.height - 40) / s.height)
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
                    ProgressView().controlSize(.large)
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
        HStack(spacing: 12) {
            Label(tr("Убрать объект"), systemImage: "eraser").font(.callout.weight(.semibold))
            Text(lib.removeMask == nil ? tr("Кликните по объекту — AI выделит его целиком; ещё клик — добавить часть")
                                       : tr("Enter — убрать · клик — добавить к выделению · Esc — сбросить"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(tr("Сбросить выделение")) { lib.clearRemoveSelection() }.disabled(lib.removePoints.isEmpty)
            Button(tr("Убрать (Enter)")) { lib.applyRemove() }.buttonStyle(.borderedProminent).disabled(lib.removeMask == nil || lib.removeBusy)
            Button(tr("Готово")) { lib.finishRemove() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
    }
}
