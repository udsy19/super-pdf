import CryptoKit
import Foundation
import SuperPDFCore

// The signature library (features #82, ARCHITECTURE "Data"): each saved signature or initials is a file in
// `Signatures/`, sealed with AES-GCM under a key that lives in the Keychain, so the pictures of someone's handwriting are
// never readable on disk by themselves. The key comes from a `SignatureKeyProvider`: the Keychain in the app, memory in
// the self-test.

/// The key the signature files are sealed with.
public protocol SignatureKeyProvider: AnyObject {
    func key() throws -> SymmetricKey
}

/// A 256-bit key kept as a generic password in the login Keychain (`SuperPDFPaths.keychainService`), made on first use.
public final class KeychainSignatureKey: SignatureKeyProvider {
    private static let account = "signature-images-key"
    private var cached: SymmetricKey?

    public init() {}

    public func key() throws -> SymmetricKey {
        if let cached { return cached }
        if let data = try Keychain.read(account: Self.account), data.count == 32 {
            cached = SymmetricKey(data: data)
            return cached!
        }
        let key = SymmetricKey(size: .bits256)
        try Keychain.write(key.withUnsafeBytes { Data($0) }, account: Self.account)
        cached = key
        return key
    }
}

/// A key for this process only (the self-test).
public final class MemorySignatureKey: SignatureKeyProvider {
    private let value = SymmetricKey(size: .bits256)
    public init() {}
    public func key() throws -> SymmetricKey { value }
}

/// Saved signatures on disk, newest last.
final class SignatureStore {
    private let folder: URL
    private let keys: SignatureKeyProvider
    private var loaded: [SavedSignature]?

    init(folder: URL, keys: SignatureKeyProvider) {
        self.folder = folder
        self.keys = keys
    }

    /// Nothing is read (and the Keychain isn't asked) until the library is first shown.
    var all: [SavedSignature] {
        if let loaded { return loaded }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [SavedSignature] = []
        for file in files where file.pathExtension == Self.fileExtension {
            guard let sealed = try? Data(contentsOf: file), let key = try? keys.key(), let box = try? AES.GCM.SealedBox(combined: sealed),
                  let plain = try? AES.GCM.open(box, using: key), let signature = try? JSONDecoder().decode(SavedSignature.self, from: plain)
            else { continue }
            result.append(signature)
        }
        result.sort { $0.created < $1.created }
        loaded = result
        return result
    }

    func save(_ signature: SavedSignature) throws {
        let plain = try JSONEncoder().encode(signature)
        guard let sealed = try AES.GCM.seal(plain, using: try keys.key()).combined else { throw CocoaError(.fileWriteUnknown) }
        try sealed.write(to: url(of: signature.id), options: [.atomic])
        var list = all.filter { $0.id != signature.id }
        list.append(signature)
        loaded = list
    }

    func delete(_ id: UUID) throws {
        let file = url(of: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        loaded = all.filter { $0.id != id }
    }

    private static let fileExtension = "signature"

    private func url(of id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension(Self.fileExtension)
    }
}
