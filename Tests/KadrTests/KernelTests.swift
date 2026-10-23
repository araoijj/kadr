import CoreImage
import Foundation
import Testing
@testable import Kadr

/// The Metal kernels of the develop chain against their formulas computed on the CPU: the same pixels the
/// former Core Image Kernel Language kernels gave (checked once against them: identical to the bit).
@Suite struct KernelTests {
    static let w = 64, h = 48
    /// Float pipeline without colour management, so the kernels' arithmetic is what comes out.
    let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// Pseudo-random RGB in -0.1…1.2 (values outside 0…1 occur in the linear develop chain), alpha 1.
    static func pixels(_ seed: UInt32) -> [Float] {
        var x = seed | 1, px = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                x = x &* 1664525 &+ 1013904223
                px[i * 4 + c] = Float(x >> 8) / Float(1 << 24) * 1.3 - 0.1
            }
        }
        return px
    }

    static func image(_ px: [Float]) -> CIImage {
        CIImage(bitmapData: px.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16,
                size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
    }

    func render(_ img: CIImage?) throws -> [Float] {
        let img = try #require(img)
        var out = [Float](repeating: 0, count: Self.w * Self.h * 4)
        ctx.render(img, toBitmap: &out, rowBytes: Self.w * 16, bounds: CGRect(x: 0, y: 0, width: Self.w, height: Self.h),
                   format: .RGBAf, colorSpace: nil)
        return out
    }

    /// Largest difference over the colour channels; `f` gives the expected RGB of pixel i.
    func maxError(_ got: [Float], _ f: (Int) -> SIMD3<Float>) -> Float {
        (0..<(Self.w * Self.h)).map { i in
            let e = f(i)
            return (0..<3).map { abs(got[i * 4 + $0] - e[$0]) }.max()!
        }.max()!
    }

    let a = pixels(1), b = pixels(2), n = pixels(3)
    func rgb(_ p: [Float], _ i: Int) -> SIMD3<Float> { SIMD3(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]) }

    @Test(arguments: [0.0, 0.35, 1.0, 2.0])
    func lutStrengthMix(k: Double) throws {
        let kernel = try CIColorKernel(functionName: "mixk", fromMetalLibraryData: KernelLibrary.data)
        let got = try render(kernel.apply(extent: Self.image(a).extent, arguments: [Self.image(a), Self.image(b), k]))
        let err = maxError(got) { i in
            let x = rgb(a, i) + (rgb(b, i) - rgb(a, i)) * Float(k)
            return SIMD3(max(x.x, 0), max(x.y, 0), max(x.z, 0))
        }
        #expect(err < 1e-5)
    }

    @Test(arguments: [0.0, 0.4, 0.7])
    func grain(amount: Double) throws {
        let kernel = try CIColorKernel(functionName: "grain", fromMetalLibraryData: KernelLibrary.data)
        let got = try render(kernel.apply(extent: Self.image(a).extent, arguments: [Self.image(a), Self.image(n), amount]))
        #expect(maxError(got) { i in rgb(a, i) * (1 + (n[i * 4] - 0.5) * Float(amount)) } < 1e-5)
    }

    @Test(arguments: [0.0, 0.5, 1.0])
    func denoiseCarryOver(k: Double) throws {
        let kernel = try CIColorKernel(functionName: "dn", fromMetalLibraryData: KernelLibrary.data)
        let got = try render(kernel.apply(extent: Self.image(a).extent, arguments: [Self.image(a), Self.image(b), Float(k)]))
        let err = maxError(got) { i in
            let base = rgb(a, i)
            let c = SIMD3(min(max(base.x, 0), 1), min(max(base.y, 0), 1), min(max(base.z, 0), 1))
            return base + (rgb(b, i) - c) * Float(k)
        }
        #expect(err < 1e-5)
    }

    @Test(arguments: [-1.0, -0.4, 0.5, 1.0])
    func vignette(amount: Double) throws {
        let kernel = try CIKernel(functionName: "vignette", fromMetalLibraryData: KernelLibrary.data)
        let center = CGPoint(x: 30, y: 20), radius: Float = 25
        let img = Self.image(a)
        let got = try render(kernel.apply(extent: img.extent, roiCallback: { _, r in r },
                                          arguments: [img, CIVector(x: center.x, y: center.y), radius, amount]))
        func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(max((x - e0) / (e1 - e0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        let err = maxError(got) { i in
            // Core Image's destination coordinate is the pixel centre, y up; the bitmap's first row is the top one.
            let x = Float(i % Self.w) + 0.5, y = Float(Self.h - 1 - i / Self.w) + 0.5
            let d = ((x - Float(center.x)) * (x - Float(center.x)) + (y - Float(center.y)) * (y - Float(center.y))).squareRoot() / radius
            var k = smoothstep(0.3, 1, d)
            k = k * k * (3 - 2 * k)
            let p = rgb(a, i), am = Float(amount)
            return am < 0 ? p * (1 + am * 0.95 * k) : p + (SIMD3(repeating: 1) - p) * am * 0.9 * k
        }
        #expect(err < 1e-4)
    }
}
