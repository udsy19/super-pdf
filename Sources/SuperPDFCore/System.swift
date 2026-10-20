import AppKit
import Security

// Small system helpers several modules share: the Keychain, colours from hex, byte and percentage formatting.
// Keychain and colour helpers adapted from super-granola Sources/SuperGranolaCore/System.swift (commit fd1f08b).

/// Generic passwords in the login Keychain (the signature images key, ARCHITECTURE "Data"). Signing private keys are
/// `SecKey`s that SignKit manages itself.
public enum Keychain {
    public enum Failure: LocalizedError, Equatable {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .status(let s): (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)."
            }
        }
    }

    public static func read(service: String = SuperPDFPaths.keychainService, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(service, account).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        return result as? Data
    }

    public static func write(_ data: Data, service: String = SuperPDFPaths.keychainService, account: String) throws {
        let update = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.status(update) }
        let add = SecItemAdd(query(service, account).merging([
            kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { $1 } as CFDictionary, nil)
        guard add == errSecSuccess else { throw Failure.status(add) }
    }

    public static func delete(service: String = SuperPDFPaths.keychainService, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA" (the "#" is optional); malformed input gives magenta so it shows.
    convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else {
            self.init(srgbRed: 1, green: 0, blue: 1, alpha: 1); return
        }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    /// "#RRGGBBAA" in sRGB, upper-case.
    var hexRGBA: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
    }
}

/// The numbers banners and panels show (ux §7.3): "6.1 MB", "72%".
public enum Formatting {
    /// File sizes as Finder shows them (decimal units).
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// The size saved, rounded down so "72% smaller" never overstates; 0 when nothing was saved.
    public static func percentSaved(before: Int64, after: Int64) -> Int {
        guard before > 0, after < before else { return 0 }
        return Int((Double(before - after) / Double(before) * 100).rounded(.down))
    }

    /// "1 page", "12 pages"; the noun is passed in its singular and plural forms.
    public static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}
