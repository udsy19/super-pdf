import Foundation
import PDFModelKit
import SuperPDFCore

/// Mail messages (.eml) → PDF (features §3.2): the headers (From, To, Cc, Date, Subject), the body (HTML with WebKit,
/// else the plain text) with its inline pictures, then attached pictures and PDFs as pages; other attachments ride
/// along as file attachments of the PDF.
enum MailImporter {
    @MainActor
    static func convert(_ input: URL, to output: URL, options: ImportOptions) async throws -> ImportReport {
        let folder = output.deletingLastPathComponent().appendingPathComponent("mail-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let message = try MIMEPart.parse(try Data(contentsOf: input))

        // Inline parts (cid:) and attachments, saved under safe names.
        var html: String?
        var plain: String?
        var inline: [String: String] = [:]
        var attachments: [(name: String, file: URL, type: String)] = []
        for part in message.leaves() {
            let type = part.contentType
            if part.isAttachment || (!type.hasPrefix("text/") && !type.hasPrefix("multipart/")) {
                let name = part.fileName ?? "attachment-\(attachments.count + 1)"
                let safe = "\(attachments.count + inline.count)-" + name.replacingOccurrences(of: "/", with: "-")
                let file = folder.appendingPathComponent(safe)
                try part.decodedBody.write(to: file)
                if let id = part.contentID, !part.isAttachment { inline[id] = safe } else { attachments.append((name, file, type)) }
            } else if type == "text/html", html == nil {
                html = part.text
            } else if type == "text/plain", plain == nil {
                plain = part.text
            }
        }

        var body: String
        if var html {
            for (id, name) in inline { html = html.replacingOccurrences(of: "cid:" + id, with: name) }
            body = html
            // The message's own document: put the headers at the start of its body.
            if let range = body.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                body.insert(contentsOf: headerTable(message), at: range.upperBound)
            } else {
                body = HTMLPage.document(title: message.subject ?? String.baseName(input), body: headerTable(message) + body)
            }
        } else {
            let text = XML.escape(plain ?? "").replacingOccurrences(of: #"(https?://[^\s<]+)"#, with: "<a href=\"$1\">$1</a>", options: .regularExpression)
            body = HTMLPage.document(title: message.subject ?? String.baseName(input),
                                     body: headerTable(message) + "<div style=\"white-space: pre-wrap\">\(text)</div>")
        }
        let page = folder.appendingPathComponent("message.html")
        // The text is UTF-8 now, whatever the message declared: say so first (the first declaration wins).
        try ("<meta charset=\"utf-8\">" + body).write(to: page, atomically: true, encoding: .utf8)
        let messagePDF = folder.appendingPathComponent("message.pdf")
        try await WebRenderer.render(file: page, paper: options.textPaper, margins: CGFloat(options.margins), to: messagePDF,
                                     title: message.subject ?? String.baseName(input))

        // Pictures and PDFs become pages; everything else is attached to the PDF.
        var parts = [PDFAssembler.Part(url: messagePDF, title: message.subject ?? String.baseName(input))]
        var embedded: [(name: String, file: URL, type: String)] = []
        for attachment in attachments {
            let ext = (attachment.name as NSString).pathExtension.lowercased()
            if ext == "pdf" || attachment.type == "application/pdf" {
                parts.append(PDFAssembler.Part(url: attachment.file, title: attachment.name))
            } else if ImageImporter.extensions.contains(ext) || attachment.type.hasPrefix("image/") {
                let pdf = folder.appendingPathComponent(UUID().uuidString + ".pdf")
                if (try? ImageImporter.convert(attachment.file, to: pdf, options: options)) != nil {
                    parts.append(PDFAssembler.Part(url: pdf, title: attachment.name))
                } else {
                    embedded.append(attachment)
                }
            } else {
                embedded.append(attachment)
            }
        }
        let title = message.subject
        try await Task.detached(priority: .userInitiated) {
            _ = try PDFAssembler.join(parts.count == 1 ? [PDFAssembler.Part(url: messagePDF, title: nil)] : parts, to: output, title: title)
            guard !embedded.isEmpty else { return }
            let model = try PDFModel(url: output)
            for file in embedded {
                model.addEmbeddedFile(try Data(contentsOf: file.file), name: file.name, mimeType: file.type)
            }
            try model.data().write(to: output, options: .atomic)
        }.value
        return ImportReport()
    }

    private static func headerTable(_ message: MIMEPart) -> String {
        let rows = [("From", "from"), ("To", "to"), ("Cc", "cc"), ("Date", "date"), ("Subject", "subject")].compactMap { label, key -> String? in
            guard let value = message.header(key), !value.isEmpty else { return nil }
            return "<tr><th style=\"text-align:left;padding:1px 10px 1px 0;color:#666;font-weight:600;border:0;background:none\">\(label)</th>"
                + "<td style=\"padding:1px 0;border:0\">\(XML.escape(value))</td></tr>"
        }
        return "<table style=\"margin:0 0 12px;border-collapse:collapse;font:11px -apple-system,sans-serif\">\(rows.joined())</table>"
            + "<hr style=\"border:0;border-top:1px solid #ccc;margin:0 0 12px\">"
    }
}

/// A MIME entity (RFC 2045–2047): headers, and either a body or parts.
struct MIMEPart {
    var headers: [(name: String, value: String)]
    var body: Data
    var parts: [MIMEPart]

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { Self.decodeWords($0.value) }
    }

