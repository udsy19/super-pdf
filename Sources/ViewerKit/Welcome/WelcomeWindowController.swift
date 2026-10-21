import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The welcome window (ux §6.1, welcome.png): 760 × 520, not resizable, centred. The app's mark and name, one
/// sentence, four big targets — Open a PDF, Combine files, Scan, Convert a file — and the recent files. Dropping files
/// anywhere does the obvious thing: one file opens (converted first if needed), several combine.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private unowned let viewer: Viewer
    let welcomeView: WelcomeView

    init(viewer: Viewer) {
        self.viewer = viewer
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SPMetrics.Welcome.size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = Strings.appName
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        welcomeView = WelcomeView(frame: NSRect(origin: .zero, size: SPMetrics.Welcome.size))
        window.contentView = welcomeView
        window.setContentSize(SPMetrics.Welcome.size)
        window.center()
        super.init(window: window)
        window.delegate = self
        welcomeView.controller = self
        reloadRecents()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        reloadRecents()
        guard viewer.environment.showsWindows else { return }
        super.showWindow(sender)
    }

    func reloadRecents() {
        welcomeView.recents = Services.documents?.recentDocuments ?? []
    }

    // MARK: Targets

    func openPDF() { viewer.environment.openDocumentPanel() }

    func chooseFilesToCombine() {
        Task {
            let urls = await viewer.environment.chooseFiles([], true, window)
            if urls.count == 1 { viewer.open(urls, from: window) } else if !urls.isEmpty { await combine(urls) }
        }
    }

    func scan() { Services.tools?.openPanel(.scanWithIPhone, for: nil, inputs: []) }

    func chooseFileToConvert() {
        Task {
            let urls = await viewer.environment.chooseFiles([], false, window)
            viewer.open(urls, from: window)
        }
    }

    func open(_ recent: RecentDocument) { viewer.open([recent.url], from: window) }

    func reveal(_ recent: RecentDocument) { viewer.environment.revealInFinder([recent.url]) }

    func remove(_ recent: RecentDocument) {
        Services.documents?.removeRecent(recent.url)
        reloadRecents()
    }

    func drop(_ decision: DropDecision) {
        switch decision.outcome {
        case .open(let urls): viewer.open(urls, from: window)
        case .combine(let urls): Task { await combine(urls) }
        default: break
        }
    }

    /// Several files become one new unsaved document, shown in the organiser with a column listing the files and each
    /// file's pages in its colour (ux §6.1, §6.2).
    func combine(_ urls: [URL]) async {
        guard let documents = Services.documents else { return }
        let combined = PDFDocument()
        var parts: [(range: Range<Int>, name: String)] = []
        for url in urls {
            guard let source = await Self.pdf(for: url) else { continue }
            let start = combined.pageCount
            for index in 0..<source.pageCount {
                if let page = source.page(at: index) { combined.insert(page, at: combined.pageCount) }
            }
            if combined.pageCount > start { parts.append((start..<combined.pageCount, url.lastPathComponent)) }
        }
        guard combined.pageCount > 0, let data = combined.dataRepresentation() else { return }
        do {
            let handle = try documents.openUntitled(data, name: ViewerStrings.Welcome.combinedName)
            guard let controller = viewer.controller(for: handle) else { return }
            for (offset, part) in parts.enumerated() {
                controller.pageActions.tag(part.range, as: PageOrigin(fileName: part.name, colorIndex: offset % PageOrigin.palette.count))
            }
            controller.showOrganiser(adding: [])
        } catch {
            viewer.environment.alert(error.localizedDescription, window)
        }
    }

    /// A readable PDF for a file: PDFs as they are (unlocked ones only), others through ConvertKit.
    private static func pdf(for url: URL) async -> PDFDocument? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { return nil }
            return pdf
        }
        guard let convert = Services.convert, convert.canConvertToPDF(url) else { return nil }
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let job = ConversionJob(inputs: [url], output: .pdf, destination: folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf"))
        guard let output = try? await convert.convert(job, progress: .ignored).outputs.first else { return nil }
        return PDFDocument(url: output)
    }
}

