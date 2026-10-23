import Foundation
import Testing
@testable import Kadr

/// XMP sidecars: what Capture One and Lightroom read. Nothing Kadr doesn't own may ever be lost.
@Suite struct SidecarTests {
    let dir = TempDir()

    private func photo(_ name: String = "IMG_0001.CR3") -> URL { writeBytes(dir.url.appendingPathComponent(name)) }
    private func xmp(_ name: String = "IMG_0001.xmp") -> URL { dir.url.appendingPathComponent(name) }

    @Test func ratingRoundTripCreatesSidecar() throws {
        let p = photo()
        var v = Sidecar.Values()
        v.rating = 4
        try Sidecar.write(v, .rating, for: p)
        #expect(exists(xmp()))
        #expect(Sidecar.read(for: p).rating == 4)
        #expect(Sidecar.read(for: p).rejected == false)
    }

    @Test func starsKeepCaptureOneLabelAndForeignFields() throws {
        let p = photo()
        try xmpPacket(["""
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmp:Label="Orange" photoshop:City="Hanoi"/>
            """]).write(to: xmp(), atomically: true, encoding: .utf8)
        var v = Sidecar.read(for: p)
        #expect(v.label == nil && v.otherLabel == "Orange")
        v.rating = 3
        try Sidecar.write(v, .rating, for: p)

        let after = Sidecar.read(for: p)
        #expect(after.rating == 3)
        #expect(after.otherLabel == "Orange")
        let text = String(decoding: read(xmp()), as: UTF8.self)
        #expect(text.contains("Hanoi"))
    }

    @Test func rejectKeepsStarsAndLiftingBringsThemBack() throws {
        let p = photo()
        var v = Sidecar.Values()
        v.rating = 4
        v.rejected = true
        try Sidecar.write(v, .rating, for: p)
        let text = String(decoding: read(xmp()), as: UTF8.self)
        #expect(text.contains("xmp:Rating=\"-1\""))   // what Capture One reads as a reject

        let rejected = Sidecar.read(for: p)
        #expect(rejected.rejected && rejected.rating == 4)

        var lifted = rejected
        lifted.rejected = false
        try Sidecar.write(lifted, .rating, for: p)
        let back = Sidecar.read(for: p)
        #expect(!back.rejected && back.rating == 4)
        #expect(!String(decoding: read(xmp()), as: UTF8.self).contains("kadr:Rating"))
    }

    @Test func unreadableSidecarIsNeverOverwritten() throws {
        let p = photo()
        let broken = Data("<x:xmpmeta><rdf:RDF><rdf:Description xmp:Rating=\"5\"".utf8)
        try broken.write(to: xmp())
        var v = Sidecar.Values()
        v.rating = 1
        #expect(throws: (any Error).self) { try Sidecar.write(v, .rating, for: p) }
        #expect(throws: (any Error).self) { try Sidecar.addKeywords(["sea"], for: p) }
        #expect(read(xmp()) == broken)
    }

    @Test func emptySidecarIsFilledIn() throws {
        let p = photo()
        try Data("  \n".utf8).write(to: xmp())
        var v = Sidecar.Values()
        v.rating = 2
        try Sidecar.write(v, .rating, for: p)
        #expect(Sidecar.read(for: p).rating == 2)
    }

    @Test func fullNameSidecarIsReadAndWrittenInPlace() throws {
        let p = photo()
        let full = xmp("IMG_0001.CR3.xmp")
        try xmpPacket(["<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"2\"/>"])
            .write(to: full, atomically: true, encoding: .utf8)
        #expect(Sidecar.url(for: p) == full)
        #expect(Sidecar.read(for: p).rating == 2)

        var v = Sidecar.read(for: p)
        v.rating = 5
        try Sidecar.write(v, .rating, for: p)
        #expect(Sidecar.read(for: p).rating == 5)
        #expect(!exists(xmp()))   // no second sidecar next to it
    }

    @Test func plainSidecarWinsOverFullName() throws {
        let p = photo()
        try xmpPacket(["<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"1\"/>"])
            .write(to: xmp(), atomically: true, encoding: .utf8)
        try xmpPacket(["<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"5\"/>"])
            .write(to: xmp("IMG_0001.CR3.xmp"), atomically: true, encoding: .utf8)
        #expect(Sidecar.read(for: p).rating == 1)
    }

    @Test func severalDescriptionsNeverGetTwoRatings() throws {
        let p = photo()
        // Bridge and exiftool put each namespace in a block of its own; the rating is in the second one.
        try xmpPacket([
            "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:format>image/x-canon-cr3</dc:format></rdf:Description>",
            "<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><xmp:Rating>2</xmp:Rating></rdf:Description>",
        ]).write(to: xmp(), atomically: true, encoding: .utf8)
        #expect(Sidecar.read(for: p).rating == 2)

        var v = Sidecar.read(for: p)
        v.rating = 5
        try Sidecar.write(v, .rating, for: p)
        let text = String(decoding: read(xmp()), as: UTF8.self)
        #expect(text.components(separatedBy: "Rating").count - 1 == 1)
        #expect(Sidecar.read(for: p).rating == 5)
        #expect(text.contains("image/x-canon-cr3"))
    }

    @Test func labelIsWrittenWithoutTouchingStars() throws {
        let p = photo()
        var v = Sidecar.Values()
        v.rating = 3
        try Sidecar.write(v, .rating, for: p)
        v.rating = 0   // a stale value must not leak in: only the label is written
        v.label = .green
        try Sidecar.write(v, .label, for: p)
        let after = Sidecar.read(for: p)
        #expect(after.rating == 3 && after.label == .green)
    }

    @Test func keywordsAreAddedNeverRemovedOrDoubled() throws {
        let p = photo()
        try xmpPacket(["""
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:subject><rdf:Bag><rdf:li>Wedding</rdf:li></rdf:Bag></dc:subject>
            </rdf:Description>
            """]).write(to: xmp(), atomically: true, encoding: .utf8)
        #expect(try Sidecar.addKeywords(["wedding", "sea", "sky"], for: p) == 2)
        #expect(try Sidecar.addKeywords(["SEA"], for: p) == 0)
        #expect(Sidecar.keywords(for: p) == ["Wedding", "sea", "sky"])
    }

    /// AI keywords are written in the background while stars are set on the main thread: both must survive.
    @Test func concurrentRatingAndKeywordWritesLoseNothing() throws {
        let p = photo()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            if i.isMultiple(of: 2) {
                var v = Sidecar.Values()
                v.rating = 4
                try? Sidecar.write(v, .rating, for: p)
            } else {
                _ = try? Sidecar.addKeywords(["tag\(i)"], for: p)
            }
        }
        #expect(Sidecar.read(for: p).rating == 4)
        #expect(Set(Sidecar.keywords(for: p)) == Set((0..<40).filter { !$0.isMultiple(of: 2) }.map { "tag\($0)" }))
    }
}
