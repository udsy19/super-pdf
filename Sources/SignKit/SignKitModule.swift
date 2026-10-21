import SuperPDFCore

/// SignKit: the signature library, certificate signing and verification, certificates, request signatures
/// (docs/ARCHITECTURE.md, WP11). It registers `Services.sign` (`Signing`), `Services.requests` (`SignatureRequesting`),
/// and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .signKit)` to `Services.toolProviders`.
public enum SignKitModule {
    /// The app installs with the login Keychain and the system's share services; the self-test passes in-memory keys
    /// and a recording sharer, so it never touches the person's Keychain, Mail or Messages.
    @MainActor public static func install(keys: SigningKeyStore = KeychainSigningKeyStore(),
                                          signatureKey: SignatureKeyProvider = KeychainSignatureKey(),
                                          sharing: RequestSharing? = nil) {
        let sign = SignService(keys: keys, signatureKey: signatureKey, signaturesFolder: SuperPDFPaths.signatures)
        let requests = RequestService(sign: sign, sharing: sharing ?? SystemSharing())
        Services.sign = sign
        Services.requests = requests
        Services.toolProviders.append(SignToolProvider(sign: sign, requests: requests))
        requests.watchOpenedDocuments()
    }
}
