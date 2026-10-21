import Foundation

// TrueType (sfnt) files as tables (Apple TrueType Reference Manual, OpenType "Font file"): assembling one with its
// checksums, reading the tables of one, and splitting a collection (.ttc) into single fonts, so a face of a system
// collection can be embedded (features #100) and the OCR layer's glyphless font can be built.

enum SFNT {
    typealias Table = (tag: String, data: Data)

    /// An sfnt file from `tables`: sorted directory, 4-byte aligned tables, table checksums and the head table's
    /// checkSumAdjustment.
    static func assemble(_ tables: [Table], version: UInt32 = 0x0001_0000) -> Data {
        let sorted = tables.sorted { Array($0.tag.utf8).lexicographicallyPrecedes(Array($1.tag.utf8)) }
        let count = sorted.count
        var power = 1, exponent = 0
        while power * 2 <= count { power *= 2; exponent += 1 }
        var out = Data()
        out.append(u32: version)
        out.append(u16: UInt16(count))
        out.append(u16: UInt16(power * 16))
        out.append(u16: UInt16(exponent))
        out.append(u16: UInt16(count * 16 - power * 16))
        var offset = 12 + 16 * count
        var body = Data()
        var headOffset: Int?
        for table in sorted {
            var data = table.data
            if table.tag == "head", data.count >= 12 { data.replaceSubrange(8..<12, with: [0, 0, 0, 0]); headOffset = offset }
            out.append(contentsOf: Array(table.tag.utf8.prefix(4)) + Array(repeating: 0x20, count: max(0, 4 - table.tag.utf8.count)))
            out.append(u32: checksum(data))
            out.append(u32: UInt32(offset))
            out.append(u32: UInt32(data.count))
            body.append(data)
            let padding = (4 - data.count % 4) % 4
            body.append(contentsOf: [UInt8](repeating: 0, count: padding))
            offset += data.count + padding
        }
        out.append(body)
        if let headOffset {
            let adjustment = 0xB1B0_AFBA &- checksum(out)
            out.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: Data(u32: adjustment))
        }
        return out
    }

    /// The tables of the font whose offset table starts at `offset` (0 for a single font), nil when malformed.
    static func tables(of font: Data, at offset: Int = 0) -> [Table]? {
        let b = [UInt8](font)
        guard offset + 12 <= b.count else { return nil }
        let count = Int(b.u16(offset + 4))
        guard offset + 12 + count * 16 <= b.count else { return nil }
        var tables: [Table] = []
        for index in 0..<count {
            let record = offset + 12 + index * 16
            let tag = String(decoding: b[record..<(record + 4)], as: UTF8.self)
            let start = Int(b.u32(record + 8)), length = Int(b.u32(record + 12))
            guard start + length <= b.count else { return nil }
            tables.append((tag, Data(b[start..<(start + length)])))
        }
        return tables
    }

    /// The fonts of a collection as standalone files (empty when `data` isn't a collection).
    static func faces(ofCollection data: Data) -> [Data] {
        let b = [UInt8](data)
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "ttcf" else { return [] }
        let count = Int(b.u32(8))
        guard 12 + count * 4 <= b.count else { return [] }
        return (0..<count).compactMap { index in
            let offset = Int(b.u32(12 + index * 4))
            guard offset + 4 <= b.count, let tables = tables(of: data, at: offset) else { return nil }
            return assemble(tables, version: b.u32(offset))
        }
    }

    static func isCollection(_ data: Data) -> Bool { data.prefix(4) == Data("ttcf".utf8) }

    /// Big-endian sum of 32-bit words, the last one zero-padded.
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | UInt32(i + k < b.count ? b[i + k] : 0) }
            sum = sum &+ word
            i += 4
        }
        return sum
    }
}

extension Data {
    init(u32 value: UInt32) { self.init([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
    mutating func append(u32 value: UInt32) { append(Data(u32: value)) }
    mutating func append(u16 value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func append(i16 value: Int16) { append(u16: UInt16(bitPattern: value)) }
}

extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func u32(_ at: Int) -> UInt32 { UInt32(self[at]) << 24 | UInt32(self[at + 1]) << 16 | UInt32(self[at + 2]) << 8 | UInt32(self[at + 3]) }
}
