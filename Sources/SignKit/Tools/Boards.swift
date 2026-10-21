import AppKit
import PDFKit
import SuperPDFCore

// What each panel has put on the pages so far: the Sign panel's signatures, initials, date, text and certificate box;
// the Request signatures panel's people and their fields. One board per open document, dropped when it closes or
// after the run that used it.

// MARK: - Sign

@MainActor
final class SignBoard: PageBoard {
    enum Mode: String { case mine, certificate }

    enum Content: Hashable {
        /// A saved signature or initials from the library.
        case saved(UUID)
        case date
        case text
        /// The visible box of a certificate signature.
        case certificate
    }

    struct Placement: Hashable {
        var id = UUID()
        var content: Content
        var page: Int
        var rect: CGRect
    }

    let document: DocumentHandle
    private let library: () -> [SavedSignature]
    var placements: [Placement] = []
    var selection: UUID?
    var mode: Mode = .mine
    /// The saved signature or initials a click places (and the handwriting in a certificate box).
    var chosen: UUID?
    var addsDate = true
    var text = ""
    /// Views that show the board (the library cards) redraw when it changes.
    var observers: [UUID: () -> Void] = [:]

    init(document: DocumentHandle, library: @escaping () -> [SavedSignature]) {
        self.document = document
        self.library = library
        chosen = library().first?.id
    }

    func changed() { Array(observers.values).forEach { $0() } }

    var boxes: [PageBox] {
        placements.filter { mode == .certificate || $0.content != .certificate }.map {
            PageBox(id: $0.id, page: $0.page, rect: $0.rect, keepsAspect: $0.content != .certificate)
        }
    }

    /// The marks and certificate box that "Sign and save…" writes in the current mode.
    var marks: [Placement] { placements.filter { $0.content != .certificate } }
    var certificateBox: Placement? { placements.first { $0.content == .certificate } }

    static let certificateSize = CGSize(width: 220, height: 60)
    static let signatureWidth: CGFloat = 180
    static let initialsHeight: CGFloat = 36

    func place(at point: CGPoint, page: Int, pdfPage: PDFPage) -> Bool {
        switch mode {
        case .certificate:
            let size = Self.certificateSize
            let rect = clamp(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), pdfPage)
            if let i = placements.firstIndex(where: { $0.content == .certificate }) {
                placements[i].page = page
                placements[i].rect = rect
                selection = placements[i].id
            } else {
                let placement = Placement(content: .certificate, page: page, rect: rect)
                placements.append(placement)
                selection = placement.id
            }
            return true
        case .mine:
            guard let chosen, let signature = library().first(where: { $0.id == chosen }), let image = Appearance.cgImage(signature.image) else { return false }
            let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            var size = signature.kind == .initials
                ? CGSize(width: Self.initialsHeight * aspect, height: Self.initialsHeight)
                : CGSize(width: Self.signatureWidth, height: min(Self.signatureWidth / aspect, 60))
            if size.height == 60 { size.width = 60 * aspect }
            var rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
            // A click inside an empty signature field (a signing package, "Sign in person") fills that field.
            if let field = pdfPage.annotations.first(where: { $0.widgetFieldType == .signature && $0.bounds.contains(point) }) {
                rect = Appearance.fit(size, in: field.bounds.insetBy(dx: 2, dy: 2))
            }
            rect = clamp(rect, pdfPage)
            let placement = Placement(content: .saved(signature.id), page: page, rect: rect)
            placements.append(placement)
            selection = placement.id
            if signature.kind == .signature && addsDate && !placements.contains(where: { $0.content == .date }) {
                let date = SignStrings.placedDate()
                let width = Appearance.lineWidth(date, size: 10) + 4
                placements.append(Placement(content: .date, page: page,
                                            rect: clamp(CGRect(x: rect.maxX - width, y: rect.minY - 18, width: width, height: 14), pdfPage)))
            }
            syncText()
            return true
        }
    }

    func update(_ id: UUID, rect: CGRect) {
        guard let i = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[i].rect = rect
    }

    func remove(_ id: UUID) { placements.removeAll { $0.id == id } }

    /// The date follows the "Add today’s date" box; typed text follows the Text field (it starts under the first
    /// signature, or in the middle of the first page).
    func sync(addsDate: Bool, text: String) {
        self.addsDate = addsDate
        if !addsDate { placements.removeAll { $0.content == .date } }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        syncText()
    }

    private func syncText() {
        guard !text.isEmpty else { placements.removeAll { $0.content == .text }; return }
        let width = Appearance.lineWidth(text, size: 12) + 6
        if let i = placements.firstIndex(where: { $0.content == .text }) {
            placements[i].rect.size.width = width
            return
        }
        let anchor = placements.first { if case .saved = $0.content { true } else { false } }
        let page = anchor?.page ?? 0
        guard let pdfPage = document.pdf.page(at: page) else { return }
        let bounds = pdfPage.bounds(for: .mediaBox)
        let rect = anchor.map { CGRect(x: $0.rect.minX, y: $0.rect.minY - 20, width: width, height: 16) }
            ?? CGRect(x: bounds.midX - width / 2, y: bounds.midY - 8, width: width, height: 16)
        placements.append(Placement(content: .text, page: page, rect: clamp(rect, pdfPage)))
    }

    private func clamp(_ rect: CGRect, _ page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .mediaBox)
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// The mark a placement draws.
    func mark(of placement: Placement) -> Mark? {
        switch placement.content {
        case .saved(let id): library().first { $0.id == id }.map { .image($0.image) }
        case .date: .text(SignStrings.placedDate())
        case .text: text.isEmpty ? nil : .text(text)
        case .certificate: nil
        }
    }

    func label(of placement: Placement) -> String {
        switch placement.content {
        case .saved(let id): library().first { $0.id == id }?.kind == .initials ? SignStrings.initialsLabel : SignStrings.signatureLabel
        case .date: SignStrings.dateLabel
        case .text: text
        case .certificate: SignStrings.signatureLabel
        }
    }
}

