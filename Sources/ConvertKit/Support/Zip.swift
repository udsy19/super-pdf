import Foundation

// ZIP containers (PKWARE APPNOTE 6.3): OOXML, OpenDocument, EPUB, HWPX and iWork files are ZIPs, and ZIP → PDF unpacks
// one (features #44). Stored and DEFLATE entries; Zip64 sizes and offsets; no encryption. Apple's `NSData` "zlib"
// algorithm is raw DEFLATE (RFC 1951), which is what ZIP stores.

enum ZipError: Error, Equatable {
    case notAZip
    case damaged(String)
    case unsupported(String)
    /// Over the safety limits (entry count, size or compression ratio): a zip bomb or simply too big.
    case tooLarge
}

/// A ZIP file read from memory: the central directory, and each entry's bytes on demand.
struct ZipArchive {
    struct Entry: Hashable {
        /// The path inside the archive, "/"-separated, as stored.
        var path: String
        var method: UInt16
        var flags: UInt16
        var crc32: UInt32
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// Limits that keep a hostile archive from filling memory or the disk.
    static let maxEntries = 100_000
    static let maxEntrySize = 1 << 30
    static let maxTotalSize = 4 << 30
    static let maxRatio = 1_000

    let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readDirectory(data)
    }

    /// Whether the bytes start like a ZIP (local header or an empty archive's end record).
    static func looksLikeZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        return head == Data([0x50, 0x4B, 0x03, 0x04]) || head == Data([0x50, 0x4B, 0x05, 0x06])
    }

    /// The entry at `path`; OPC part names compare without case, so an exact match is tried first, then any case.
    func entry(_ path: String) -> Entry? {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return entries.first { $0.path == path } ?? entries.first { $0.path.caseInsensitiveCompare(path) == .orderedSame }
    }

    func data(_ path: String) throws -> Data? {
        guard let entry = entry(path) else { return nil }
        return try data(for: entry)
    }

    func data(for entry: Entry) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ZipError.unsupported("encrypted entry") }
        guard entry.size <= Self.maxEntrySize, entry.size <= max(entry.compressedSize, 1) * Self.maxRatio else { throw ZipError.tooLarge }
        let local = entry.localHeaderOffset
        guard local >= 0, local + 30 <= data.count, data.u32(local) == 0x0403_4B50 else { throw ZipError.damaged("local header of \(entry.path)") }
        let start = local + 30 + Int(data.u16(local + 26)) + Int(data.u16(local + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.damaged("data of \(entry.path)") }
        let raw = data.subdata(in: start..<start + entry.compressedSize)
        let bytes: Data
        switch entry.method {
        case 0:
            bytes = raw
        case 8:
            if entry.size == 0 { return Data() }
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else { throw ZipError.damaged("deflate of \(entry.path)") }
            bytes = inflated
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard bytes.count == entry.size else { throw ZipError.damaged("size of \(entry.path)") }
        guard CRC32.checksum(bytes) == entry.crc32 else { throw ZipError.damaged("checksum of \(entry.path)") }
        return bytes
    }

    /// Unpacks every file into `folder` (which must exist); entries that would land outside it ("../", absolute paths)
    /// are skipped. Returns the files written, in archive order.
    @discardableResult
    func extract(to folder: URL) throws -> [URL] {
        let root = folder.standardizedFileURL.path + "/"
        var total = 0
        var written: [URL] = []
        for entry in entries where !entry.isDirectory {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains(".."), !entry.path.hasPrefix("/"),
                  !components.contains(where: { $0.hasPrefix("__MACOSX") }) else { continue }
            let target = components.reduce(folder) { $0.appendingPathComponent($1) }
            guard target.standardizedFileURL.path.hasPrefix(root) else { continue }
            total += entry.size
            guard total <= Self.maxTotalSize else { throw ZipError.tooLarge }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(for: entry).write(to: target)
            written.append(target)
        }
        return written
    }

    // MARK: Directory

    private static func readDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAZip }
        // The end-of-central-directory record sits in the last 22 + 65535 bytes.
        let floor = max(0, data.count - 22 - 0xFFFF)
        var eocd = -1
        var i = data.count - 22
        while i >= floor {
            if data.u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        var count = Int(data.u16(eocd + 10))
        var directorySize = Int(data.u32(eocd + 12))
        var directoryOffset = Int(data.u32(eocd + 16))
        // Zip64: the locator just before the end record points at the Zip64 end record.
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF, eocd >= 20, data.u32(eocd - 20) == 0x0706_4B50 {
            let record = Int(data.u64(eocd - 12))
            guard record + 56 <= data.count, data.u32(record) == 0x0606_4B50 else { throw ZipError.damaged("zip64 end record") }
            count = Int(data.u64(record + 32))
            directorySize = Int(data.u64(record + 40))
            directoryOffset = Int(data.u64(record + 48))
        }
        guard count <= maxEntries else { throw ZipError.tooLarge }
        guard directoryOffset >= 0, directoryOffset + directorySize <= data.count else { throw ZipError.damaged("central directory") }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var p = directoryOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { throw ZipError.damaged("central directory entry") }
            let flags = data.u16(p + 8), method = data.u16(p + 10), crc = data.u32(p + 16)
            var compressed = Int(data.u32(p + 20)), size = Int(data.u32(p + 24))
            let nameLength = Int(data.u16(p + 28)), extraLength = Int(data.u16(p + 30)), commentLength = Int(data.u16(p + 32))
            var offset = Int(data.u32(p + 42))
            guard p + 46 + nameLength + extraLength <= data.count else { throw ZipError.damaged("entry name") }
            let nameBytes = data.subdata(in: p + 46..<p + 46 + nameLength)
            // Bit 11: UTF-8 names; others are CP437, which Latin-1 reads well enough for the ASCII names in practice.
            let path = (flags & 0x800 != 0 ? String(data: nameBytes, encoding: .utf8) : nil)
                ?? String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            // Zip64 extended information replaces the fields that are all ones, in this order.
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let tag = data.u16(e), length = Int(data.u16(e + 2))
                if tag == 0x0001 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF, f + 8 <= extraEnd { size = Int(data.u64(f)); f += 8 }
                    if compressed == 0xFFFF_FFFF, f + 8 <= extraEnd { compressed = Int(data.u64(f)); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= extraEnd { offset = Int(data.u64(f)) }
                }
                e += 4 + length
            }
            entries.append(Entry(path: path, method: method, flags: flags, crc32: crc, compressedSize: compressed, size: size, localHeaderOffset: offset))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

