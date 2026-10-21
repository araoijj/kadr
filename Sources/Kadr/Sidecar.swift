import Foundation

/// Ratings and labels are stored in an XMP file next to the photo (Z7D00185.ARW → Z7D00185.xmp).
/// This format is read by Capture One, Lightroom, Bridge and darktable, so culling
/// here shows up in Capture One right away. Other fields in an existing XMP are left untouched.
enum Sidecar {
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let dcNS = "http://purl.org/dc/elements/1.1/"

    static func url(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    struct Values {
        var rating = 0
        var rejected = false
        var label: ColorLabel?
    }

    static func read(for photo: URL) -> Values {
        var v = Values()
        guard let data = try? Data(contentsOf: url(for: photo)),
              let doc = try? XMLDocument(data: data),
              let desc = description(in: doc) else { return v }
        let rating = value(of: "Rating", in: desc).flatMap { Int($0) } ?? 0
        if rating < 0 { v.rejected = true } else { v.rating = min(rating, 5) }
        if let l = value(of: "Label", in: desc) {
            v.label = ColorLabel.allCases.first { $0.rawValue.lowercased() == l.lowercased() }
        }
        return v
    }

    static func write(_ v: Values, for photo: URL) throws {
        let file = url(for: photo)
        let doc: XMLDocument
        if let data = try? Data(contentsOf: file), let existing = try? XMLDocument(data: data),
           description(in: existing) != nil {
            doc = existing
        } else {
            doc = try XMLDocument(xmlString: emptyPacket, options: [])
        }
        guard let desc = description(in: doc) else { return }
        if desc.resolveNamespace(forName: "xmp:Rating") == nil {
            desc.addNamespace(XMLNode.namespace(withName: "xmp", stringValue: xmpNS) as! XMLNode)
        }
        set("Rating", to: v.rejected ? "-1" : String(v.rating), in: desc)
        set("Label", to: v.label?.rawValue, in: desc)
        let out = doc.xmlData(options: [.nodePrettyPrint])
        try out.write(to: file, options: .atomic)
    }

    /// Keywords (dc:subject), the field Capture One and Lightroom search by. Adds the missing words to the ones
    /// already there, never removes any. Returns how many were added; the file is written only if something changed.
    @discardableResult
    static func addKeywords(_ words: [String], for photo: URL) throws -> Int {
        let file = url(for: photo)
        let doc: XMLDocument
        if let data = try? Data(contentsOf: file), let existing = try? XMLDocument(data: data),
           description(in: existing) != nil {
            doc = existing
        } else {
            doc = try XMLDocument(xmlString: emptyPacket, options: [])
        }
        guard let desc = description(in: doc) else { return 0 }
        if desc.resolveNamespace(forName: "dc:subject") == nil {
            desc.addNamespace(XMLNode.namespace(withName: "dc", stringValue: dcNS) as! XMLNode)
        }
        let subject: XMLElement
        if let s = desc.children?.first(where: { $0.localName == "subject" && ($0 as? XMLElement)?.uri == dcNS }) as? XMLElement {
            subject = s
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

    private static func description(in doc: XMLDocument) -> XMLElement? {
        (try? doc.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement
    }

    /// The value can be an attribute (xmp:Rating="3") or a child element (<xmp:Rating>3</xmp:Rating>).
    private static func value(of name: String, in desc: XMLElement) -> String? {
        if let a = desc.attributes?.first(where: { $0.localName == name && ($0.uri == xmpNS || $0.prefix == "xmp") }) {
            return a.stringValue
        }
        if let e = desc.children?.first(where: { $0.localName == name && ($0 as? XMLElement)?.uri == xmpNS }) {
            return e.stringValue
        }
        return nil
    }

    private static func set(_ name: String, to value: String?, in desc: XMLElement) {
        // Remove both forms, then write it as an attribute.
        for a in desc.attributes ?? [] where a.localName == name && (a.uri == xmpNS || a.prefix == "xmp") {
            desc.removeAttribute(forName: a.name ?? "")
        }
        for c in (desc.children ?? []).reversed() where c.localName == name && (c as? XMLElement)?.uri == xmpNS {
            desc.removeChild(at: c.index)
        }
        guard let value, !value.isEmpty else { return }
        let attr = XMLNode.attribute(withName: "xmp:\(name)", uri: xmpNS, stringValue: value) as! XMLNode
        desc.addAttribute(attr)
    }
}