// MARK: - Request signatures

@MainActor
final class RequestBoard: PageBoard {
    let document: DocumentHandle
    var signers: [Signer] = []
    var fields: [RequestField] = []
    var selection: UUID?
    /// The person a click places a field for.
    var current: UUID?
    var kind: RequestFieldKind = .signature
    var observers: [UUID: () -> Void] = [:]

    /// The signer colours, in order (ux §2.3's category colours, purple and teal first as in the mockup).
    static let colors = ["#AF52DE", "#30B0C7", "#FF9500", "#007AFF", "#34C759", "#FF2D55", "#A2845E"]

    init(document: DocumentHandle) { self.document = document }

    func changed() { Array(observers.values).forEach { $0() } }

    var boxes: [PageBox] { fields.map { PageBox(id: $0.id, page: $0.page, rect: $0.rect, keepsAspect: false) } }

    static func defaultSize(_ kind: RequestFieldKind) -> CGSize {
        switch kind {
        case .signature: CGSize(width: 170, height: 34)
        case .initials: CGSize(width: 60, height: 34)
        case .date: CGSize(width: 90, height: 22)
        case .name: CGSize(width: 170, height: 22)
        case .checkbox: CGSize(width: 16, height: 16)
        }
    }

    func place(at point: CGPoint, page: Int, pdfPage: PDFPage) -> Bool {
        guard let current, signers.contains(where: { $0.id == current }) else { return false }
        let size = Self.defaultSize(kind)
        let bounds = pdfPage.bounds(for: .mediaBox)
        var rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height - RequestPackage.tabHeight)
        let field = RequestField(kind: kind, signerID: current, page: page, rect: rect)
        fields.append(field)
        selection = field.id
        changed()
        return true
    }

    func update(_ id: UUID, rect: CGRect) {
        guard let i = fields.firstIndex(where: { $0.id == id }) else { return }
        fields[i].rect = rect
    }

    func remove(_ id: UUID) {
        fields.removeAll { $0.id == id }
        changed()
    }

    func addSigner(name: String, email: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines), trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedEmail.isEmpty else { return }
        let used = Set(signers.map(\.color))
        let color = Self.colors.first { !used.contains($0) } ?? Self.colors[signers.count % Self.colors.count]
        let signer = Signer(name: trimmedName.isEmpty ? trimmedEmail : trimmedName, email: trimmedEmail, color: color, order: signers.count)
        signers.append(signer)
        if current == nil { current = signer.id }
        changed()
    }

    func removeSigner(_ id: UUID) {
        signers.removeAll { $0.id == id }
        fields.removeAll { $0.signerID == id }
        for i in signers.indices { signers[i].order = i }
        if current == id { current = signers.first?.id }
        changed()
    }

    func fieldCount(of signer: UUID) -> Int { fields.filter { $0.signerID == signer }.count }

    /// Every person has a place to sign.
    var isPlaced: Bool { !signers.isEmpty && signers.allSatisfy { fieldCount(of: $0.id) > 0 } }
}
