import AppKit
import Combine
import PDFModelKit
import SuperPDFCore

/// `Services.requests` (features #84): "Signatures I asked for" as a local file exchange. Each request lives in
/// `Requests/<id>/`: `request.json` (its state), the package as sent (`<name>.pdf`), the copy being filled in
/// (`current/<name>.pdf`), the files that came back (`returns/`, listed in `returns.json` with their SHA-256) and, at the
/// end, the sealed copy (`<name> (signed).pdf`).
@MainActor
public final class RequestService: ObservableObject, SignatureRequesting {
    @Published public private(set) var requests: [SignatureRequest] = []
    private let subject = PassthroughSubject<SignatureRequest, Never>()
    public var changes: AnyPublisher<SignatureRequest, Never> { subject.eraseToAnyPublisher() }

    let sign: SignService
    let sharing: RequestSharing
    private var window: NSWindowController?
    private var watcher: AnyCancellable?

    init(sign: SignService, sharing: RequestSharing) {
        self.sign = sign
        self.sharing = sharing
        load()
    }

    // MARK: Store

    struct ReturnRecord: Codable, Hashable {
        var file: String
        var sha256: String
        var received: Date
        /// The people whose fields this file completed or started.
        var signers: [UUID]
    }

    func folder(_ id: UUID) -> URL { SuperPDFPaths.request(id) }
    func packageURL(_ request: SignatureRequest) -> URL { folder(request.id).appendingPathComponent(request.documentName + ".pdf") }
    func currentURL(_ request: SignatureRequest) -> URL {
        SuperPDFPaths.ensure(folder(request.id).appendingPathComponent("current", isDirectory: true)).appendingPathComponent(request.documentName + ".pdf")
    }
    func sealedURL(_ request: SignatureRequest) -> URL {
        folder(request.id).appendingPathComponent(OutputSuffix.signed.fileName(base: request.documentName, ext: "pdf"))
    }
    private func stateURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("request.json") }
    private func returnsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("returns.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: SuperPDFPaths.requests, includingPropertiesForKeys: nil)) ?? []
        requests = folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("request.json"))).flatMap { try? Self.decoder.decode(SignatureRequest.self, from: $0) }
        }.sorted { $0.created > $1.created }
    }

    public func save(_ request: SignatureRequest) throws {
        try Self.encoder.encode(request).write(to: stateURL(request.id), options: .atomic)
        var list = requests.filter { $0.id != request.id }
        list.append(request)
        requests = list.sorted { $0.created > $1.created }
        subject.send(request)
    }

    func returns(of id: UUID) -> [ReturnRecord] {
        (try? Data(contentsOf: returnsURL(id))).flatMap { try? Self.decoder.decode([ReturnRecord].self, from: $0) } ?? []
    }

    // MARK: Package and sending

    public func makePackage(for request: SignatureRequest, from document: DocumentHandle) async throws -> URL {
        let source = document.snapshot()
        let data = try await Task.detached(priority: .userInitiated) { try RequestPackage.build(source, request: request) }.value
        let url = packageURL(request)
        try data.write(to: url, options: .atomic)
        try data.write(to: currentURL(request), options: .atomic)
        return url
    }

    /// Who gets the file now: everyone still to sign, or with "Sign in this order" the next one.
    func recipients(of request: SignatureRequest) -> [Signer] {
        let waiting = request.signers.filter { $0.state != .done }.sorted { $0.order < $1.order }
        return request.signInOrder ? Array(waiting.prefix(1)) : waiting
    }

    /// Step 3: builds the package, hands it to Mail, Messages or AirDrop and keeps the request (only once it went).
    /// Returns how many people it went to.
    func send(_ request: SignatureRequest, from document: DocumentHandle, via channel: SharingChannel) async throws -> Int {
        let url = try await makePackage(for: request, from: document)
        let people = recipients(of: request)
        try sharing.share(url, to: people.map(\.email), subject: SignStrings.mailSubject(request.documentName), message: request.message, via: channel)
        try save(request)
        return people.count
    }

    /// Remind: the copy as it stands (with the signatures so far) to one person, by Mail.
    func remind(_ request: SignatureRequest, signer: Signer) throws {
        try sharing.share(currentURL(request), to: [signer.email], subject: SignStrings.reminderSubject(request.documentName),
                          message: request.message, via: .mail)
    }

    /// Sign in person: the copy as it stands opens with the Sign tool; the signed copy it saves comes back here by
    /// itself when it opens (it carries the request).
    func signInPerson(_ request: SignatureRequest) async throws {
        let document = try await Services.documents.open(currentURL(request))
        Services.tools?.openPanel(.sign, for: document, inputs: [])
    }

    // MARK: Returns

    public func receive(_ file: URL) async throws -> SignatureRequest? {
        let data = try Data(contentsOf: file)
        let known = requests.map(\.id)
        let embedded = await Task.detached { RequestPackage.requestID(in: data, known: known) }.value
        guard let id = embedded ?? RequestReturns.coverReference(in: data, known: known), var request = requests.first(where: { $0.id == id }) else {
            return nil
        }
        guard request.sealedAt == nil, let package = try? Data(contentsOf: packageURL(request)) else { return request }
        let master = (try? Data(contentsOf: currentURL(request))) ?? package
        if data == package || data == master { return request }

        let open = request.fields.filter { field in request.signers.contains { $0.id == field.signerID && $0.state != .done } }
        let filled = RequestReturns.filledFields(returned: data, package: package, fields: open)
        guard !filled.isEmpty else { return request }
        let alreadyIn = RequestReturns.filledFields(returned: master, package: package, fields: open)
        let fresh = open.filter { filled.contains($0.id) && !alreadyIn.contains($0.id) }

        // An appended update to the copy as it stands keeps every digital signature; anything else comes across box by box.
        let merged: Data
        if data.count > master.count, data.prefix(master.count) == master {
            merged = data
        } else if !fresh.isEmpty {
            merged = try await transplant(fresh, from: data, into: master, request: request)
        } else {
            return request
        }
        try merged.write(to: currentURL(request), options: .atomic)

        let done = RequestReturns.filledFields(returned: merged, package: package, fields: request.fields)
        var moved: [UUID] = []
        for i in request.signers.indices where request.signers[i].state != .done {
            let theirs = request.fields.filter { $0.signerID == request.signers[i].id }
            let count = theirs.filter { done.contains($0.id) }.count
            let state: SignerState = !theirs.isEmpty && count == theirs.count ? .done : count > 0 ? .returned : request.signers[i].state
            guard state != request.signers[i].state else { continue }
            request.signers[i].state = state
            request.signers[i].returnedAt = Date()
            moved.append(request.signers[i].id)
        }
        guard !moved.isEmpty else { return request }

        // Keep their file as it came, for the audit page.
        let returns = SuperPDFPaths.ensure(folder(request.id).appendingPathComponent("returns", isDirectory: true))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let kept = returns.appendingPathComponent("\(stamp) \(file.lastPathComponent)")
        try data.write(to: kept, options: .atomic)
        var log = self.returns(of: request.id)
        log.append(ReturnRecord(file: kept.lastPathComponent, sha256: Certificates.fingerprint(data), received: Date(), signers: moved))
        try Self.encoder.encode(log).write(to: returnsURL(request.id), options: .atomic)
        try save(request)
        return request
    }

    private func transplant(_ fields: [RequestField], from data: Data, into master: Data, request: SignatureRequest) async throws -> Data {
        let signed = await Task.detached { Set((try? PDFModel(data: data))?.signatures().map(\.fieldName) ?? []) }.value
        let prefix = RequestPackage.prefix(request.id)
        let marks: [PlacedMark] = fields.compactMap { field in
            let page = field.page + RequestPackage.coverPages
            return RequestReturns.region(of: data, page: page, rect: field.rect, fieldPrefix: prefix, signedFields: signed).map {
                PlacedMark(mark: .pdf($0), page: page, rect: field.rect, label: SignStrings.fieldKind(field.kind))
            }
        }
        return try await Task.detached(priority: .userInitiated) { try await PDFSigner.sign(.data(master), marks: marks, certificate: nil) }.value
    }

    // MARK: Seal

    public func seal(_ request: SignatureRequest, identityID: String) async throws -> URL {
        guard let identity = sign.identities.first(where: { $0.id == identityID }) else { throw SigningKeyError.notFound }
        let package = try Data(contentsOf: packageURL(request))
        let master = (try? Data(contentsOf: currentURL(request))) ?? package
        let now = Date()
        let record = AuditRecord(request: request, returns: returns(of: request.id), packageHash: Certificates.fingerprint(package),
                                 sealedBy: identity.commonName, sealedAt: now)
        let audited = try await Task.detached(priority: .userInitiated) { try AuditPage.append(record, to: master) }.value
        let options = CertificateSignOptions(identityID: identityID, page: audited.page, rect: audited.signatureBox, lockDocument: true,
                                             timestampServer: Defaults[.addTrustedTimestamp] ? Defaults[.timestampServer] : nil)
        let sealed = try await sign.signedCopy(.data(audited.data), marks: [], certificate: options, handwriting: nil)
        let url = sealedURL(request)
        try sealed.write(to: url, options: .atomic)
        var finished = request
        finished.sealedAt = now
        try save(finished)
        return url
    }

    // MARK: Window › Signature Requests

    public func showRequestsWindow() {
        if window == nil { window = RequestsWindowController(service: self) }
        window?.showWindow(nil)
        window?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Files that come back by being opened

    /// A returned copy opened anywhere in the app is matched and merged, with a banner in its window.
    func watchOpenedDocuments() {
        watcher = Services.documents?.events.sink { [weak self] event in
            guard case .opened(let id) = event else { return }
            Task { @MainActor [weak self] in await self?.match(documentID: id) }
        }
    }

    private func match(documentID: UUID) async {
        guard !requests.isEmpty, let document = Services.documents?.openDocuments.first(where: { $0.id == documentID }),
              let url = document.url else { return }
        let before = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        guard let updated = try? await receive(url), let previous = before[updated.id], previous != updated else { return }
        let names = updated.signers.filter { signer in previous.signers.first { $0.id == signer.id }?.state != signer.state }.map(\.name)
        guard !names.isEmpty else { return }
        Services.viewer?.showBanner(ResultBanner(SignStrings.cameBack(updated.documentName, from: names), actions: [.showRequests]), in: document)
    }
}