    var subject: String? { header("subject") }

    /// "text/html", lower-cased, without parameters; text/plain when absent.
    var contentType: String {
        (header("content-type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }) ?? "text/plain"
    }

    var contentID: String? {
        header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    var isAttachment: Bool { header("content-disposition")?.lowercased().hasPrefix("attachment") == true }

    var fileName: String? {
        parameter("filename", in: header("content-disposition")) ?? parameter("name", in: header("content-type"))
    }

    /// The body with its transfer encoding undone.
    var decodedBody: Data {
        switch header("content-transfer-encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let clean = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: clean, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable":
            return Self.quotedPrintable(body)
        default:
            return body
        }
    }

    /// The decoded body as text in its charset.
    var text: String {
        let charset = parameter("charset", in: header("content-type")) ?? "utf-8"
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let decoded = decodedBody
        if encoding != kCFStringEncodingInvalidId,
           let text = String(data: decoded, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
            return text
        }
        return String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .windowsCP1252) ?? ""
    }

    /// Parts without parts, depth first (bodies and attachments).
    func leaves() -> [MIMEPart] { parts.isEmpty ? [self] : parts.flatMap { $0.leaves() } }

    func parameter(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            // RFC 2231 "filename*=utf-8''name".
            if key == name + "*", let quote = pair[1].range(of: "''") {
                return String(pair[1][quote.upperBound...]).removingPercentEncoding
            }
            if key == name { return Self.decodeWords(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        }
        return nil
    }

    // MARK: Parsing

    static func parse(_ data: Data, depth: Int = 0) throws -> MIMEPart {
        let bytes = [UInt8](data)
        // Headers end at the first empty line (CRLF CRLF or LF LF).
        var split = bytes.count
        var bodyStart = bytes.count
        var i = 0
        while i < bytes.count {
            if bytes[i] == 10 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { split = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { split = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        let headerText = String(decoding: bytes[0..<split], as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        var headers: [(String, String)] = []
        for line in headerText.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        var part = MIMEPart(headers: headers, body: body, parts: [])
        if part.contentType.hasPrefix("multipart/"), depth < 20, let boundary = part.parameter("boundary", in: part.header("content-type")) {
            part.parts = try splitParts(body, boundary: boundary).map { try parse($0, depth: depth + 1) }
        }
        return part
    }

    private static func splitParts(_ body: Data, boundary: String) throws -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var current: Int?
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            if let start = current {
                var end = range.lowerBound
                // The line break before the delimiter belongs to it.
                if end > start, body[end - 1] == 10 { end -= 1 }
                if end > start, body[end - 1] == 13 { end -= 1 }
                parts.append(body.subdata(in: start..<max(start, end)))
            }
            var next = range.upperBound
            if next + 1 < body.endIndex, body[next] == 45, body[next + 1] == 45 { break }   // "--" closes
            while next < body.endIndex, body[next] != 10 { next += 1 }
            current = min(next + 1, body.endIndex)
            searchStart = current!
        }
        return parts
    }

    /// RFC 2047 encoded words: "=?utf-8?B?…?=" and "=?iso-8859-1?Q?…?=".
    static func decodeWords(_ text: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        var previousWasWord = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let charsetRange = Range(match.range(at: 1), in: text),
                  let modeRange = Range(match.range(at: 2), in: text), let payloadRange = Range(match.range(at: 3), in: text) else { continue }
            let between = String(text[last..<whole.lowerBound])
            // Whitespace between two encoded words is dropped.
            if !(previousWasWord && between.allSatisfy(\.isWhitespace)) { result += between }
            let payload = String(text[payloadRange])
            let bytes: Data = text[modeRange].lowercased() == "b"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
                : quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            let encoding = CFStringConvertIANACharSetNameToEncoding(String(text[charsetRange]).split(separator: "*").first.map(String.init)! as CFString)
            let decoded = encoding != kCFStringEncodingInvalidId
                ? String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) : nil
            result += decoded ?? String(decoding: bytes, as: UTF8.self)
            last = whole.upperBound
            previousWasWord = true
        }
        result += text[last...]
        return result
    }

    static func quotedPrintable(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        while i < bytes.count {
            let c = bytes[i]
            if c == 61 {   // "="
                if i + 2 < bytes.count, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                    out.append(high << 4 | low); i += 3; continue
                }
                // Soft line break.
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
