import AppKit
import SuperPDFCore

// Certificates & signatures (ux §5.3): the signatures in this file with what they mean, the person's certificates and
// "People I trust". Rows are drawn plainly; their buttons send actions to the panel (`ToolPanel.performActionNotification`).

/// A list of rows: an icon, a title, up to two lines under it, and an optional button on the right.
@MainActor
final class InfoRows: NSStackView {
    struct Row {
        var symbol: String
        var tint: NSColor
        var title: String
        var lines: [String]
        var button: (title: String, action: String)?
    }

    private let document: DocumentHandle?

    init(rows: [Row], document: DocumentHandle?) {
        self.document = document
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        orientation = .vertical
        alignment = .leading
        spacing = 12
        for row in rows {
            let view = make(row)
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    private func make(_ row: Row) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = row.tint
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title] + row.lines.map { line in
            let label = NSTextField(labelWithString: line)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label
        })
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for view in text.arrangedSubviews { view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        var views: [NSView] = [icon, text]
        if let button = row.button {
            let control = ActionButton(title: button.title, action: button.action, document: document)
            views.append(control)
        }
        let line = NSStackView(views: views)
        line.alignment = .top
        line.spacing = 10
        return line
    }
}

/// A bordered button that sends its action to the document's open panel.
@MainActor
final class ActionButton: NSButton {
    private let actionID: String
    private weak var document: DocumentHandle?

    init(title: String, action: String, document: DocumentHandle?) {
        actionID = action
        self.document = document
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11)
        target = self
        self.action = #selector(send)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func send() {
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document, userInfo: [ToolPanel.actionKey: actionID])
    }
}

enum CertificateRows {
    static func reports(_ reports: [SignatureReport]) -> [InfoRows.Row] {
        reports.enumerated().map { index, report in
            let ok = report.validity == .valid && !report.changedAfterSigning
            var lines: [String] = []
            if let date = report.signedAt { lines.append(SignStrings.signed(date)) }
            lines.append(status(report))
            if report.chain.count > 1 { lines.append(report.chain.joined(separator: " › ")) }
            let button: (String, String)? = switch report.validity {
            case .untrusted: (SignStrings.trustThisPerson, "trust.\(index)")
            case .modified: (Strings.Errors.showWhatChanged, "changed.\(index)")
            default: report.changedAfterSigning ? (Strings.Errors.showWhatChanged, "changed.\(index)") : nil
            }
            return InfoRows.Row(symbol: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", tint: ok ? .systemGreen : .systemOrange,
                                title: report.signerName, lines: lines, button: button)
        }
    }

    static func status(_ report: SignatureReport) -> String {
        switch report.validity {
        case .valid: report.changedAfterSigning ? SignStrings.changedLater : SignStrings.valid
        case .untrusted: report.changedAfterSigning ? SignStrings.changedLater : SignStrings.untrusted
        case .modified: SignStrings.modified
        case .invalid: SignStrings.invalid
        }
    }

    static func identities(_ identities: [SigningIdentity]) -> [InfoRows.Row] {
        identities.map { identity in
            InfoRows.Row(symbol: "person.text.rectangle", tint: .controlAccentColor, title: identity.commonName,
                         lines: [identity.email, SignStrings.validUntil(identity.notAfter)].compactMap { $0 },
                         button: (SignStrings.exportCertificate, "export.\(identity.id)"))
        }
    }

    static func trusted(_ certificates: [TrustedCertificate]) -> [InfoRows.Row] {
        certificates.map { certificate in
            InfoRows.Row(symbol: "person.crop.circle.badge.checkmark", tint: .systemGreen, title: certificate.commonName,
                         lines: [certificate.email].compactMap { $0 }, button: (SignStrings.remove, "untrust.\(certificate.id)"))
        }
    }
}
