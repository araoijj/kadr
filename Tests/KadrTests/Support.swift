import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A throwaway folder under the system temp directory, removed when the test is done.
/// Tests never touch real shoots, the app's support folder or its settings.
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("KadrTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func sub(_ path: String) -> URL {
        let u = url.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// A fake photo: `size` bytes that differ by `seed`, so two files of one size are still different shots.
@discardableResult
func writeBytes(_ url: URL, size: Int = 4096, seed: UInt8 = 1) -> URL {
    var bytes = [UInt8](repeating: 0, count: size)
    for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed) &* 7) }
    try! Data(bytes).write(to: url)
    return url
}

func read(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func names(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

/// An XMP packet with the given Description bodies (attributes and children are written as given).
func xmpPacket(_ descriptions: [String]) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    \(descriptions.joined(separator: "\n"))
      </rdf:RDF>
    </x:xmpmeta>
    """
}

/// A real JPEG of `width`×`height` with a gradient, so Core Image can develop and resize it.
@discardableResult
func writeJPEG(_ url: URL, width: Int, height: Int) -> URL {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let colors = [CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1), CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)] as CFArray
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
    return url
}

/// Pixel size of an image file.
func pixelSize(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}
