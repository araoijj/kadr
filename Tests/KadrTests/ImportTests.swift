import Foundation
import Testing
@testable import Kadr

/// Memory card import: every frame arrives whole and verified, nothing is skipped by mistake or overwritten.
@Suite struct ImportTests {
    let tmp = TempDir()

    /// One frame on the card: its photos (by extension) and optional XMP files, as `listFiles` would find them.
    private func frame(on card: URL, _ base: String, exts: [String], xmp: [String] = [], seed: UInt8 = 1) -> [CardFile] {
        let sidecars = xmp.map { writeBytes(card.appendingPathComponent($0), size: 300, seed: seed) }
        return exts.map { ext in
            let u = writeBytes(card.appendingPathComponent("\(base).\(ext)"), size: 8192, seed: seed &+ UInt8(ext.count))
            return CardFile(url: u, size: 8192, date: Date(timeIntervalSince1970: 1_700_000_000), sidecars: sidecars)
        }
    }

    @Test func frameIsCopiedWithItsSidecarAndVerified() {
        let card = tmp.sub("card/DCIM/100CANON"), shoot = tmp.sub("shoot")
        let group = frame(on: card, "IMG_0001", exts: ["CR3", "JPG"], xmp: ["IMG_0001.xmp"])
        let (outcomes, sidecarsOK) = CardImporter.copy(group, to: shoot)
        #expect(outcomes.map { "\($0)" } == ["copied", "copied"])
        #expect(sidecarsOK)
        #expect(names(in: shoot) == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp"])
        for f in group { #expect(read(shoot.appendingPathComponent(f.url.lastPathComponent)) == read(f.url)) }
    }

    @Test func secondImportSkipsWhatIsAlreadyThere() {
        let card = tmp.sub("card"), shoot = tmp.sub("shoot")
        let group = frame(on: card, "IMG_0001", exts: ["CR3"], xmp: ["IMG_0001.xmp"])
        _ = CardImporter.copy(group, to: shoot)
        let (again, ok) = CardImporter.copy(group, to: shoot)
        #expect(again.map { "\($0)" } == ["exists"])
        #expect(ok)
        #expect(names(in: shoot) == ["IMG_0001.CR3", "IMG_0001.xmp"])
    }

    /// Same frame number, same size, another shot (second card or camera): imported under a new suffix,
    /// the photo already in the shoot stays as it was.
    @Test func sameNameAndSizeButOtherShotIsNotSkipped() {
        let card = tmp.sub("card"), shoot = tmp.sub("shoot")
        let earlier = writeBytes(shoot.appendingPathComponent("IMG_0001.CR3"), size: 8192, seed: 99)
        let before = read(earlier)
        let group = frame(on: card, "IMG_0001", exts: ["CR3", "JPG"], xmp: ["IMG_0001.xmp"])
        let (outcomes, ok) = CardImporter.copy(group, to: shoot)
        #expect(outcomes.map { "\($0)" } == ["copied", "copied"])
        #expect(ok)
        #expect(read(earlier) == before)
        // The whole frame shares one suffix: RAW, JPEG and XMP stay a set.
        #expect(names(in: shoot) == ["IMG_0001-2.CR3", "IMG_0001-2.JPG", "IMG_0001-2.xmp", "IMG_0001.CR3"])
    }

    /// The frame's photos are new but an XMP of its name is there (its photo was deleted): the frame must not
    /// pick up that stale rating, so it takes the next suffix and the orphan is left alone.
    @Test func orphanSidecarIsNotAdopted() {
        let card = tmp.sub("card"), shoot = tmp.sub("shoot")
        let orphan = writeBytes(shoot.appendingPathComponent("IMG_0001.xmp"), size: 120, seed: 5)
        let before = read(orphan)
        let group = frame(on: card, "IMG_0001", exts: ["CR3"])
        _ = CardImporter.copy(group, to: shoot)
        #expect(names(in: shoot) == ["IMG_0001-2.CR3", "IMG_0001.xmp"])
        #expect(read(orphan) == before)
    }

    /// A card's IMG_0001.CR3.xmp is stored as IMG_0001.xmp, the name Kadr and Capture One read.
    @Test func fullNameSidecarFromCardIsStoredUnderPlainName() {
        let card = tmp.sub("card"), shoot = tmp.sub("shoot")
        let group = frame(on: card, "IMG_0001", exts: ["CR3"], xmp: ["IMG_0001.CR3.xmp"])
        _ = CardImporter.copy(group, to: shoot)
        #expect(names(in: shoot) == ["IMG_0001.CR3", "IMG_0001.xmp"])
    }

    @Test func scanPairsSidecarsWithPhotosAndListsOnlyPhotos() {
        let card = tmp.sub("card/DCIM/100CANON")
        writeBytes(card.appendingPathComponent("IMG_0001.CR3"))
        writeBytes(card.appendingPathComponent("IMG_0001.JPG"))
        writeBytes(card.appendingPathComponent("IMG_0001.xmp"), size: 200)
        writeBytes(card.appendingPathComponent("IMG_0002.ARW"))
        writeBytes(card.appendingPathComponent("notes.txt"))
        let found = CardImporter.listFiles(tmp.url.appendingPathComponent("card"))
        #expect(found.map(\.url.lastPathComponent).sorted() == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.ARW"])
        for f in found {
            let expected = f.url.lastPathComponent.hasPrefix("IMG_0001") ? ["IMG_0001.xmp"] : []
            #expect(f.sidecars.map(\.lastPathComponent) == expected)
        }
    }

    /// Equal size, a difference only in the middle of the file (sensor data): still a different shot.
    @Test func contentCheckSeesDifferenceInTheMiddle() throws {
        let size = 5 << 20
        var bytes = [UInt8](repeating: 7, count: size)
        let a = tmp.url.appendingPathComponent("a.CR3"), b = tmp.url.appendingPathComponent("b.CR3")
        try Data(bytes).write(to: a)
        try Data(bytes).write(to: b)
        #expect(CardImporter.sameContent(a, b, size: Int64(size)))
        bytes[size / 2] = 8
        try Data(bytes).write(to: b)
        #expect(!CardImporter.sameContent(a, b, size: Int64(size)))
    }

    @Test func baseNamesAndSuffixesKeepFrameTogether() {
        #expect(CardImporter.baseName(URL(fileURLWithPath: "/c/IMG_0001.CR3.xmp")) == "IMG_0001")
        #expect(CardImporter.baseName(URL(fileURLWithPath: "/c/IMG_0001.xmp")) == "IMG_0001")
        #expect(CardImporter.name(URL(fileURLWithPath: "/c/IMG_0001.CR3.xmp"), suffix: "-2") == "IMG_0001-2.CR3.xmp")
        #expect(CardImporter.groupKey(URL(fileURLWithPath: "/c/IMG_0001.JPG"))
                == CardImporter.groupKey(URL(fileURLWithPath: "/c/img_0001.cr3")))
    }
}
