import AppKit
import PDFKit
import SuperPDFCore

/// Preview's markup bar (ux §6.4) under the toolbar as a titlebar accessory (31 pt as Preview's; macOS 26 gives bottom
/// accessories its own 36 pt and the items stay centred): Text Selection · Selection ▾ ·
/// Black out · Sketch · Draw · Shapes ▾ · Text · Highlight ▾ · Sign ▾ · Note ‖ Shape Style · Border Colour · Fill
/// Colour · Text Style ‖ Rotate · Crop · Form Fill ‖ Stamp ▾ · Measure ▾. The ▾ items are split buttons whose arrow
/// opens a menu; the style items open menus of Preview's choices (its colour menu: Black … Pink, No Fill, Other…).
@MainActor
final class MarkupBarView: NSView {
    unowned let session: MarkupSession
    private let stack = NSStackView()
    private var toggles: [(NSButton, (MarkupTool) -> Bool)] = []
    private var splits: [(NSSegmentedControl, () -> NSMenu, (MarkupTool) -> Bool)] = []
    private var handlers: [MenuHandler] = []
    private var shapesControl: NSSegmentedControl?
    private var borderButton: NSButton?
    private var fillButton: NSButton?

    init(session: MarkupSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: SPMetrics.MarkupBar.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Markup")
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        build()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Items

    private func build() {
        add(toggle("character.cursor.ibeam", "Text Selection", tool: .textSelection) { $0 == .textSelection })
        add(split("rectangle.dashed", "Selection Tools", isOn: { $0 == .rectangularSelection },
                  primary: { [unowned self] in session.choose(session.tool == .rectangularSelection ? .textSelection : .rectangularSelection) },
                  menu: { [unowned self] in menu([item("Rectangular Selection", on: session.tool == .rectangularSelection) { [unowned self] in
                      session.choose(.rectangularSelection) }]) }))
        add(button("text.redaction", Strings.menuTitle("Black out")) { [unowned self] in session.open(.blackOut) })
        add(toggle("scribble.variable", "Sketch", tool: .sketch) { $0 == .sketch })
        add(toggle("pencil.tip", "Draw", tool: .draw) { $0 == .draw })
        let shapes = split(ShapeKind.rectangle.symbol, "Shape Tools", isOn: { if case .shape = $0 { true } else { false } },
                           primary: { [unowned self] in session.choose(.shape(lastShape)) },
                           menu: { [unowned self] in shapesMenu() })
        shapesControl = shapes
        add(shapes)
        add(toggle("character.textbox", "Text", tool: .text) { $0 == .text })
        add(split("highlighter", "Highlight", isOn: { if case .highlight = $0 { true } else if case .correction = $0 { true } else { false } },
                  primary: { [unowned self] in session.choose(session.tool == .highlight ? .textSelection : .highlight) },
                  menu: { [unowned self] in highlightMenu() }))
        add(split("signature", "Signature", isOn: { _ in false }, primary: { [unowned self] in session.open(.sign) },
                  menu: { [unowned self] in menu([item("Add Signature…") { [unowned self] in session.open(.sign) }]) }))
        add(toggle("note.text", "Note", tool: .note) { $0 == .note })
        addSeparator()
        add(menuButton(NSImage(systemSymbolName: "lineweight", accessibilityDescription: "Shape Style"), "Shape Style") { [unowned self] in shapeStyleMenu() })
        let border = menuButton(nil, "Border Color") { [unowned self] in colorMenu(fill: false) }
        borderButton = border
        add(border)
        let fill = menuButton(nil, "Fill Color") { [unowned self] in colorMenu(fill: true) }
        fillButton = fill
        add(fill)
        add(menuButton(NSImage(systemSymbolName: "textformat", accessibilityDescription: "Text Style"), "Text Style") { [unowned self] in textStyleMenu() })
        addSeparator()
        add(button("rotate.left", "Rotate Left") { [unowned self] in session.rotateLeft() })
        add(button("crop", "Crop") { [unowned self] in session.open(.crop) })
        add(button("rectangle.and.pencil.and.ellipsis", "Form Filling") { [unowned self] in session.open(.fillForm) })
        addSeparator()
        add(split("seal", "Stamp", isOn: { if case .stamp = $0 { true } else { false } },
                  primary: { [unowned self] in session.choose(.stamp(lastStamp)) },
                  menu: { [unowned self] in stampMenu() }))
        add(split("ruler", "Measure", isOn: { if case .measure = $0 { true } else { false } },
                  primary: { [unowned self] in session.choose(.measure(lastMeasure)) },
                  menu: { [unowned self] in measureMenu() }))
    }

    private var lastShape: ShapeKind = .rectangle
    private var lastStamp: StandardStamp = .approved
    private var lastMeasure: MeasureKind = .distance

    private func add(_ view: NSView) { stack.addArrangedSubview(view) }

    private func addSeparator() {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.setCustomSpacing(8, after: line)
    }

    private func image(_ symbol: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    private func toggle(_ symbol: String, _ label: String, tool: MarkupTool, isOn: @escaping (MarkupTool) -> Bool) -> NSButton {
        let control = button(symbol, label) { [unowned self] in session.choose(session.tool == tool && tool != .textSelection ? .textSelection : tool) }
        control.setButtonType(.pushOnPushOff)
        toggles.append((control, isOn))
        return control
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        let handler = MenuHandler(action)
        handlers.append(handler)
        let control = NSButton(image: image(symbol, label), target: handler, action: #selector(MenuHandler.run))
        control.bezelStyle = .toolbar
        control.isBordered = true
        control.showsBorderOnlyWhileMouseInside = true
        control.toolTip = label
        control.setAccessibilityLabel(label)
        return control
    }

    /// A button whose click opens a menu under it.
    private func menuButton(_ image: NSImage?, _ label: String, menu: @escaping @MainActor () -> NSMenu) -> NSButton {
        var control: NSButton!
        control = button("circle", label) { menu().popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.height + 4), in: control) }
        if let image { control.image = image }
        return control
    }

    /// Preview's split buttons: the left part acts, the arrow opens the menu.
    private func split(_ symbol: String, _ label: String, isOn: @escaping (MarkupTool) -> Bool, primary: @escaping @MainActor () -> Void,
                       menu: @escaping @MainActor () -> NSMenu) -> NSSegmentedControl {
        let handler = MenuHandler(primary)
        handlers.append(handler)
        let control = NSSegmentedControl(images: [image(symbol, label)], trackingMode: .selectAny, target: handler, action: #selector(MenuHandler.run))
        control.segmentStyle = .separated
        control.setShowsMenuIndicator(true, forSegment: 0)
        control.setMenu(menu(), forSegment: 0)
        control.setToolTip(label, forSegment: 0)
        control.setAccessibilityLabel(label)
        splits.append((control, menu, isOn))
        return control
    }

    // MARK: State

    func refresh() {
        let tool = session.tool
        for (control, isOn) in toggles { control.state = isOn(tool) ? .on : .off }
        for (control, menu, isOn) in splits {
            control.setSelected(isOn(tool), forSegment: 0)
            control.setMenu(menu(), forSegment: 0)
        }
        if case .shape(let kind) = tool { lastShape = kind }
        if case .stamp(let stamp) = tool { lastStamp = stamp }
        if case .measure(let kind) = tool { lastMeasure = kind }
        shapesControl?.setImage(image(lastShape.symbol, lastShape.title), forSegment: 0)
        let style = session.style
        borderButton?.image = Self.swatch(style.stroke, filled: false)
        fillButton?.image = Self.swatch(style.fill, filled: true)
    }

    /// A colour chip for the colour buttons and menus (a slashed box for clear).
    static func swatch(_ color: MarkupColor, filled: Bool, size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let box = rect.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            if color.isClear {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: box.minX, y: box.minY))
                slash.line(to: NSPoint(x: box.maxX, y: box.maxY))
                NSColor.systemRed.setStroke()
                slash.stroke()
            } else if filled {
                color.nsColor.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.stroke()
            } else {
                color.nsColor.setStroke()
                path.lineWidth = 2.5
                path.stroke()
            }
            return true
        }
    }

    // MARK: Menus

    private func item(_ title: String, image: NSImage? = nil, on: Bool = false, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let handler = MenuHandler(action)
        let item = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        item.image = image
        item.state = on ? .on : .off
        return item
    }

    private func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    private func shapesMenu() -> NSMenu {
        menu(ShapeKind.allCases.map { kind in
            let entry = item(kind.title, image: image(kind.symbol, kind.title), on: session.tool == .shape(kind)) { [unowned self] in session.choose(.shape(kind)) }
            if let combo = MarkupKitStrings.shortcut(for: kind) { entry.keyEquivalent = combo.key; entry.keyEquivalentModifierMask = combo.modifiers.flags }
            return entry
        })
    }

    private func highlightMenu() -> NSMenu {
        let style = session.style
        var items = HighlightColor.allCases.map { color in
            item(color.title, image: Self.swatch(MarkupColor(color.color), filled: true), on: style.textMarkup == .highlight(color)) { [unowned self] in
                session.restyle("Highlight Style") { $0.textMarkup = .highlight(color) }
                session.choose(.highlight)
            }
        }
        items.append(.separator())
        items.append(item("Underline", on: style.textMarkup == .underline) { [unowned self] in
            session.restyle("Highlight Style") { $0.textMarkup = .underline }
            session.choose(.highlight)
        })
        items.append(item("Strikethrough", on: style.textMarkup == .strikethrough) { [unowned self] in
            session.restyle("Highlight Style") { $0.textMarkup = .strikethrough }
            session.choose(.highlight)
        })
        items.append(.separator())
        items += CorrectionKind.allCases.map { kind in
            item(kind.title, on: session.tool == .correction(kind)) { [unowned self] in session.choose(.correction(kind)) }
        }
        return menu(items)
    }

    private func stampMenu() -> NSMenu {
        var items = StandardStamp.allCases.map { stamp in
            item(stamp.title, on: session.tool == .stamp(stamp)) { [unowned self] in session.choose(.stamp(stamp)) }
        }
        items.append(.separator())
        items.append(item("More Stamps…") { [unowned self] in session.open(.stamps) })
        return menu(items)
    }

    private func measureMenu() -> NSMenu {
        var items = MeasureKind.allCases.map { kind in
            item(kind.title, on: session.tool == .measure(kind)) { [unowned self] in session.choose(.measure(kind)) }
        }
        items.append(.separator())
        items.append(item("Set Scale…") { [unowned self] in session.open(.measure) })
        return menu(items)
    }

    private func shapeStyleMenu() -> NSMenu {
        let style = session.style
        var items = MarkupPalette.lineWidths.map { width in
            item(MarkupKitStrings.points(width), image: Self.lineImage(width), on: style.lineWidth == width) { [unowned self] in
                session.restyle("Border Line Width") { $0.lineWidth = width }
            }
        }
        items.append(.separator())
        items.append(item("Dashed Line", on: style.dashed) { [unowned self] in session.restyle("Border Dashed") { $0.dashed.toggle() } })
        items.append(.separator())
        let arrows: [(String, Bool, Bool)] = [("Arrowhead at End", false, true), ("Arrowhead at Start", true, false), ("Arrowheads at Both Ends", true, true)]
        for (title, start, end) in arrows {
            items.append(item(title, on: style.arrowAtStart == start && style.arrowAtEnd == end) { [unowned self] in
                session.restyle("Arrow Style") { $0.arrowAtStart = start; $0.arrowAtEnd = end }
            })
        }
        return menu(items)
    }

    private func colorMenu(fill: Bool) -> NSMenu {
        let style = session.style
        let current = fill ? style.fill : style.stroke
        var items: [NSMenuItem] = []
        if fill {
            items.append(item("No Fill", image: Self.swatch(.clear, filled: true), on: current.isClear) { [unowned self] in
                session.restyle("Fill Color") { $0.fill = .clear }
            })
        }
        items += MarkupPalette.colors.map { name, color in
            item(name, image: Self.swatch(color, filled: true), on: current == color) { [unowned self] in
                session.restyle(fill ? "Fill Color" : "Color") { if fill { $0.fill = color } else { $0.stroke = color } }
            }
        }
        items.append(.separator())
        items.append(item("Other…") { [unowned self] in ColorPanelBridge.shared.show(current) { [unowned self] picked in
            session.restyle(fill ? "Fill Color" : "Color") { if fill { $0.fill = picked } else { $0.stroke = picked } }
        } })
        return menu(items)
    }

    private func textStyleMenu() -> NSMenu {
        let style = session.style
        let fonts = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fonts.submenu = menu(MarkupPalette.fonts.map { name in
            let entry = item(NSFont(name: name, size: 13)?.displayName ?? name, on: style.fontName == name) { [unowned self] in
                session.restyle("Font") { $0.fontName = name }
            }
            if let font = NSFont(name: name, size: 13) { entry.attributedTitle = NSAttributedString(string: entry.title, attributes: [.font: font]) }
            return entry
        })
        let sizes = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizes.submenu = menu(MarkupPalette.fontSizes.map { size in
            item(MarkupKitStrings.points(size), on: style.fontSize == size) { [unowned self] in session.restyle("Font") { $0.fontSize = size } }
        })
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colors.submenu = menu(MarkupPalette.colors.map { name, color in
            item(name, image: Self.swatch(color, filled: true), on: style.textColor == color) { [unowned self] in
                session.restyle("Color") { $0.textColor = color }
            }
        })
        var items = [fonts, sizes, colors, .separator()]
        items += MarkupTextAlignment.allCases.map { alignment in
            item(alignment.title, on: style.alignment == alignment) { [unowned self] in
                session.restyle("Text Annotation Alignment") { $0.alignment = alignment }
            }
        }
        return menu(items)
    }

    static func lineImage(_ width: Double) -> NSImage {
        NSImage(size: NSSize(width: 36, height: 14), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = CGFloat(min(width, 10))
            path.move(to: NSPoint(x: 2, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.midY))
            path.stroke()
            return true
        }
    }
}

/// A target for controls and menu items that runs a closure.
@MainActor
final class MenuHandler: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// "Other…": the system colour panel, reporting the colour picked.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var picked: ((MarkupColor) -> Void)?

    func show(_ color: MarkupColor, picked: @escaping (MarkupColor) -> Void) {
        self.picked = picked
        let panel = NSColorPanel.shared
        panel.color = color.nsColor
        panel.showsAlpha = true
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { picked?(MarkupColor(panel.color)) }
}

extension MarkupTextAlignment {
    var title: String {
        switch self {
        case .left: "Align Left"
        case .center: "Center"
        case .right: "Align Right"
        }
    }
}