/// The welcome window's content, laid out to welcome.png: everything centred on the 760 pt window.
final class WelcomeView: NSView {
    weak var controller: WelcomeWindowController?
    var recents: [RecentDocument] = [] { didSet { layoutRecents() } }
    private(set) var targets: [WelcomeTargetView] = []
    private let recentHeader = NSTextField(labelWithString: ViewerStrings.Welcome.recent)
    private let recentScroll = NSScrollView()
    private let recentList = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: Strings.Empty.welcomeRecents)
    private let dropHighlight = DropHighlightView()

    // Positions from welcome.html: 26 pt top padding, the 56 pt mark, 28 pt title, 15 pt subtitle, 160 × 140 targets 16 pt
    // apart, "Recent" 22 pt below them, 36 pt rows.
    static let targetTop: CGFloat = 174
    static let recentTop: CGFloat = 336
    static let rowsTop: CGFloat = 359
    static var contentWidth: CGFloat { 4 * SPMetrics.Welcome.targetSize.width + 3 * 16 }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let side = ((frame.width - Self.contentWidth) / 2).rounded()
        let specs: [(String, String, String, SPColorToken, String?)] = [
            ("doc", ViewerStrings.Welcome.open, ViewerStrings.Welcome.openHint, SPColor.categoryBlue, "⌘O"),
            ("doc.on.doc", ViewerStrings.Welcome.combine, ViewerStrings.Welcome.combineHint, SPColor.categoryBlue, nil),
            ("scanner", ViewerStrings.Welcome.scan, ViewerStrings.Welcome.scanHint, SPColor.categoryBrown, nil),
            ("doc.badge.arrow.up", ViewerStrings.Welcome.convert, ViewerStrings.Welcome.convertHint, SPColor.categoryGreen, nil),
        ]
        for (index, spec) in specs.enumerated() {
            let target = WelcomeTargetView(symbol: spec.0, title: spec.1, hint: spec.2, color: spec.3, shortcut: spec.4)
            target.frame = NSRect(x: side + CGFloat(index) * (SPMetrics.Welcome.targetSize.width + 16), y: Self.targetTop,
                                  width: SPMetrics.Welcome.targetSize.width, height: SPMetrics.Welcome.targetSize.height)
            target.onPress = { [weak self] in self?.press(index) }
            addSubview(target)
            targets.append(target)
        }
        recentHeader.font = SPFont.sectionHeader.font()
        recentHeader.textColor = SPColor.secondaryLabel.color
        recentHeader.frame = NSRect(x: side, y: Self.recentTop, width: 200, height: 17)
        addSubview(recentHeader)
        recentScroll.frame = NSRect(x: side, y: Self.rowsTop, width: Self.contentWidth, height: frame.height - Self.rowsTop - 14)
        recentScroll.documentView = recentList
        recentScroll.drawsBackground = false
        recentScroll.hasVerticalScroller = true
        recentScroll.autohidesScrollers = true
        addSubview(recentScroll)
        emptyLabel.font = SPFont.body.font()
        emptyLabel.textColor = SPColor.tertiaryLabel.color
        emptyLabel.frame = NSRect(x: side + 8, y: Self.rowsTop + 9, width: Self.contentWidth, height: 18)
        addSubview(emptyLabel)
        dropHighlight.isHidden = true
        dropHighlight.frame = bounds.insetBy(dx: 6, dy: 6)
        addSubview(dropHighlight)
        registerForDraggedTypes([.fileURL])
        layoutRecents()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func press(_ index: Int) {
        switch index {
        case 0: controller?.openPDF()
        case 1: controller?.chooseFilesToCombine()
        case 2: controller?.scan()
        default: controller?.chooseFileToConvert()
        }
    }

    private func layoutRecents() {
        recentList.subviews.forEach { $0.removeFromSuperview() }
        let rowHeight = SPMetrics.Welcome.recentRowHeight
        for (index, recent) in recents.enumerated() {
            let row = RecentRowView(recent)
            row.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: Self.contentWidth, height: rowHeight)
            row.onOpen = { [weak self] in self?.controller?.open(recent) }
            row.onReveal = { [weak self] in self?.controller?.reveal(recent) }
            row.onRemove = { [weak self] in self?.controller?.remove(recent) }
            recentList.addSubview(row)
        }
        recentList.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: max(CGFloat(recents.count) * rowHeight, recentScroll.bounds.height))
        emptyLabel.isHidden = !recents.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        SPColor.windowBackground.color.setFill()
        dirtyRect.fill()
        drawMark()
        let title = NSAttributedString(string: Strings.appName, attributes: [.font: SPFont.welcomeTitle.font(), .foregroundColor: SPColor.label.color,
                                                                             .kern: -0.56])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: (bounds.width - titleSize.width) / 2, y: 92 + (36 - titleSize.height) / 2))
        let subtitle = NSAttributedString(string: ViewerStrings.Welcome.subtitle,
                                          attributes: [.font: SPFont.welcomeSubtitle.font(), .foregroundColor: SPColor.secondaryLabel.color])
        let subtitleSize = subtitle.size()
        subtitle.draw(at: NSPoint(x: (bounds.width - subtitleSize.width) / 2, y: 132 + (19.5 - subtitleSize.height) / 2))
    }

    /// The mark: a rounded blue tile with a page (welcome.png).
    private func drawMark() {
        let rect = NSRect(x: (bounds.width - 56) / 2, y: 26, width: 56, height: 56)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 80 / 255, green: 126 / 255, blue: 247 / 255, alpha: 0.35)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        NSColor(hex: "#507EF7").setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(hex: "#B6CFFB"), ending: NSColor(hex: "#507EF7"))?.draw(in: path, angle: -70)
        let symbol = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular).applying(.init(paletteColors: [.white])))
        if let symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    // MARK: Drops anywhere in the window (ux §3, §6.1)

    private func decision(_ info: NSDraggingInfo) -> DropDecision {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return DropDecision(.none) }
        let files = urls.map { DroppedFile(url: $0, canConvert: { Services.convert?.canConvertToPDF($0) ?? false }) }
        return DropDecision.decide(.files(files), onto: .welcome)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlight(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { highlight(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.isHidden = true }

    private func highlight(_ info: NSDraggingInfo) -> NSDragOperation {
        let decision = decision(info)
        switch decision.outcome {
        case .open, .combine:
            dropHighlight.label = decision.label
            dropHighlight.isRefusal = false
            dropHighlight.isHidden = false
            return .copy
        case .refuse(let reason):
            dropHighlight.label = reason
            dropHighlight.isRefusal = true
            dropHighlight.isHidden = false
            return []
        default:
            dropHighlight.isHidden = true
            return []
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight.isHidden = true
        let decision = decision(sender)
        guard decision.isAllowed else { return false }
        controller?.drop(decision)
        return true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One of the four big targets: 160 × 140, 14 pt radius, a 40 pt circle in the category colour at 15 % with its symbol,
/// the label 15 pt semibold and the hint 11 pt; hover turns the border accent and lifts it (welcome.png).
final class WelcomeTargetView: NSControl {
    private let symbol: String
    private let title: String
    private let hint: String
    private let color: SPColorToken
    private let shortcut: String?
    var onPress: (() -> Void)?
    var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, hint: String, color: SPColorToken, shortcut: String?) {
        self.symbol = symbol; self.title = title; self.hint = hint; self.color = color; self.shortcut = shortcut
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onPress?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0.5, dy: 0.5).offsetBy(dx: 0, dy: isHovered ? -SPMetrics.Tile.hoverLift : 0)
        let path = NSBezierPath(roundedRect: card, xRadius: SPMetrics.Welcome.targetRadius, yRadius: SPMetrics.Welcome.targetRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isHovered ? 0.10 : 0.05)
        shadow.shadowBlurRadius = isHovered ? 16 : 2
        shadow.shadowOffset = NSSize(width: 0, height: isHovered ? -6 : -1)
        shadow.set()
        SPColor.controlBackground.color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        path.lineWidth = 1
        (isHovered ? SPColor.accent.color : SPColor.separator.color).setStroke()
        path.stroke()

        let tint = color.color
        let circle = NSRect(x: card.minX + 14, y: card.minY + 16, width: 40, height: 40)
        tint.withAlphaComponent(SPMetrics.Tile.iconCircleOpacity).setFill()
        NSBezierPath(ovalIn: circle).fill()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: SPMetrics.Tile.symbolSize - 2, weight: .medium).applying(.init(paletteColors: [tint]))) {
            let size = image.size
            image.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width, height: size.height))
        }
        let name = NSAttributedString(string: title, attributes: [.font: SPFont.welcomeTarget.font(), .foregroundColor: SPColor.label.color])
        name.draw(at: NSPoint(x: card.minX + 14, y: circle.maxY + 12))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        paragraph.lineBreakMode = .byWordWrapping
        let hintText = NSAttributedString(string: hint, attributes: [.font: SPFont.tileHint.font(), .foregroundColor: SPColor.secondaryLabel.color,
                                                                     .paragraphStyle: paragraph])
        hintText.draw(with: NSRect(x: card.minX + 14, y: circle.maxY + 12 + 22, width: card.width - 28, height: card.maxY - circle.maxY - 34),
                      options: [.usesLineFragmentOrigin])
        if let shortcut {
            let key = NSAttributedString(string: shortcut, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: SPColor.tertiaryLabel.color])
            let size = key.size()
            key.draw(at: NSPoint(x: card.maxX - 12 - size.width, y: card.minY + 12))
        }
    }
}

