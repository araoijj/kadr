import Foundation
import ImageIO
import Testing
@testable import Kadr

/// Saving to a folder: exact sizes, culling carried into the JPEG, and nothing ever overwritten.
@Suite struct ExportTests {
    let tmp = TempDir()

    private func item(_ url: URL, _ adj: Adjustments = .none, index: Int = 1) -> ExportItem {
        ExportItem(url: url, adj: adj, date: nil, index: index)
    }

    private func jpegSettings(longSide: Int = 0) -> ExportSettings {
        var s = ExportSettings()
        s.format = .jpeg
        s.longSide = longSide
        return s
    }

    // MARK: Names

    /// IMG_1 is taken, so it becomes a suffixed name — but never IMG_1-2, which is a real frame of the shoot.
    @Test func suffixNeverTakesAnotherPhotosName() {
        let out = tmp.sub("out")
        writeBytes(out.appendingPathComponent("IMG_1.jpg"))
        let items = [item(URL(fileURLWithPath: "/shoot/IMG_1.CR3"), index: 1), item(URL(fileURLWithPath: "/shoot/IMG_1-2.CR3"), index: 2)]
        let jobs = Exporter.plan(items, to: out, jpegSettings(), shootName: "shoot")
        #expect(jobs.map(\.base) == ["IMG_1-3", "IMG_1-2"])
    }

    @Test func sameNamesFromSubfoldersGetDistinctNames() {
        let out = tmp.sub("out")
        let items = [item(URL(fileURLWithPath: "/shoot/a/IMG_1.CR3")), item(URL(fileURLWithPath: "/shoot/b/IMG_1.CR3"))]
        let jobs = Exporter.plan(items, to: out, jpegSettings(), shootName: "shoot")
        #expect(Set(jobs.compactMap(\.base)).count == 2)
    }

    /// An original already in the folder (same size) is skipped whole instead of duplicated.
    @Test func originalAlreadyThereIsSkipped() {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let raw = writeBytes(shoot.appendingPathComponent("IMG_1.CR3"))
        writeBytes(out.appendingPathComponent("IMG_1.CR3"))
        var s = ExportSettings()
        s.format = .original
        let jobs = Exporter.plan([item(raw)], to: out, s, shootName: nil)
        #expect(jobs.first?.base == nil)
    }

    // MARK: Originals

    @Test func originalTravelsWithItsSidecarAndTwin() {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let raw = writeBytes(shoot.appendingPathComponent("IMG_1.CR3"))
        writeBytes(shoot.appendingPathComponent("IMG_1.xmp"), size: 200)
        writeBytes(shoot.appendingPathComponent("IMG_1.JPG"))
        var s = ExportSettings()
        s.format = .original
        s.move = true
        let job = Exporter.plan([item(raw)], to: out, s, shootName: nil)[0]
        let result = Exporter.export(job, to: out, s)
        #expect(result.ok && result.errors.isEmpty)
        #expect(names(in: out) == ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"])
        #expect(names(in: shoot).isEmpty)
        #expect(result.moved?.to == out.appendingPathComponent("IMG_1.CR3"))
    }

    /// When one file of the set can't go, the ones already moved come back: a RAW never sits without its XMP.
    @Test func failedSetIsRolledBack() {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let raw = writeBytes(shoot.appendingPathComponent("IMG_1.CR3"))
        writeBytes(shoot.appendingPathComponent("IMG_1.xmp"), size: 200)
        writeBytes(out.appendingPathComponent("IMG_1.xmp"), size: 50, seed: 9)   // blocks the XMP's move
        let (target, errors) = Exporter.transfer(Exporter.existingCompanions(of: raw), of: raw, base: "IMG_1", to: out, move: true)
        #expect(target == nil)
        #expect(!errors.isEmpty)
        #expect(names(in: shoot) == ["IMG_1.CR3", "IMG_1.xmp"])
        #expect(names(in: out) == ["IMG_1.xmp"])
        #expect(read(out.appendingPathComponent("IMG_1.xmp")).count == 50)
    }

    // MARK: JPEG

    /// 3000×2000 cropped to its middle half (1500×1000) and saved at 1200 px: exactly 1200×800,
    /// with the JPEG's own size in its Exif, not the source's.
    @Test func croppedJPEGHasExactlyTheRequestedSize() throws {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let src = writeJPEG(shoot.appendingPathComponent("IMG_1.jpg"), width: 3000, height: 2000)
        var adj = Adjustments()
        adj.cropX = 0.25; adj.cropY = 0.25; adj.cropW = 0.5; adj.cropH = 0.5
        let s = jpegSettings(longSide: 1200)
        let job = Exporter.plan([item(src, adj)], to: out, s, shootName: nil)[0]
        #expect(Exporter.export(job, to: out, s).ok)

        let result = out.appendingPathComponent("IMG_1.jpg")
        let size = try #require(pixelSize(result))
        #expect(size == (1200, 800))
        let props = try #require(CGImageSourceCreateWithURL(result as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifPixelXDimension] as? Int == 1200)
    }

