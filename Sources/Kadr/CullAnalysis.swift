import CoreGraphics
import Foundation
import Vision

/// A face in the frame: box in frame fractions (y from top to bottom), quality, eye openness, sharpness.
struct FaceInfo: Codable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    var quality: Double?        // built-in macOS score 0…1: sharpness, pose, face lighting
    var eyes: Double?           // eye openness: contour height/width (open ~0.3–0.45)
    var sharpness: Double?      // sharpness within the face area
    var px: Double?             // face width in preview pixels: small faces are unreliable for eyes and sharpness
    var blink: Double?          // blink of both eyes from the MediaPipe face mesh 0…1 (closed ≥ ~0.42), if the models are installed
    var squint: Double?         // squint from MediaPipe: smiles and sun, not a blink
    var lookDown: Double?       // downward gaze from MediaPipe
    var pitch: Double?          // head pitch from macOS, degrees (> 0 means the head is lowered)

    /// The face is usable for eye and sharpness checks: large and turned toward the camera.
    /// Calibrated on 2032 frames: for faces smaller than ~180 px, eye openness and sharpness are measured noticeably worse.
    var reliable: Bool { (px ?? 0) >= 180 && (quality ?? 0) >= 0.35 }

    /// Eyes were measured by the MediaPipe mesh. The macOS "face quality" filter isn't needed here: with closed eyes
    /// macOS lowers the quality itself (~0.3), and the mesh rejects profiles and the backs of heads on its own.
    var meshUsable: Bool { blink != nil && (px ?? 0) >= 120 }
    /// Eyes are open: per MediaPipe if there is a measurement, otherwise per the macOS contour.
    var eyesOpen: Bool { blink.map { $0 < 0.3 } ?? ((eyes ?? 0.3) >= 0.22) }
    /// Eyes are closed (threshold depends on strictness, 0…1). Calibrated on 2032 frames: on blinks both eyes are ≥ 0.42
    /// and "look down" is ≥ 0.5; "look down" ~0 with "closed" eyes means dark glasses.
    func eyesShut(_ st: Double = 0.5) -> Bool {
        guard let blink else { return (eyes ?? 0.3) < 0.12 + 0.04 * st }
        return blink >= 0.45 - 0.1 * st && (lookDown ?? 1) >= 0.35
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Everything Culling needs: computed in the background from the embedded preview and stored in the index.
struct CullData: Codable, Sendable, Hashable {
    var faces: [FaceInfo] = []
    var subject: CGRectCodable?     // main subject, if there are no faces
    var subjectSharpness: Double?   // sharpness of the best face or the main subject
    var clipHigh = 0.0              // fraction of blown-out pixels
    var clipLow = 0.0               // fraction of crushed shadows
    var meanLuma: Double?           // mean luminance 0…1 (for underexposure)
    var brightLuma: Double?         // 95th-percentile luminance: whether the frame has any bright areas
    var subjectClip: Double?        // overexposure on the face or main subject (white sky behind is not a defect)
    var horizon: Double?            // horizon tilt, degrees
    var aesthetics: Double?         // frame aesthetics as scored by macOS (−1…1)
    var utility = false             // utility frame: screen, document, accidental shot
    var people: [CGRectCodable]?    // full-body boxes of people (for auto crop: never cut a figure)
    var mesh: Bool?                 // eyes were measured by the MediaPipe face mesh (frames with faces are reanalyzed after the models are installed)
}

struct CGRectCodable: Codable, Sendable, Hashable {
    var x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

enum CullAnalyzer {
    /// ~25 ms per frame after the first run (macOS models load once, ~1 s).
    /// On macOS 14 there is no recognition (center sharpness, overexposure and crushed shadows only).
    static func analyze(_ img: CGImage) async -> CullData {
        if #available(macOS 15.0, *) { return await analyzeVision(img) }
        var d = CullData()
        d.subjectSharpness = ImageStore.shared.sharpness(img)
        (d.clipHigh, d.clipLow, d.meanLuma, d.brightLuma) = clipping(img)
        return d
    }

    @available(macOS 15.0, *)
    private static func analyzeVision(_ img: CGImage) async -> CullData {
        var d = CullData()
        // Vision measures from the bottom-left corner; convert to top-to-bottom.
        func topDown(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

        let marks = (try? await DetectFaceLandmarksRequest().perform(on: img)) ?? []
        let quality = (try? await DetectFaceCaptureQualityRequest().perform(on: img)) ?? []
        for f in marks {
            let r = topDown(f.boundingBox.cgRect)
            // Quality comes from the second request, matched by the nearest box center.
            let q = quality.min { a, b in
                dist(topDown(a.boundingBox.cgRect), r) < dist(topDown(b.boundingBox.cgRect), r)
            }.flatMap { $0.captureQuality.map { Double($0.score) } }
            var eyes: [Double] = []
            for e in [f.landmarks?.leftEye, f.landmarks?.rightEye].compactMap({ $0 }) {
                let pts = e.points.map(\.cgPoint)
                guard let xmin = pts.map(\.x).min(), let xmax = pts.map(\.x).max(),
                      let ymin = pts.map(\.y).min(), let ymax = pts.map(\.y).max(), xmax > xmin else { continue }
                eyes.append(Double((ymax - ymin) / (xmax - xmin)))
            }
            var face = FaceInfo(x: r.minX, y: r.minY, w: r.width, h: r.height, quality: q,
                                eyes: eyes.isEmpty ? nil : eyes.reduce(0, +) / Double(eyes.count))
            face.px = Double(r.width) * Double(img.width)
            face.pitch = f.pitch.converted(to: .degrees).value
            face.sharpness = ImageStore.shared.sharpness(img, region: r)
            d.faces.append(face)
        }
        d.faces.sort { $0.w * $0.h > $1.w * $1.h }   // largest faces first
        // Eyes via the MediaPipe face mesh (~12 ms per face): tells a blink apart from a squint or a downward gaze.
        let mesh = FaceMesh.shared
        if !d.faces.isEmpty, mesh.available {
            d.mesh = true
            for i in d.faces.indices.prefix(6) where (d.faces[i].px ?? 0) >= 40 {
                // The mesh didn't find a face: almost always a profile, so we don't judge the eyes (the macOS contour is wrong here too).
                guard let e = mesh.eyes(img, face: d.faces[i].rect) else { d.faces[i].eyes = nil; continue }
                d.faces[i].blink = e.blink
                d.faces[i].squint = e.squint
                d.faces[i].lookDown = e.lookDown
            }
        }

        if !d.faces.contains(where: \.reliable), let sal = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: img),
           let o = sal.salientObjects.first {
            let xs = [o.topLeft, o.topRight, o.bottomLeft, o.bottomRight].map(\.cgPoint.x)
            let ys = [o.topLeft, o.topRight, o.bottomLeft, o.bottomRight].map(\.cgPoint.y)
            let r = topDown(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            d.subject = CGRectCodable(x: r.minX, y: r.minY, w: r.width, h: r.height)
        }
        // Sharpness of the "main" subject: the best of the large camera-facing faces, otherwise the saliency object, otherwise the frame center.
        // A small face gets stretched when measured and always looks "blurry"; the back of a head isn't a face either.
        if let best = d.faces.filter(\.reliable).compactMap(\.sharpness).max() {
            d.subjectSharpness = best
        } else if let s = d.subject {
            d.subjectSharpness = ImageStore.shared.sharpness(img, region: s.rect)
        } else {
            d.subjectSharpness = ImageStore.shared.sharpness(img)
        }

        var humans = DetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        if let hs = try? await humans.perform(on: img) {
            d.people = hs.filter { $0.confidence >= 0.5 }.map { o in
                let r = topDown(o.boundingBox.cgRect)
                return CGRectCodable(x: r.minX, y: r.minY, w: r.width, h: r.height)
            }
        }
        if let h = try? await DetectHorizonRequest().perform(on: img) {
            d.horizon = h.angle.converted(to: .degrees).value
        }
        if let a = try? await CalculateImageAestheticsScoresRequest().perform(on: img) {
            d.aesthetics = Double(a.overallScore)
            d.utility = a.isUtility
        }
        (d.clipHigh, d.clipLow, d.meanLuma, d.brightLuma) = clipping(img)
        if let f = d.faces.first(where: \.reliable) { d.subjectClip = clipping(img, region: f.rect) }
        else if let s = d.subject { d.subjectClip = clipping(img, region: s.rect) }
        return d
    }

    /// Fraction of overexposed pixels within a frame region.
    static func clipping(_ img: CGImage, region r: CGRect) -> Double? {
        let px = CGRect(x: r.minX * CGFloat(img.width), y: r.minY * CGFloat(img.height),
                        width: r.width * CGFloat(img.width), height: r.height * CGFloat(img.height)).integral
        guard px.width >= 8, px.height >= 8, let crop = img.cropping(to: px) else { return nil }
        return clipping(crop).0
    }

    private static func dist(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }

    /// Fraction of blown highlights and crushed shadows plus mean luminance, from a downscaled preview.
    static func clipping(_ img: CGImage) -> (Double, Double, Double, Double) {
        let w = 320, h = max(1, Int(Double(w) * Double(img.height) / Double(img.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (0, 0, 0.5, 0.9) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hi = 0, lo = 0, luma = 0
        var hist = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: px.count, by: 4) {
            let l = (Int(px[i]) * 54 + Int(px[i + 1]) * 183 + Int(px[i + 2]) * 19) >> 8
            luma += l
            hist[min(255, l)] += 1
            let mx = max(px[i], px[i + 1], px[i + 2]), mn = min(px[i], px[i + 1], px[i + 2])
            if mx >= 253 { hi += 1 }
            if mx <= 4 && mn <= 4 { lo += 1 }
        }
        let n = Double(w * h)
        var acc = 0, p95 = 255
        for (v, c) in hist.enumerated() { acc += c; if Double(acc) >= n * 0.95 { p95 = v; break } }
        return (Double(hi) / n, Double(lo) / n, Double(luma) / n / 255, Double(p95) / 255)
    }
}
