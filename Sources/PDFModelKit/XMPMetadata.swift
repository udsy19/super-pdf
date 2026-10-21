import Foundation

// The document's XMP packet kept in step with /Info (ISO 32000-2 §14.3.2, XMP Part 1): when Title, Author, Subject,
// Keywords or Creator change, dc:title, dc:creator, dc:description, pdf:Keywords and xmp:CreatorTool follow, and
// xmp:ModifyDate (and xmp:MetadataDate when the packet has one) take the modification date, as /Info's /ModDate does,
// so the two agree (PDF/A requires it). Everything else in the packet stays as it was. Only an existing packet is
// changed; a file without one doesn't get one.

extension PDFModel {
    /// Writes the current /Info values of `keys` ("Title", "Author", "Subject", "Keywords", "Creator") into the
    /// catalog's XMP packet, with `modified` as its modification date there and in /Info. A key /Info no longer has
    /// removes its property. Returns false (and changes nothing) when there is no packet or it can't be read as UTF-8 RDF.
    @discardableResult
    public func updateXMP(forInfo keys: Set<String>, modified: Date) -> Bool {
        guard let stream = root["Metadata"], stream.type == .stream, let data = try? stream.streamData(decode: .all),
              var packet = XMPPacket(data) else { return false }
        for key in keys.sorted() {
            guard let property = XMPPacket.infoProperties[key] else { continue }
            let value = info(key).flatMap { $0.isEmpty ? nil : $0 }
            packet.set(property, value)
        }
        let date = XMPPacket.dateString(modified)
        packet.set(XMPPacket.modifyDate, date)
        if packet.has(XMPPacket.metadataDate) { packet.set(XMPPacket.metadataDate, date) }
        stream.setStreamData(Data(packet.xml.utf8))
        setInfo("ModDate", PDFDate.string(modified))
        return true
    }
}

/// An XMP packet as text, changed property by property with everything around it left alone.
struct XMPPacket {
    enum Form { case text, langAlt, seq }

    struct Property {
        var namespace: String
        var prefix: String
        var name: String
        var form: Form
    }

    static let dc = "http://purl.org/dc/elements/1.1/", xmp = "http://ns.adobe.com/xap/1.0/", pdf = "http://ns.adobe.com/pdf/1.3/"
    static let infoProperties: [String: Property] = [
        "Title": Property(namespace: dc, prefix: "dc", name: "title", form: .langAlt),
        "Author": Property(namespace: dc, prefix: "dc", name: "creator", form: .seq),
        "Subject": Property(namespace: dc, prefix: "dc", name: "description", form: .langAlt),
        "Keywords": Property(namespace: pdf, prefix: "pdf", name: "Keywords", form: .text),
        "Creator": Property(namespace: xmp, prefix: "xmp", name: "CreatorTool", form: .text),
    ]
    static let modifyDate = Property(namespace: xmp, prefix: "xmp", name: "ModifyDate", form: .text)
    static let metadataDate = Property(namespace: xmp, prefix: "xmp", name: "MetadataDate", form: .text)