    @Test func smallerSourceIsNeverEnlarged() throws {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let src = writeJPEG(shoot.appendingPathComponent("IMG_1.jpg"), width: 900, height: 600)
        let s = jpegSettings(longSide: 2560)
        let job = Exporter.plan([item(src)], to: out, s, shootName: nil)[0]
        #expect(Exporter.export(job, to: out, s).ok)
        #expect(try #require(pixelSize(out.appendingPathComponent("IMG_1.jpg"))) == (900, 600))
    }

    /// Stars, label and keywords go into the exported JPEG, so Lightroom and Photos see the culling.
    @Test func cullingIsCarriedIntoTheJPEG() throws {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let src = writeJPEG(shoot.appendingPathComponent("IMG_1.jpg"), width: 800, height: 600)
        var v = Sidecar.Values()
        v.rating = 4
        v.label = .red
        try Sidecar.write(v, [.rating, .label], for: src)
        try Sidecar.addKeywords(["sea", "sky"], for: src)

        let s = jpegSettings()
        let job = Exporter.plan([item(src)], to: out, s, shootName: nil)[0]
        #expect(Exporter.export(job, to: out, s).ok)

        let meta = try #require(CGImageSourceCreateWithURL(out.appendingPathComponent("IMG_1.jpg") as CFURL, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        #expect(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String? == "4")
        #expect(CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Label" as CFString) as String? == "Red")
        let words = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString)
            .flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }?
            .compactMap { CGImageMetadataTagCopyValue($0) as? String } ?? []
        #expect(Set(words) == ["sea", "sky"])
    }

    /// A file that appeared under the planned name is kept; the JPEG takes the next free name.
    @Test func jpegNeverOverwritesAFileThatAppeared() throws {
        let shoot = tmp.sub("shoot"), out = tmp.sub("out")
        let src = writeJPEG(shoot.appendingPathComponent("IMG_1.jpg"), width: 400, height: 300)
        let s = jpegSettings()
        let job = Exporter.plan([item(src)], to: out, s, shootName: nil)[0]
        let intruder = writeBytes(out.appendingPathComponent("IMG_1.jpg"), size: 77)
        #expect(Exporter.export(job, to: out, s).ok)
        #expect(read(intruder).count == 77)
        #expect(names(in: out) == ["IMG_1-2.jpg", "IMG_1.jpg"])
        #expect(try #require(pixelSize(out.appendingPathComponent("IMG_1-2.jpg"))) == (400, 300))
    }

    /// Leftovers of a crashed save are removed: only our own pattern, only when older than an hour.
    @Test func onlyStaleTempFilesOfOurOwnAreRemoved() throws {
        let out = tmp.sub("out")
        let old = Date().addingTimeInterval(-7200)
        let stale = writeBytes(out.appendingPathComponent(".IMG_1-\(UUID().uuidString).kadr-tmp"))
        let fresh = writeBytes(out.appendingPathComponent(".IMG_2-\(UUID().uuidString).kadr-tmp"))
        let foreign = writeBytes(out.appendingPathComponent("notes.kadr-tmp"))
        for f in [stale, foreign] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path) }
        Exporter.removeStaleTemps(in: out)
        #expect(!exists(stale))
        #expect(exists(fresh) && exists(foreign))
    }

    // MARK: Presets

    @Test func presetsGiveTheirExactSizes() {
        var s = ExportSettings()
        s.preset = .story
        s.presetCrop = true
        let story = ExportPlan.make(aspect: 3.0 / 2, userCropped: false, s)
        #expect(story?.width == 1080 && story?.height == 1920 && story?.crop == ExportPlan.story)

        s.preset = .instagram
        let tall = ExportPlan.make(aspect: 2.0 / 3, userCropped: false, s)
        #expect(tall?.width == 1080 && tall?.height == 1350 && tall?.crop == ExportPlan.igMin)
        let square = ExportPlan.make(aspect: 1, userCropped: true, s)
        #expect(square?.width == 1080 && square?.height == 1080 && square?.crop == nil)
    }

    @Test func longSideKeepsTheShapeAndNeverEnlarges() {
        var s = ExportSettings()
        s.longSide = 2560
        #expect(Exporter.outputSize(CGSize(width: 6000, height: 4000), userCropped: false, s) == CGSize(width: 2560, height: 1707))
        #expect(Exporter.outputSize(CGSize(width: 1000, height: 800), userCropped: false, s) == CGSize(width: 1000, height: 800))
    }
}
