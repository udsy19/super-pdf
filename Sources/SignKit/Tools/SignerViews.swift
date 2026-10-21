import AppKit
import Contacts
import ContactsUI
import SuperPDFCore

// Request signatures' people (ux §5.3, panel-request-signatures.png): step 1 adds them (typed, or picked from
// Contacts), step 2 shows them as rows to choose whose field a click places, with their colour and field count.

/// One person as the mockup draws them: a colour circle with initials, the name, the email, and on the right either
/// the field count or a remove button.
@MainActor
final class SignerRow: NSView {
    private let signer: Signer
    private let detail: String?
    private let isChosen: Bool
    var onClick: (() -> Void)?
    private var removeButton: NSButton?

    static let height: CGFloat = 44

    init(signer: Signer, detail: String?, isChosen: Bool, onRemove: (() -> Void)?) {
        self.signer = signer
        self.detail = detail
        self.isChosen = isChosen
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.height))
        if let onRemove {
            let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: SignStrings.removePerson)!,
                                  target: nil, action: nil)
            button.isBordered = false
            button.contentTintColor = .tertiaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = #selector(remove)
            addSubview(button)
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                                         button.centerYAnchor.constraint(equalTo: centerYAnchor)])
            removeButton = button
            removal = onRemove
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([signer.name, signer.email, detail].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var removal: (() -> Void)?
    @objc private func remove() { removal?() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(hex: signer.color)
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        (isChosen ? color.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        path.lineWidth = isChosen ? 1.5 : 1
        (isChosen ? color : NSColor.separatorColor).setStroke()
        path.stroke()
        let avatar = NSRect(x: 10, y: box.midY - 13, width: 26, height: 26)
        color.setFill()
        NSBezierPath(ovalIn: avatar).fill()
        let initials = signer.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let initialsAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let size = (initials as NSString).size(withAttributes: initialsAttributes)
        (initials as NSString).draw(at: NSPoint(x: avatar.midX - size.width / 2, y: avatar.midY - size.height / 2), withAttributes: initialsAttributes)
        let right = removeButton == nil ? box.maxX - 12 : box.maxX - 34
        var textRight = right
        if let detail {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            let width = (detail as NSString).size(withAttributes: attributes).width
            (detail as NSString).draw(at: NSPoint(x: right - width, y: box.midY - 7), withAttributes: attributes)
            textRight = right - width - 8
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (signer.name as NSString).draw(in: NSRect(x: 46, y: box.minY + 5, width: textRight - 46, height: 17),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .paragraphStyle: style,
                                                        .foregroundColor: NSColor.labelColor])
        (signer.email as NSString).draw(in: NSRect(x: 46, y: box.minY + 22, width: textRight - 46, height: 15),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: style,
                                                         .foregroundColor: NSColor.secondaryLabelColor])
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Step 1 "Who": the people so far, then name and email fields with Add person, and Add from Contacts….
@MainActor
final class SignerEditor: NSStackView, NSTextFieldDelegate, CNContactPickerDelegate {
    private let board: RequestBoard
    private let rows = NSStackView()
    private let nameField = NSTextField()
    private let emailField = NSTextField()
    private let observer = UUID()
    private var picker: CNContactPicker?

    init(board: RequestBoard) {
        self.board = board
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
        orientation = .vertical
        alignment = .leading
        spacing = 10
        rows.orientation = .vertical
        rows.spacing = 8
        for (field, placeholder) in [(nameField, SignStrings.namePlaceholder), (emailField, SignStrings.emailAddressPlaceholder)] {
            field.placeholderString = placeholder
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        emailField.setAccessibilityLabel(SignStrings.email)
        nameField.setAccessibilityLabel(SignStrings.name)
        let add = NSButton(title: SignStrings.addPerson, target: self, action: #selector(addPerson))
        let contacts = NSButton(title: SignStrings.addFromContacts, target: self, action: #selector(pickContact(_:)))
        for button in [add, contacts] { button.bezelStyle = .rounded; button.controlSize = .regular }
        let buttons = NSStackView(views: [add, contacts])
        buttons.spacing = 8
        for view in [rows, nameField, emailField, buttons] as [NSView] { addArrangedSubview(view) }
        for view in [rows, nameField, emailField] as [NSView] {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        reload()
        let id = observer
        board.observers[id] = { [weak self, weak board] in
            guard let self else { board?.observers[id] = nil; return }
            self.reload()
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    private func reload() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for signer in board.signers {
            let row = SignerRow(signer: signer, detail: nil, isChosen: false) { [weak self] in
                self?.board.removeSigner(signer.id)
                self?.board.announce()
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        invalidateIntrinsicContentSize()
    }

    @objc private func addPerson() {
        board.addSigner(name: nameField.stringValue, email: emailField.stringValue)
        nameField.stringValue = ""
        emailField.stringValue = ""
        window?.makeFirstResponder(nameField)
        board.announce()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(insertNewline(_:)) else { return false }
        if control === nameField { window?.makeFirstResponder(emailField) } else { addPerson() }
        return true
    }

    /// Contacts' own picker (no Contacts permission needed: the person picks, we get only that email).
    @objc private func pickContact(_ sender: NSButton) {
        let picker = CNContactPicker()
        picker.displayedKeys = [CNContactEmailAddressesKey]
        picker.delegate = self
        picker.showRelative(to: sender.bounds, of: sender, preferredEdge: .maxY)
        self.picker = picker
    }

    nonisolated func contactPicker(_ picker: CNContactPicker, didSelect contactProperty: CNContactProperty) {
        let name = CNContactFormatter.string(from: contactProperty.contact, style: .fullName) ?? ""
        let email = contactProperty.value as? String ?? ""
        MainActor.assumeIsolated {
            board.addSigner(name: name, email: email)
            board.announce()
        }
    }

    nonisolated func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let email = (contact.isKeyAvailable(CNContactEmailAddressesKey) ? contact.emailAddresses.first?.value as String? : nil) ?? ""
        MainActor.assumeIsolated {
            board.addSigner(name: name, email: email)
            board.announce()
        }
    }
}

/// Step 2 "Where": the people as rows; the chosen one is whose field a click on the page places.
@MainActor
final class SignerPicker: NSStackView {
    private let board: RequestBoard
    private let observer = UUID()

    init(board: RequestBoard) {
        self.board = board
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        orientation = .vertical
        spacing = 14
        reload()
        let id = observer
        board.observers[id] = { [weak self, weak board] in
            guard let self else { board?.observers[id] = nil; return }
            self.reload()
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    private func reload() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for signer in board.signers {
            let row = SignerRow(signer: signer, detail: SignStrings.fields(board.fieldCount(of: signer.id)), isChosen: signer.id == board.current,
                                onRemove: nil)
            row.onClick = { [weak self] in
                self?.board.current = signer.id
                self?.board.changed()
                self?.board.announce()
            }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        invalidateIntrinsicContentSize()
    }
}
