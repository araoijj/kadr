import Foundation

/// Ratings and labels are stored in an XMP file next to the photo (Z7D00185.ARW → Z7D00185.xmp).
/// This format is read by Capture One, Lightroom, Bridge and darktable, so culling
/// here shows up in Capture One right away. Other fields in an existing XMP are left untouched.
enum Sidecar {
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dcNS = "http://purl.org/dc/elements/1.1/"
    /// Kadr's own fields. Capture One reads a reject as xmp:Rating -1, which leaves no room for the stars,
    /// so a rejected photo's stars wait in kadr:Rating and come back when the reject is lifted.
    static let kadrNS = "http://ns.kozlov.ru/kadr/1.0/"

    static func url(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    struct Values {
        var rating = 0
        var rejected = false
        var label: ColorLabel?
        /// A label Kadr has no colour for (Capture One's Orange, Pink…), kept as read so it can be written back.
        var otherLabel: String?
    }

    /// Which properties a write touches. Rating and label are written separately: setting stars must not
    /// rewrite (and lose) a label Kadr can't show.
    struct Fields: OptionSet {
        let rawValue: Int
        static let rating = Fields(rawValue: 1)
        static let label = Fields(rawValue: 2)
    }

    /// Every XMP read-modify-write goes through this lock: AI keywords are written in the background
    /// while ratings are set on the main thread, and two unserialised writers to one file lose each other's change.
    /// Held for one file at a time, so the main thread waits a few milliseconds at most.
    private static let writer = NSLock()

    static func read(for photo: URL) -> Values {
        var v = Values()
        guard let data = try? Data(contentsOf: url(for: photo)),
              let doc = try? XMLDocument(data: data) else { return v }
        let descs = descriptions(in: doc)
        let rating = descs.lazy.compactMap { value(of: "Rating", in: $0) }.first.flatMap { Int($0) } ?? 0
        if rating < 0 {
            v.rejected = true
            let kept = descs.lazy.compactMap { value(of: "Rating", in: $0, ns: kadrNS, prefix: "kadr") }.first.flatMap { Int($0) } ?? 0
            v.rating = min(max(kept, 0), 5)
        } else {
            v.rating = min(rating, 5)
        }
        if let l = descs.lazy.compactMap({ value(of: "Label", in: $0) }).first, !l.isEmpty {
            v.label = ColorLabel.allCases.first { $0.rawValue.lowercased() == l.lowercased() }
            if v.label == nil { v.otherLabel = l }
        }
        return v
    }

    static func write(_ v: Values, _ fields: Fields, for photo: URL) throws {
        guard !fields.isEmpty else { return }
        writer.lock()
        defer { writer.unlock() }
        let file = url(for: photo)
        let doc = try packet(file)
        if fields.contains(.rating) {
            set("Rating", to: v.rejected ? "-1" : String(v.rating), in: doc)
            set("Rating", ns: kadrNS, prefix: "kadr", to: v.rejected && v.rating > 0 ? String(v.rating) : nil, in: doc)
        }
        if fields.contains(.label) { set("Label", to: v.label?.rawValue ?? v.otherLabel, in: doc) }
        let out = doc.xmlData(options: [.nodePrettyPrint])
        try out.write(to: file, options: .atomic)
    }

    /// Keywords (dc:subject), the field Capture One and Lightroom search by. Adds the missing words to the ones
    /// already there, never removes any. Returns how many were added; the file is written only if something changed.
    @discardableResult
    static func addKeywords(_ words: [String], for photo: URL) throws -> Int {
        writer.lock()
        defer { writer.unlock() }
        let file = url(for: photo)
        let doc = try packet(file)
        let descs = descriptions(in: doc)
        // The Description that already has dc:subject (a file can have several Description blocks), else the first.
        let found = descs.lazy.compactMap { d in
            d.children?.first(where: { $0.localName == "subject" && ($0 as? XMLElement)?.uri == dcNS }) as? XMLElement
        }.first
        guard let desc = (found?.parent as? XMLElement) ?? descs.first else { return 0 }
        if desc.resolveNamespace(forName: "dc:subject") == nil {
            desc.addNamespace(XMLNode.namespace(withName: "dc", stringValue: dcNS) as! XMLNode)
        }
        let subject: XMLElement
        if let found {
            subject = found
        } else {
            subject = XMLElement(name: "dc:subject", uri: dcNS)
            desc.addChild(subject)
        }
        let bag: XMLElement
        if let b = subject.children?.first(where: { ["Bag", "Seq"].contains($0.localName ?? "") }) as? XMLElement {
            bag = b
        } else {
            bag = XMLElement(name: "rdf:Bag", uri: rdfNS)
            subject.addChild(bag)
        }
        var have = Set((bag.children ?? []).compactMap { $0.stringValue?.lowercased() })
        var added = 0
        for w in words where !w.isEmpty && !have.contains(w.lowercased()) {
            let li = XMLElement(name: "rdf:li", uri: rdfNS)
            li.stringValue = w
            bag.addChild(li)
            have.insert(w.lowercased())
            added += 1
        }
        guard added > 0 else { return 0 }
        try doc.xmlData(options: [.nodePrettyPrint]).write(to: file, options: .atomic)
        return added
    }

    static func keywords(for photo: URL) -> [String] {
        guard let data = try? Data(contentsOf: url(for: photo)), let doc = try? XMLDocument(data: data) else { return [] }
        let li = (try? doc.nodes(forXPath: "//*[local-name()='subject']//*[local-name()='li']")) ?? []
        return li.compactMap(\.stringValue)
    }

    // MARK: - XML

    private static let emptyPacket = """
    <?xml version="1.0" encoding="UTF-8"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="\(rdfNS)">
        <rdf:Description rdf:about="" xmlns:xmp="\(xmpNS)"/>
      </rdf:RDF>
    </x:xmpmeta>
    """

    /// The existing XMP, or a fresh packet when there is none (or it has no Description to write into).
    private static func packet(_ file: URL) throws -> XMLDocument {
        if let data = try? Data(contentsOf: file), let existing = try? XMLDocument(data: data),
           !descriptions(in: existing).isEmpty {
            return existing
        }
        return try XMLDocument(xmlString: emptyPacket, options: [])
    }

    /// All rdf:Description blocks: Bridge and exiftool often put each namespace in a block of its own.
    private static func descriptions(in doc: XMLDocument) -> [XMLElement] {
        ((try? doc.nodes(forXPath: "//*[local-name()='Description']")) ?? []).compactMap { $0 as? XMLElement }
    }

    /// The value can be an attribute (xmp:Rating="3") or a child element (<xmp:Rating>3</xmp:Rating>).
    private static func value(of name: String, in desc: XMLElement, ns: String = xmpNS, prefix: String = "xmp") -> String? {
        if let a = desc.attributes?.first(where: { $0.localName == name && ($0.uri == ns || $0.prefix == prefix) }) {
            return a.stringValue
        }
        if let e = desc.children?.first(where: { $0.localName == name && ($0 as? XMLElement)?.uri == ns }) {
            return e.stringValue
        }
        return nil
    }

    private static func has(_ name: String, in desc: XMLElement, ns: String, prefix: String) -> Bool {
        desc.attributes?.contains { $0.localName == name && ($0.uri == ns || $0.prefix == prefix) } == true
            || desc.children?.contains { $0.localName == name && ($0 as? XMLElement)?.uri == ns } == true
    }

    /// Writes the property into the Description that already holds it (else the first one) and removes it
    /// from every other block, so the file never carries two contradicting values.
    private static func set(_ name: String, ns: String = xmpNS, prefix: String = "xmp", to value: String?, in doc: XMLDocument) {
        let descs = descriptions(in: doc)
        guard let target = descs.first(where: { has(name, in: $0, ns: ns, prefix: prefix) }) ?? descs.first else { return }
        for desc in descs {
            // Remove both forms, then write it as an attribute.
            for a in desc.attributes ?? [] where a.localName == name && (a.uri == ns || a.prefix == prefix) {
                desc.removeAttribute(forName: a.name ?? "")
            }
            for c in (desc.children ?? []).reversed() where c.localName == name && (c as? XMLElement)?.uri == ns {
                desc.removeChild(at: c.index)
            }
        }
        guard let value, !value.isEmpty else {
            // Our own namespace goes with its last property; others' declarations are left alone.
            if ns == kadrNS {
                for desc in descs where !(desc.attributes ?? []).contains(where: { $0.uri == ns || $0.prefix == prefix })
                    && !(desc.children ?? []).contains(where: { ($0 as? XMLElement)?.uri == ns }) {
                    desc.removeNamespace(forPrefix: prefix)
                }
            }
            return
        }
        if target.resolveNamespace(forName: "\(prefix):\(name)") == nil {
            target.addNamespace(XMLNode.namespace(withName: prefix, stringValue: ns) as! XMLNode)
        }
        let attr = XMLNode.attribute(withName: "\(prefix):\(name)", uri: ns, stringValue: value) as! XMLNode
        target.addAttribute(attr)
    }
}
