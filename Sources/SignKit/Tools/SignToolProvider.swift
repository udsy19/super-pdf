import AppKit
import Combine
import PDFKit
import PDFModelKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The Sign & fill tiles SignKit serves (ux §4.1, §5.3): Sign (D), Request signatures (G) and Certificates & signatures
/// (G). Panels are described here; the work is `SignService`'s and `RequestService`'s.
@MainActor
final class SignToolProvider: ToolProviding {
    private let sign: SignService
    private let requests: RequestService
    private var signBoards: [UUID: SignBoard] = [:]
    private var requestBoards: [UUID: RequestBoard] = [:]
    /// "Signatures in this file", with the fingerprint of the bytes they were checked on.
    private var verified: [UUID: (fingerprint: String, source: PDFSource, reports: [SignatureReport])] = [:]
    private var closing: AnyCancellable?

    init(sign: SignService, requests: RequestService) {
        self.sign = sign
        self.requests = requests
        closing = Services.documents?.events.sink { [weak self] event in
            guard case .closed(let id) = event else { return }
            MainActor.assumeIsolated {
                self?.signBoards[id] = nil
                self?.requestBoards[id] = nil
                self?.verified[id] = nil
            }
        }
    }

    var tools: [ToolID] { ToolCatalog.tiles(ownedBy: .signKit).map(\.id) }

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .sign: signPanel(context)
        case .requestSignatures: requestPanel(context)
        default: certificatesPanel(context)
        }
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        switch tool {
        case .sign: signPreview(context)
        case .requestSignatures: requestPreview(context)
        default: await verify(context)
        }
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        switch context.tool {
        case .sign: try await handleSign(action, context: context)
        case .requestSignatures: try await handleRequest(action, context: context)
        default: try await handleCertificates(action, context: context)
        }
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        switch request.tool {
        case .sign: try await runSign(request)
        case .requestSignatures: try await runRequest(request)
        default: .none
        }
    }

    // MARK: - Sign (ux §5.3, panel-sign.png)

    func signBoard(_ document: DocumentHandle) -> SignBoard {
        if let board = signBoards[document.id] { return board }
        let board = SignBoard(document: document) { [weak sign] in sign?.savedSignatures ?? [] }
        signBoards[document.id] = board
        return board
    }

    private func signPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let mode = SignBoard.Mode(rawValue: v.string("kind", default: SignBoard.Mode.mine.rawValue)) ?? .mine
        var controls: [ToolControl] = [
            .segmented(id: "kind", options: [ToolOption(SignBoard.Mode.mine.rawValue, SignStrings.mySignature),
                                             ToolOption(SignBoard.Mode.certificate.rawValue, SignStrings.withCertificate)],
                       selected: SignBoard.Mode.mine.rawValue),
        ]
        let output = OutputPolicy.sibling(.signed, ext: "pdf")
        guard let document = context.document else {
            return ToolPanel(.mode, hint: SignStrings.signHint, controls: controls, primary: ToolButton(SignStrings.signAndSave, isEnabled: false),
                             output: output)
        }
        let board = signBoard(document)
        board.mode = mode
        board.sync(addsDate: v.bool("date", default: true), text: v.string("text"))
        var more: [ToolControl] = []
        let ready: Bool
        switch mode {
        case .mine:
            controls += [
                .custom(id: "pads", make: { [sign] in BoardHost(board: board, content: LibraryCards(board: board, sign: sign)) }),
                .action(id: "create", title: SignStrings.createSignature, isDestructive: false, symbol: "plus"),
                .note(SignStrings.captureNote),
                .toggle(id: "date", label: SignStrings.addDate, isOn: true, rowLabel: SignStrings.date),
            ]
            more = [.text(id: "text", label: SignStrings.text, placeholder: SignStrings.textPlaceholder, value: "", isSecure: false)]
            ready = !board.marks.isEmpty
        case .certificate:
            let identities = sign.identities
            if !identities.isEmpty {
                controls.append(.popup(id: "identity", label: SignStrings.certificate,
                                       options: identities.prefix(SPMetrics.ToolPanel.maximumPopupItems).map { ToolOption($0.id, $0.commonName, detail: $0.email) },
                                       selected: sign.preferredIdentity?.id ?? identities[0].id))
            }
            controls.append(.action(id: "createIdentity", title: SignStrings.createCertificate, isDestructive: false, symbol: "plus"))
            controls.append(.text(id: "reason", label: SignStrings.reason, placeholder: SignStrings.reasonPlaceholder, value: "", isSecure: false))
            controls.append(.toggle(id: "lock", label: SignStrings.lockAfterSigning, isOn: false))
            let seal = sealAppearance(v, board: board)
            controls.append(.custom(id: "seal." + Self.key(seal), make: { BoardHost(board: board, content: SealPreview(seal: seal)) }))
            controls.append(.note(SignStrings.certificatePlacement))
            more = [.text(id: "location", label: SignStrings.location, placeholder: SignStrings.locationPlaceholder, value: "", isSecure: false)]
            ready = identity(v) != nil
        }
        return ToolPanel(.mode, hint: mode == .mine ? SignStrings.signHint : nil, controls: controls, moreOptions: more,
                         primary: ToolButton(SignStrings.signAndSave, isEnabled: ready), output: output)
    }

    /// The certificate chosen in the popup, else the one Sign proposes.
    private func identity(_ v: ToolValues) -> SigningIdentity? {
        let all = sign.identities
        return all.first { $0.id == v.string("identity") } ?? sign.preferredIdentity
    }

    /// The person's chosen handwritten signature, for the certificate box.
    private func handwriting(_ board: SignBoard) -> Data? {
        sign.savedSignatures.first { $0.id == board.chosen && $0.kind == .signature }?.image
    }

    private func sealAppearance(_ v: ToolValues, board: SignBoard) -> SealAppearance {
        SealAppearance(image: handwriting(board), name: identity(v)?.commonName ?? NSFullUserName(), date: Date(),
                       reason: v.string("reason").trimmingCharacters(in: .whitespaces), location: v.string("location").trimmingCharacters(in: .whitespaces))
    }

    /// A key that changes with what the certificate box shows (not with the clock).
    private static func key(_ seal: SealAppearance) -> String {
        var hasher = Hasher()
        hasher.combine(seal.image)
        hasher.combine(seal.name)
        hasher.combine(seal.reason)
        hasher.combine(seal.location)
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }

    private func signPreview(_ context: ToolContext) -> ToolPreview {
        guard let document = context.document, let board = signBoards[document.id] else { return .none }
        let seal = sealAppearance(context.values, board: board)
        let shown = board.placements.filter { board.mode == .certificate || $0.content != .certificate }
        let marks = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, board.mark(of: $0)) })
        let selection = board.selection
        guard !shown.isEmpty else { return .none }
        return .overlay { page, cg in
            guard let index = page.document?.index(for: page) else { return }
            for placement in shown where placement.page == index {
                cg.saveGState()
                let box = Appearance.upright(placement.rect, rotation: page.rotation, context: cg)
                if placement.content == .certificate {
                    cg.setFillColor(CGColor(gray: 1, alpha: 0.85))
                    cg.fill(box)
                    Appearance.drawSeal(seal, in: box, context: cg)
                } else if let mark = marks[placement.id] ?? nil {
                    Appearance.draw(mark, in: box, context: cg)
                }
                cg.restoreGState()
                if placement.id == selection { PageBoxDrawing.drawSelection(placement.rect, in: cg) }
            }
        }
    }

    private func handleSign(_ action: String, context: ToolContext) async throws -> ToolValues {
        var values = context.values
        guard let document = context.document else { return values }
        let board = signBoard(document)
        switch action {
        case "create":
            guard let signature = await CreateSignatureSheet().run(on: Services.viewer?.pdfView(for: document)?.window) else { return values }
            try sign.save(signature)
            board.chosen = signature.id
            board.changed()
            values["kind"] = .string(SignBoard.Mode.mine.rawValue)
        case "createIdentity":
            guard let details = await Prompts.newCertificate(in: Services.viewer?.pdfView(for: document)?.window) else { return values }
            let identity = try await sign.createIdentity(name: details.name, email: details.email)
            values["identity"] = .string(identity.id)
        default:
            break
        }
        return values
    }

    private func runSign(_ request: ToolRequest) async throws -> ToolResult {
        guard let document = request.document, let source = request.source else { return .none }
        let v = request.values
        let board = signBoard(document)
        board.mode = SignBoard.Mode(rawValue: v.string("kind", default: SignBoard.Mode.mine.rawValue)) ?? .mine
        board.sync(addsDate: v.bool("date", default: true), text: v.string("text"))
        let marks = board.marks.compactMap { placement in
            board.mark(of: placement).map { PlacedMark(mark: $0, page: placement.page, rect: placement.rect, label: board.label(of: placement)) }
        }
        var options: CertificateSignOptions?
        var handwriting: Data?
        if board.mode == .certificate {
            guard let identity = identity(v) else { throw ToolError(SignStrings.noCertificate) }
            let box = board.certificateBox
            options = CertificateSignOptions(identityID: identity.id, page: box?.page ?? 0, rect: box?.rect,
                                             reason: v.string("reason").trimmingCharacters(in: .whitespaces),
                                             location: v.string("location").trimmingCharacters(in: .whitespaces), lockDocument: v.bool("lock"),
                                             timestampServer: Defaults[.addTrustedTimestamp] ? Defaults[.timestampServer] : nil)
            handwriting = self.handwriting(board)
            Defaults[.defaultCertificateID] = identity.id
        } else if marks.isEmpty {
            return .none
        }
        let data: Data
        do { data = try await sign.signedCopy(source, marks: marks, certificate: options, handwriting: handwriting) } catch SignError.encrypted {
            throw ToolError(SignStrings.encrypted)
        }
        let output = request.workFolder.appendingPathComponent("signed.pdf")
        try data.write(to: output, options: .atomic)
        signBoards[document.id] = nil
        return .newFile(output, banner: Strings.Banner.signed(request.destination?.lastPathComponent ?? output.lastPathComponent))
    }

    // MARK: - Request signatures (ux §5.3, panel-request-signatures.png)

    func requestBoard(_ document: DocumentHandle) -> RequestBoard {
        if let board = requestBoards[document.id] { return board }
        let board = RequestBoard(document: document)
        requestBoards[document.id] = board
        return board
    }

    private static let fieldKinds: [ToolOption] = RequestFieldKind.allCases.map {
        ToolOption($0.rawValue, SignStrings.fieldKind($0), symbol: $0 == .signature ? "signature" : nil)
    }

    private func requestPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let step = min(max(v.int(ToolPanel.stepValue), 0), SignStrings.steps.count - 1)
        guard let document = context.document else {
            return ToolPanel(.flow, hint: SignStrings.requestHint, steps: SignStrings.steps, currentStep: 0,
                             primary: ToolButton(SignStrings.nextWhere, isEnabled: false))
        }
        let board = requestBoard(document)
        board.kind = v.strings("field").first.flatMap(RequestFieldKind.init(rawValue:)) ?? .signature
        let order = ToolControl.toggle(id: "order", label: SignStrings.signInOrder, isOn: false)
        var controls: [ToolControl]
        let primary: ToolButton
        var message: ToolMessage?
        switch step {
        case 0:
            controls = [.note(SignStrings.who), .custom(id: "people", make: { SignerEditor(board: board) }), order]
            primary = ToolButton(SignStrings.nextWhere, isEnabled: !board.signers.isEmpty)
        case 1:
            if board.current == nil || !board.signers.contains(where: { $0.id == board.current }) { board.current = board.signers.first?.id }
            controls = [
                .note(SignStrings.whereNote),
                .custom(id: "signers", make: { BoardHost(board: board, content: SignerPicker(board: board)) }),
                .chips(id: "field", options: Self.fieldKinds, selected: [RequestFieldKind.signature.rawValue], allowsMultiple: false),
                order,
                .note(SignStrings.fieldsNote),
            ]
            primary = ToolButton(SignStrings.nextSend, isEnabled: board.isPlaced)
            if !board.fields.isEmpty && !board.isPlaced { message = ToolMessage(.info, SignStrings.everyoneNeedsAField) }
        default:
            controls = [
                .text(id: "message", label: SignStrings.message, placeholder: "", value: SignStrings.defaultMessage(document.displayName), isSecure: false),
                .note(SignStrings.sendNote),
                .action(id: SharingChannel.messages.rawValue, title: SignStrings.sendWithMessages, isDestructive: false, symbol: "message"),
                .action(id: SharingChannel.airDrop.rawValue, title: SignStrings.airDrop, isDestructive: false, symbol: "airplayaudio"),
                .action(id: Self.saveAction, title: SignStrings.saveSigningPackage, isDestructive: false, symbol: "square.and.arrow.down"),
            ]
            primary = ToolButton(SignStrings.sendWithMail, isEnabled: board.isPlaced)
        }
        return ToolPanel(.flow, hint: SignStrings.requestHint, steps: SignStrings.steps, currentStep: step, controls: controls, primary: primary,
                         message: message)
    }

    private func requestPreview(_ context: ToolContext) -> ToolPreview {
        guard let document = context.document, let board = requestBoards[document.id], !board.fields.isEmpty else { return .none }
        let fields = board.fields, signers = Dictionary(uniqueKeysWithValues: board.signers.map { ($0.id, $0) }), selection = board.selection
        return .overlay { page, cg in
            guard let index = page.document?.index(for: page) else { return }
            for field in fields where field.page == index {
                guard let signer = signers[field.signerID] else { continue }
                let color = (NSColor(hex: signer.color).usingColorSpace(.sRGB) ?? .systemPurple).cgColor
                cg.saveGState()
                let box = Appearance.upright(RequestPackage.widgetRect(field.rect, rotation: page.rotation), rotation: page.rotation, context: cg)
                RequestPackage.drawField(label: RequestPackage.label(field.kind, signer: signer), color: color, ticked: false, in: box, context: cg)
                cg.restoreGState()
                if field.id == selection { PageBoxDrawing.drawSelection(field.rect, in: cg) }
            }
        }
    }

    /// The request the panel describes.
    private func makeRequest(_ board: RequestBoard, values: ToolValues, document: DocumentHandle) -> SignatureRequest {
        var signers = board.signers
        for i in signers.indices { signers[i].order = i }
        let typed = values.string("message").trimmingCharacters(in: .whitespacesAndNewlines)
        return SignatureRequest(documentName: document.displayName, signers: signers, signInOrder: values.bool("order"), fields: board.fields,
                                message: typed.isEmpty ? SignStrings.defaultMessage(document.displayName) : typed)
    }

    private static let saveAction = "save"

    private func handleRequest(_ action: String, context: ToolContext) async throws -> ToolValues {
        guard let document = context.document, let board = requestBoards[document.id], board.isPlaced,
              action == Self.saveAction || SharingChannel(rawValue: action) != nil else { return context.values }
        let request = makeRequest(board, values: context.values, document: document)
        if let channel = SharingChannel(rawValue: action) {
            let people = try await requests.send(request, from: document, via: channel)
            Services.viewer?.showBanner(Strings.Banner.requestSent(people: people), in: document)
        } else {
            try requests.save(request)
            let package = try await requests.makePackage(for: request, from: document)
            guard let destination = Prompts.saveFile(named: package.lastPathComponent, type: .pdf, in: document.url?.deletingLastPathComponent()) else {
                return context.values
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: package, to: destination)
            Services.viewer?.showBanner(Strings.Banner.saved(destination.lastPathComponent, openIn: nil), in: document)
        }
        requestBoards[document.id] = nil
        Services.tools?.closePanel(for: document)
        return context.values
    }

    private func runRequest(_ request: ToolRequest) async throws -> ToolResult {
        guard let document = request.document, let board = requestBoards[document.id], board.isPlaced else { return .none }
        let people = try await requests.send(makeRequest(board, values: request.values, document: document), from: document, via: .mail)
        requestBoards[document.id] = nil
        Services.viewer?.showBanner(Strings.Banner.requestSent(people: people), in: document)
        return .none
    }

    // MARK: - Certificates & signatures (ux §5.3)

    private func certificatesPanel(_ context: ToolContext) -> ToolPanel {
        let tab = context.values.string("tab", default: "file")
        var controls: [ToolControl] = [
            .segmented(id: "tab", options: [ToolOption("file", SignStrings.signaturesInFile), ToolOption("mine", SignStrings.myCertificate),
                                            ToolOption("trusted", SignStrings.peopleITrust)], selected: "file"),
        ]
        var message: ToolMessage?
        switch tab {
        case "mine":
            let identities = sign.identities
            controls.append(identities.isEmpty ? .note(SignStrings.noCertificate)
                : .custom(id: "identities." + identities.map(\.id).joined(separator: ","), make: {
                    InfoRows(rows: CertificateRows.identities(identities), document: context.document)
                }))
            controls.append(.action(id: "createIdentity", title: SignStrings.createCertificate, isDestructive: false, symbol: "plus"))
            controls.append(.action(id: "import", title: SignStrings.importP12, isDestructive: false, symbol: "square.and.arrow.down"))
        case "trusted":
            let trusted = sign.trustedCertificates
            controls.append(trusted.isEmpty ? .note(SignStrings.noTrusted)
                : .custom(id: "trusted." + trusted.map(\.id).joined(separator: ","), make: {
                    InfoRows(rows: CertificateRows.trusted(trusted), document: context.document)
                }))
            controls.append(.action(id: "addTrusted", title: SignStrings.trustCertificateFile, isDestructive: false, symbol: "plus"))
        default:
            if let document = context.document, let cached = verified[document.id] {
                if cached.reports.isEmpty {
                    controls.append(.note(SignStrings.noSignatures))
                } else {
                    let reports = cached.reports
                    controls.append(.custom(id: "reports." + Self.key(reports), make: {
                        InfoRows(rows: CertificateRows.reports(reports), document: context.document)
                    }))
                    if let broken = reports.firstIndex(where: { $0.validity == .modified }) {
                        message = ToolMessage(.warning, Strings.Errors.signatureInvalid,
                                              action: ToolOption("changed.\(broken)", Strings.Errors.showWhatChanged))
                    }
                }
            } else {
                controls.append(.note(SignStrings.checking))
            }
        }
        return ToolPanel(.flow, controls: controls, primary: ToolButton(Strings.Panel.done), secondary: nil, message: message)
    }

    private static func key(_ reports: [SignatureReport]) -> String {
        var hasher = Hasher()
        hasher.combine(reports)
        return String(UInt(bitPattern: hasher.finalize()), radix: 36)
    }

    /// Checks the document's signatures when its bytes changed since the last look.
    private func verify(_ context: ToolContext) async -> ToolPreview {
        guard let document = context.document else { return .none }
        let source = document.snapshot()
        let fingerprint = source.fingerprint()
        guard verified[document.id]?.fingerprint != fingerprint else { return .none }
        let reports = (try? await sign.verify(source)) ?? []
        verified[document.id] = (fingerprint, source, reports)
        return .none
    }

    private func handleCertificates(_ action: String, context: ToolContext) async throws -> ToolValues {
        let window = context.document.flatMap { Services.viewer?.pdfView(for: $0)?.window }
        let parts = action.split(separator: ".", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "trust":
            guard let document = context.document, let index = Int(argument), let report = verified[document.id]?.reports[safe: index] else { break }
            _ = try sign.trust(report.certificate)
            verified[document.id] = nil
        case "changed":
            guard let document = context.document, let index = Int(argument), let cached = verified[document.id],
                  let report = cached.reports[safe: index] else { break }
            try showSignedVersion(of: report, source: cached.source, document: document)
        case "createIdentity":
            guard let details = await Prompts.newCertificate(in: window) else { break }
            _ = try await sign.createIdentity(name: details.name, email: details.email)
        case "import":
            guard let file = Prompts.chooseFile([UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data]),
                  let password = await Prompts.p12Password(in: window) else { break }
            _ = try await sign.importIdentity(p12: file, password: password)
        case "export":
            guard let identity = sign.identities.first(where: { $0.id == argument }),
                  let destination = Prompts.saveFile(named: identity.commonName + ".cer", type: UTType(filenameExtension: "cer") ?? .data,
                                                     in: nil) else { break }
            try sign.exportCertificate(of: identity.id, to: destination)
        case "addTrusted":
            guard let file = Prompts.chooseFile([UTType(filenameExtension: "cer") ?? .data, UTType(filenameExtension: "crt") ?? .data,
                                                 UTType(filenameExtension: "pem") ?? .data, UTType(filenameExtension: "der") ?? .data]) else { break }
            _ = try sign.trust(try Data(contentsOf: file))
            if let document = context.document { verified[document.id] = nil }
        case "untrust":
            try sign.untrust(argument)
            if let document = context.document { verified[document.id] = nil }
        default:
            break
        }
        return context.values
    }

    /// "Show what changed": the file as it was when this signature was made opens next to it.
    private func showSignedVersion(of report: SignatureReport, source: PDFSource, document: DocumentHandle) throws {
        let data = try source.bytes()
        guard let info = try PDFModel(data: data, password: source.password).signatures().first(where: { $0.fieldName == report.fieldName }),
              let length = info.revisionLength, length <= data.count else { return }
        _ = try Services.documents.openUntitled(data.prefix(length), name: SignStrings.asSigned(document.displayName))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
