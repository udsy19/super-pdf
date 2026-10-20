import CommonCrypto
import CryptoKit
import Foundation
internal import QPDF

// Which password opened an encrypted file (ISO 32000-2 §7.6.4.4). QPDF's C API does not say, and only the owner
// (permissions) password lifts the restrictions; ProtectKit needs the difference to remove passwords honestly
// (features #87: we never crack passwords).

extension PDFModel {
    /// The file is unencrypted or was opened with its owner password.
    public var hasOwnerAccess: Bool {
        guard isEncrypted else { return true }
        guard let encrypt = trailer["Encrypt"], let revision = encrypt["R"]?.int else { return false }
        if revision >= 5 {
            guard let o = encrypt["O"]?.stringData.map([UInt8].init), o.count >= 40,
                  let u = encrypt["U"]?.stringData.map([UInt8].init), u.count >= 48 else { return false }
            let password = Array(passwordBytes.prefix(127))
            return Self.securityHash(password: password, salt: Array(o[32..<40]), userKey: Array(u[0..<48]), revision: revision) == Array(o[0..<32])
        }
        // R2–R4: QPDF recovers the user password from an owner password; given the user password it keeps it.
        guard let recovered = qpdf_get_user_password(q) else { return false }
        let user = Array(UnsafeBufferPointer(start: recovered, count: strlen(recovered))).map { UInt8(bitPattern: $0) }
        return user != passwordBytes
    }

    /// Algorithm 2.A/2.B: SHA-256 for R5, the iterated SHA-256/384/512 + AES hash for R6.
    static func securityHash(password: [UInt8], salt: [UInt8], userKey: [UInt8], revision: Int) -> [UInt8] {
        var k = Array(SHA256.hash(data: password + salt + userKey))
        guard revision >= 6 else { return k }
        var round = 0
        var last: UInt8 = 0
        while round < 64 || Int(last) > round - 32 {
            let block = password + k + userKey
            var k1 = [UInt8]()
            k1.reserveCapacity(block.count * 64)
            for _ in 0..<64 { k1 += block }
            let e = aes128CBC(key: Array(k[0..<16]), iv: Array(k[16..<32]), data: k1)
            let selector = e[0..<16].reduce(0) { $0 + Int($1) } % 3
            switch selector {
            case 0: k = Array(SHA256.hash(data: e))
            case 1: k = Array(SHA384.hash(data: e))
            default: k = Array(SHA512.hash(data: e))
            }
            last = e[e.count - 1]
            round += 1
        }
        return Array(k[0..<32])
    }

    /// AES-128-CBC encryption without padding (`data` is a multiple of 16 bytes).
    private static func aes128CBC(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv, data, data.count,
                    &out, out.count, &moved)
        return out
    }
}