/// Writes a ZIP in memory: the OOXML and EPUB writers' container.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    /// Adds a file. EPUB's `mimetype` must be first and stored (`compress: false`).
    mutating func add(_ path: String, _ data: Data, compress: Bool = true) {
        let crc = CRC32.checksum(data)
        var stored = data
        var method: UInt16 = 0
        if compress, data.count > 64, let deflated = try? (data as NSData).compressed(using: .zlib) as Data, deflated.count < data.count {
            stored = deflated
            method = 8
        }
        let name = Data(path.utf8)
        let offset = body.count
        // DOS time 00:00, date 1980-01-01: reproducible output.
        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(0x800); local.le16(method); local.le16(0); local.le16(0x21)
        local.le32(crc); local.le32(UInt32(stored.count)); local.le32(UInt32(data.count)); local.le16(UInt16(name.count)); local.le16(0)
        body.append(local); body.append(name); body.append(stored)

        var central = Data()
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0x800); central.le16(method); central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(stored.count)); central.le32(UInt32(data.count)); central.le16(UInt16(name.count))
        central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(UInt32(offset))
        directory.append(central); directory.append(name)
        count += 1
    }

    mutating func add(_ path: String, _ text: String, compress: Bool = true) { add(path, Data(text.utf8), compress: compress) }

    func finish() -> Data {
        var out = body
        out.append(directory)
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0); end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(directory.count)); end.le32(UInt32(body.count)); end.le16(0)
        out.append(end)
        return out
    }
}

/// CRC-32 (IEEE 802.3), as ZIP stores it.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }

    mutating func le16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 0xFFFF)); le16(UInt16(value >> 16)) }
}