/// A recent file: 36 pt, a 24 pt page picture, the name at 13 pt and when · pages · size at 11 pt; hover highlights;
/// right-click offers Show in Finder and Remove from list (ux §6.1).
final class RecentRowView: NSView {
    let recent: RecentDocument
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?
    var isHovered = false { didSet { needsDisplay = true } }
    private var picture: CGImage?

    init(_ recent: RecentDocument) {
        self.recent = recent
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(recent.name)
        RecentThumbnails.image(for: recent.url) { [weak self] image in
            self?.picture = image
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) { onOpen?() }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(ViewerStrings.Welcome.showInFinder, onReveal), (ViewerStrings.Welcome.removeFromList, onRemove)] {
            let handler = MenuAction { action?() }
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let thumb = NSRect(x: 8 + 2, y: (bounds.height - 24) / 2, width: 20, height: 24)
        NSColor.white.setFill()
        thumb.fill()
        if let picture, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: 0, y: thumb.maxY + thumb.minY)
            context.scaleBy(x: 1, y: -1)
            let aspect = CGFloat(picture.height) / CGFloat(picture.width)
            let height = min(thumb.height, thumb.width * aspect)
            context.draw(picture, in: NSRect(x: thumb.minX, y: thumb.midY - height / 2, width: thumb.width, height: height))
            context.restoreGState()
        } else {
            NSColor(white: 0.73, alpha: 1).setFill()
            for line in 0..<4 { NSRect(x: thumb.minX + 3, y: thumb.minY + 5 + CGFloat(line) * 3, width: thumb.width - 6, height: 1).fill() }
        }
        NSColor.black.withAlphaComponent(0.16).setStroke()
        NSBezierPath(rect: thumb.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let name = NSAttributedString(string: recent.name, attributes: [.font: SPFont.body.font(), .foregroundColor: SPColor.label.color])
        let metaFont = SPFont.secondary.font()
        let meta = [RecentDates.string(for: recent.lastOpened), ViewerStrings.pages(recent.pageCount), Formatting.bytes(recent.fileSize)]
        var x = bounds.width - 13
        for (index, text) in meta.enumerated().reversed() {
            let string = NSAttributedString(string: text, attributes: [.font: metaFont, .foregroundColor: SPColor.secondaryLabel.color])
            let size = string.size()
            x -= size.width
            string.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            x -= index > 0 ? 18 + 10 : 0
        }
        let nameSize = name.size()
        name.draw(with: NSRect(x: thumb.maxX + 10 + 6, y: (bounds.height - nameSize.height) / 2, width: max(0, x - thumb.maxX - 40), height: nameSize.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// "Yesterday, 4:12 PM", "Monday", "12 Sep" (welcome.png), in the person's locale.
public enum RecentDates {
    public static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        let startToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startToday).day ?? 0
        if days <= 1 {
            // DateFormatter's relative words ("Today", "Yesterday") count from the real clock, not `now`, so ask it about
            // the same distance from the real today.
            let relative = DateFormatter()
            relative.locale = locale
            relative.dateStyle = .medium
            relative.timeStyle = .none
            relative.doesRelativeDateFormatting = true
            let word = relative.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? date)
            return "\(word), \(time.string(from: date))"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        if days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        }
        return formatter.string(from: date)
    }
}

/// First-page pictures for the recents, rendered off the main thread from the file (encrypted files keep the plain icon).
@MainActor
enum RecentThumbnails {
    private static let cache = NSCache<NSURL, CGImageBox>()
    private static let queue = DispatchQueue(label: "com.udsy.superpdf.recent-thumbnails", qos: .utility)

    static func image(for url: URL, completion: @escaping @MainActor (CGImage) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) { completion(cached.image); return }
        queue.async {
            guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted, let page = document.page(at: 1) else { return }
            let box = page.getBoxRect(.cropBox)
            let width = 48
            let height = max(1, Int(CGFloat(width) * box.height / max(box.width, 1)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { return }
            let boxed = CGImageBox(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cache.setObject(boxed, forKey: url as NSURL)
                    completion(boxed.image)
                }
            }
        }
    }
}
