import Foundation

/// FlateDecode data (RFC 1950 zlib streams) from Apple's raw DEFLATE (RFC 1951) plus the zlib header and Adler-32.
enum Flate {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x78, 0x9C])
        out.append(deflated)
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { bytes in
            // Sums stay below 2^32 for 5552-byte runs (zlib's NMAX).
            var index = 0
            let count = bytes.count
            while index < count {
                let end = min(index + 5552, count)
                for i in index..<end {
                    a += UInt32(bytes[i])
                    b += a
                }
                a %= 65521; b %= 65521
                index = end
            }
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }
}