    private(set) var xml: String

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), text.contains("</rdf:RDF>") else { return nil }
        xml = text
    }

    static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Finding a property

    /// The prefix the packet binds to `namespace` (nil when it declares none).
    private func declaredPrefix(_ namespace: String) -> String? {
        let pattern = "xmlns:([A-Za-z_][A-Za-z0-9_.-]*)\\s*=\\s*[\"']" + NSRegularExpression.escapedPattern(for: namespace) + "[\"']"
        return firstMatch(pattern)?.groups[1].map { String(xml[$0]) }
    }

    private func firstMatch(_ pattern: String, in range: Range<String.Index>? = nil) -> (range: Range<String.Index>, groups: [Range<String.Index>?])? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let searched = range.map { NSRange($0, in: xml) } ?? NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: searched), let whole = Range(match.range, in: xml) else { return nil }
        return (whole, (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: xml) })
    }

    /// The element form (`<p:name …>…</p:name>` or `<p:name …/>`) and the attribute form (`p:name="…"`) of a property.
    private func elementPattern(_ qualified: String) -> String {
        let q = NSRegularExpression.escapedPattern(for: qualified)
        return "<\(q)(?:\\s[^>]*?)?(?:/>|>[\\s\\S]*?</\(q)\\s*>)"
    }

    private func attributePattern(_ qualified: String) -> String {
        "\\s" + NSRegularExpression.escapedPattern(for: qualified) + "\\s*=\\s*(?:\"[^\"]*\"|'[^']*')"
    }

    func has(_ property: Property) -> Bool {
        guard let prefix = declaredPrefix(property.namespace) else { return false }
        let qualified = prefix + ":" + property.name
        return firstMatch(elementPattern(qualified)) != nil || firstMatch(attributePattern(qualified)) != nil
    }

    // MARK: Changing a property

    /// Sets `property` to `value` (nil removes it): in place of its first occurrence, in the description that declares
    /// its namespace otherwise, or in a new description. Other occurrences go.
    mutating func set(_ property: Property, _ value: String?) {
        let declared = declaredPrefix(property.namespace)
        let qualified = (declared ?? property.prefix) + ":" + property.name
        if declared != nil {
            let element = firstMatch(elementPattern(qualified)), attribute = firstMatch(attributePattern(qualified))
            var replacement: String?
            var first: Range<String.Index>?
            if let element, attribute.map({ element.range.lowerBound < $0.range.lowerBound }) ?? true {
                first = element.range
                replacement = value.map { self.element(qualified, $0, form: property.form, replacing: String(xml[element.range])) }
            } else if let attribute {
                first = attribute.range
                if property.form == .text { replacement = value.map { " \(qualified)=\"\(Self.escape($0, attribute: true))\"" } }
            }
            if let first, let replacement {
                let marker = "\u{1}XMP\u{1}"
                xml.replaceSubrange(first, with: marker)
                removeAll(elementPattern(qualified))
                removeAll(attributePattern(qualified))
                xml = xml.replacingOccurrences(of: marker, with: replacement)
                return
            }
            removeAll(elementPattern(qualified))
            removeAll(attributePattern(qualified))
        }
        guard let value else { return }
        insert(element(qualified, value, form: property.form, replacing: nil), namespace: property.namespace,
               prefix: declared ?? property.prefix, declared: declared != nil)
    }

    private mutating func removeAll(_ pattern: String) {
        while let match = firstMatch(pattern) { xml.removeSubrange(match.range) }
    }

    /// The property's element. A language alternative replaced in place keeps its other languages and changes the
    /// default one.
    private func element(_ qualified: String, _ value: String, form: Form, replacing old: String?) -> String {
        let text = Self.escape(value, attribute: false)
        switch form {
        case .text:
            return "<\(qualified)>\(text)</\(qualified)>"
        case .seq:
            return "<\(qualified)><rdf:Seq><rdf:li>\(text)</rdf:li></rdf:Seq></\(qualified)>"
        case .langAlt:
            let fresh = "<\(qualified)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(text)</rdf:li></rdf:Alt></\(qualified)>"
            guard let old, let regex = try? NSRegularExpression(pattern: "(<rdf:li\\s[^>]*xml:lang\\s*=\\s*[\"']x-default[\"'][^>]*>)[\\s\\S]*?(</rdf:li>)"),
                  regex.firstMatch(in: old, range: NSRange(old.startIndex..., in: old)) != nil else { return fresh }
            let template = "$1" + NSRegularExpression.escapedTemplate(for: text) + "$2"
            return regex.stringByReplacingMatches(in: old, range: NSRange(old.startIndex..., in: old), withTemplate: template)
        }
    }

    /// Puts `element` at the end of the description that declares `prefix`, or of a new description.
    private mutating func insert(_ element: String, namespace: String, prefix: String, declared: Bool) {
        if declared, let open = firstMatch("<rdf:Description\\s[^>]*xmlns:" + NSRegularExpression.escapedPattern(for: prefix) + "\\s*=[^>]*?(/?)>") {
            if let slash = open.groups[1], !slash.isEmpty {
                // `<rdf:Description … />`: open it up.
                let tag = String(xml[open.range.lowerBound..<slash.lowerBound])
                xml.replaceSubrange(open.range, with: tag + ">" + element + "</rdf:Description>")
                return
            }
            if let close = xml.range(of: "</rdf:Description>", range: open.range.upperBound..<xml.endIndex) {
                xml.insert(contentsOf: element, at: close.lowerBound)
                return
            }
        }
        let about = firstMatch("rdf:about\\s*=\\s*[\"']([^\"']*)[\"']").flatMap { $0.groups[1] }.map { String(xml[$0]) } ?? ""
        let description = "<rdf:Description rdf:about=\"\(Self.escape(about, attribute: true))\" xmlns:\(prefix)=\"\(namespace)\">\(element)</rdf:Description>"
        if let close = xml.range(of: "</rdf:RDF>", options: .backwards) { xml.insert(contentsOf: description, at: close.lowerBound) }
    }

    static func escape(_ text: String, attribute: Bool) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if attribute { result = result.replacingOccurrences(of: "\"", with: "&quot;") }
        return result
    }
}
