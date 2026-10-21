import AppKit
import SuperPDFCore

// The Sign panel's own views (ux §5.3, panel-sign.png): the saved signatures as big cards (Preview's library) and the
// look of a certificate signature. Both host the page editor while they are shown, so the document takes clicks.

/// The library: one card per saved signature or initials, the chosen one ringed in the accent colour with a check.
@MainActor
final class LibraryCards: NSView {
    private let board: SignBoard
    private let sign: SignService
    private let observer = UUID()
    private var items: [SavedSignature] = []

    static let cardHeight: CGFloat = 84
    static let gap: CGFloat = 14

    init(board: SignBoard, sign: SignService) {
        self.board = board
        self.sign = sign
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 0))
        reload()
        let id = observer
        board.observers[id] = { [weak self, weak board] in
            guard let self else { board?.observers[id] = nil; return }
            self.reload()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(SignStrings.mySignature)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func reload() {
        let all = sign.savedSignatures
        items = all.filter { $0.kind == .signature } + all.filter { $0.kind == .initials }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: items.isEmpty ? 0 : CGFloat(items.count) * (Self.cardHeight + Self.gap) - Self.gap)
    }

    private func card(_ index: Int) -> NSRect {
        NSRect(x: 1, y: CGFloat(index) * (Self.cardHeight + Self.gap) + 1, width: bounds.width - 2, height: Self.cardHeight - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, item) in items.enumerated() {
            let box = card(i)
            let chosen = item.id == board.chosen
            let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            path.lineWidth = chosen ? 2 : 1
            (chosen ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            if let image = NSImage(data: item.image) {
                let area = NSRect(x: box.minX + 20, y: box.minY + 10, width: box.width - 40, height: box.height - 30)
                let fitted = Appearance.fit(image.size, in: area)
                image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let caption = item.kind == .initials ? SignStrings.initials : SignStrings.savedOnThisMac
            (caption as NSString).draw(at: NSPoint(x: box.minX + 16, y: box.maxY - 20),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
            if chosen {
                let badge = NSRect(x: box.maxX - 30, y: box.minY + 10, width: 20, height: 20)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: badge).fill()
                if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) {
                    let tinted = NSImage(size: check.size, flipped: false) { rect in
                        check.draw(in: rect)
                        NSColor.white.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: Appearance.fit(check.size, in: badge.insetBy(dx: 5, dy: 5)))
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = items.indices.first(where: { card($0).contains(point) }) else { return }
        board.chosen = items[index].id
        needsDisplay = true
        board.announce()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = items.indices.first(where: { card($0).contains(point) }) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: SignStrings.deleteSignature, action: #selector(deleteSignature(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = items[index].id
        menu.addItem(item)
        return menu
    }

    @objc private func deleteSignature(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        try? sign.delete(id)
        board.placements.removeAll { $0.content == .saved(id) }
        if board.chosen == id { board.chosen = sign.savedSignatures.first?.id }
        board.changed()
        board.announce()
    }
}

/// The certificate signature as it will look (ux §5.3 "appearance preview").
@MainActor
final class SealPreview: NSView {
    private let seal: SealAppearance

    init(seal: SealAppearance) {
        self.seal = seal
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 84))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(seal.lines.joined(separator: ", "))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 84) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = SignBoard.certificateSize
        Appearance.drawSeal(seal, in: Appearance.fit(size, in: box.insetBy(dx: 12, dy: 8)), context: context)
    }
}
