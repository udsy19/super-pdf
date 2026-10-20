import AppKit
import CoreText
import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

// Crop, Number pages and Resize pages (features #28–#31; ux §5.3): tools that change how pages are laid out.
extension PagesTools {
    // MARK: Crop (C)

    static let millimetre = 72 / 25.4

    /// The margins to take off, in points, as people see the page.
    static func cropInsets(_ values: ToolValues) -> Insets {
        let unit = values.string(Key.unit, default: "pt") == "mm" ? millimetre : 1
        return Insets(top: Double(values.int(Key.top)) * unit, left: Double(values.int(Key.left)) * unit,
                      bottom: Double(values.int(Key.bottom)) * unit, right: Double(values.int(Key.right)) * unit)
    }

    static let cropBoxes: [(id: String, title: String, box: PDFDisplayBox)] = [
        ("crop", PagesStrings.cropBox, .cropBox), ("trim", PagesStrings.trimBox, .trimBox),
        ("bleed", PagesStrings.bleedBox, .bleedBox), ("art", PagesStrings.artBox, .artBox),
    ]

    func cropPanel(_ context: ToolContext) -> ToolPanel {
        let side = { (id: String, label: String) in ToolControl.stepper(id: id, label: label, range: 0...5000, value: 0) }
        return ToolPanel(.livePreview, notice: PagesStrings.cropNotice, showsScope: true, controls: [
            .scope,
            .action(id: Action.whiteMargins, title: PagesStrings.removeWhiteMargins, isDestructive: false, symbol: "crop"),
            .moreOptions,
        ], moreOptions: [
            .popup(id: Key.unit, label: PagesStrings.units, options: [ToolOption("pt", PagesStrings.points), ToolOption("mm", PagesStrings.millimetres)],
                   selected: "pt"),
            side(Key.top, PagesStrings.top), side(Key.left, PagesStrings.left), side(Key.bottom, PagesStrings.bottom), side(Key.right, PagesStrings.right),
            .popup(id: Key.box, label: PagesStrings.box, options: Self.cropBoxes.map { ToolOption($0.id, $0.title) }, selected: "crop"),
        ], primary: ToolButton(PagesStrings.crop, isEnabled: !Self.cropInsets(context.values).isZero && !scopePages(context).isEmpty))
    }

    func cropPreview(_ context: ToolContext) -> ToolPreview {
        let insets = Self.cropInsets(context.values)
        guard !insets.isZero, let pdf = context.document?.pdf else { return .none }
        let targets = Set(scopePages(context))
        return .overlay { page, cg in
            guard page.document === pdf, targets.contains(pdf.index(for: page)) else { return }
            let bounds = page.bounds(for: .cropBox)
            guard let kept = CropMath.crop(bounds, insets: insets, rotation: page.rotation)?.offsetBy(dx: -bounds.minX, dy: -bounds.minY) else { return }
            let whole = CGRect(origin: .zero, size: bounds.size)
            cg.saveGState()
            cg.addRect(whole); cg.addRect(kept)
            cg.setFillColor(CGColor(gray: 0, alpha: 0.35))
            cg.fillPath(using: .evenOdd)
            cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
            cg.setLineWidth(1.5)
            cg.stroke(kept)
            cg.restoreGState()
        }
    }

    func runCrop(_ request: ToolRequest) throws -> ToolResult {
        let document = try document(request)
        let insets = Self.cropInsets(request.values)
        let boxID = request.values.string(Key.box, default: "crop")
        let box = Self.cropBoxes.first { $0.id == boxID }?.box ?? .cropBox
        let pages = request.pages.compactMap { document.pdf.page(at: $0) }
        var changes: [(page: PDFKit.PDFPage, before: CGRect, after: CGRect)] = []
        for page in pages {
            guard let kept = CropMath.crop(page.bounds(for: .cropBox), insets: insets, rotation: page.rotation) else {
                throw ToolError(PagesStrings.cropsEverything)
            }
            changes.append((page, page.bounds(for: box), kept))
        }
        let set = { (after: Bool) in for change in changes { change.page.setBounds(after ? change.after : change.before, for: box) } }
        set(true)
        return .inPlace(undoable: UndoGroup(PagesStrings.Undo.crop, undo: { set(false) }, redo: { set(true) }), banner: nil)
    }

    /// "Remove white margins": the white every chosen page shares, put into the margin fields.
    func removeWhiteMargins(_ context: ToolContext) async throws -> ToolValues {
        guard let document = context.document else { return context.values }
        let source = document.snapshot(), pages = scopePages(context)
        guard let found = try await Task.detached(operation: { try PageEngine.sharedWhiteMargins(source, pages: pages) }).value, !found.isZero else {
            throw ToolError(PagesStrings.noWhiteMargins)
        }
        var values = context.values
        let unit = values.string(Key.unit, default: "pt") == "mm" ? Self.millimetre : 1
        for (key, points) in [(Key.top, found.top), (Key.left, found.left), (Key.bottom, found.bottom), (Key.right, found.right)] {
            values[key] = .int(Int((points / unit).rounded(.down)))
        }
        return values
    }

    // MARK: Number pages (C)

    static let numberPositions: [PagePosition] = [.topLeft, .topCenter, .topRight, .bottomLeft, .bottomCenter, .bottomRight]
    static let numberStyles: [(style: PageNumberStyle, title: String)] = [
        (.plain, "1"), (.page, "Page 1"), (.pageOfTotal, "Page 1 of 12"), (.dashed, "– 1 –"), (.roman, "i, ii"), (.prefixed, "A-1"),
    ]

    static func numbering(_ values: ToolValues) -> PageNumbering {
        let position = numberPositions[min(max(values.int(Key.position, default: 4), 0), numberPositions.count - 1)]
        let style = PageNumberStyle(rawValue: values.string(Key.style, default: PageNumberStyle.plain.rawValue)) ?? .plain
        return PageNumbering(position: position, style: style, startAt: values.int(Key.start, default: 1), skipFirst: values.int(Key.skip),
                             text: DecorationStyle(fontSize: Double(values.int(Key.fontSize, default: 10))))
    }

    func numberPanel(_ context: ToolContext) -> ToolPanel {
        let pages = scopePages(context)
        return ToolPanel(.livePreview, showsScope: true, controls: [
            .positionGrid(id: Key.position, columns: 3, rows: 2, selected: 4),
            .popup(id: Key.style, label: PagesStrings.style, options: Self.numberStyles.map { ToolOption($0.style.rawValue, $0.title) },
                   selected: PageNumberStyle.plain.rawValue),
            .stepper(id: Key.start, label: PagesStrings.startAt, range: 1...99_999, value: 1),
            .scope,
        ], moreOptions: [
            .stepper(id: Key.skip, label: PagesStrings.skipFirst, range: 0...max(pages.count - 1, 0), value: 0),
            .stepper(id: Key.fontSize, label: PagesStrings.size, range: 6...72, value: 10),
            .toggle(id: Key.labels, label: PagesStrings.pageLabels, isOn: false),
        ], primary: ToolButton(PagesStrings.addNumbers, isEnabled: pages.count > context.values.int(Key.skip)))
    }

    /// The text each numbered page shows, by page index: the scope's pages after the skipped ones, counting from "Start at".
    static func numberTexts(_ numbering: PageNumbering, pages: [Int]) -> [Int: String] {
        let numbered = pages.sorted().dropFirst(numbering.skipFirst)
        let total = numbering.startAt - 1 + numbered.count
        return Dictionary(uniqueKeysWithValues: numbered.enumerated().map { k, index in
            (index, numbering.style.text(numbering.startAt + k, of: total))
        })
    }

    func numberPreview(_ context: ToolContext) -> ToolPreview {
        guard let pdf = context.document?.pdf else { return .none }
        let numbering = Self.numbering(context.values)
        let texts = Self.numberTexts(numbering, pages: scopePages(context))
        let margin = HeaderFooter(fields: [:]).margins
        return .overlay { page, cg in
            guard page.document === pdf, let text = texts[pdf.index(for: page)] else { return }
            let size = page.bounds(for: .cropBox).size
            let font = CTFontCreateWithName(numbering.text.fontName as CFString, numbering.text.fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.controlAccentColor.cgColor]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x: Double = switch numbering.position {
            case .topLeft, .bottomLeft: margin
            case .topRight, .bottomRight: size.width - margin - width
            default: (size.width - width) / 2
            }
            let top = [PagePosition.topLeft, .topCenter, .topRight].contains(numbering.position)
            cg.saveGState()
            cg.textPosition = CGPoint(x: x, y: top ? size.height - margin - numbering.text.fontSize : margin)
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
    }

    /// Page labels that match the numbers (features #31): the pages before the first numbered one as i, ii…, then the
    /// numbers from "Start at" in the style's label form.
    static func labelRanges(_ numbering: PageNumbering, firstNumbered: Int) -> [PDFPageLabelRange] {
        let range: PDFPageLabelRange = switch numbering.style {
        case .roman: PDFPageLabelRange(startPage: firstNumbered, style: .lowerRoman, firstNumber: numbering.startAt)
        case .prefixed: PDFPageLabelRange(startPage: firstNumbered, style: .decimal, prefix: "A-", firstNumber: numbering.startAt)
        default: PDFPageLabelRange(startPage: firstNumbered, style: .decimal, firstNumber: numbering.startAt)
        }
        return firstNumbered > 0 ? [PDFPageLabelRange(startPage: 0, style: .lowerRoman), range] : [range]
    }

    func runNumbers(_ request: ToolRequest) async throws -> ToolResult {
        let document = try document(request)
        let numbering = Self.numbering(request.values)
        let pages = request.pages.sorted()
        guard pages.count > numbering.skipFirst else { throw ToolError(PageEditError.pagesOutOfRange.errorDescription ?? "") }
        let before = try request.source?.bytes() ?? document.snapshot().bytes()
        let group = try await Services.edit.apply(.pageNumbers(numbering), to: pages, in: document, replacing: true)
        guard request.values.bool(Key.labels) else { return .inPlace(undoable: group, banner: nil) }
        // The numbers and the labels as one step: the bytes after the numbers, with the labels set by QPDF.
        let numbered: Data = switch group.change {
        case .contents(_, let after): after
        case .actions: document.pdf.dataRepresentation() ?? before
        }
        let ranges = Self.labelRanges(numbering, firstNumbered: pages[numbering.skipFirst])
        let password = document.password
        let labelled = try await Task.detached { try PageEngine.setPageLabels(ranges, in: numbered, password: password) }.value
        return .inPlace(undoable: UndoGroup(PagesStrings.Undo.number, .contents(before: before, after: labelled)), banner: nil)
    }

    // MARK: Resize pages (B)

    func resizePanel(_ context: ToolContext) -> ToolPanel {
        let pages = scopePages(context)
        return ToolPanel(.presetAndMore, showsScope: true, controls: [
            .radio(id: Key.paper, options: [
                ToolOption("a4", "A4", detail: PagesStrings.a4Detail), ToolOption("letter", "Letter", detail: PagesStrings.letterDetail),
                ToolOption("custom", PagesStrings.customSize, detail: PagesStrings.customDetail),
            ], selected: Self.localPaper),
            .popup(id: Key.fit, label: PagesStrings.fit, options: [ToolOption("scale", PagesStrings.scaleToFit), ToolOption("pad", PagesStrings.addSpace)],
                   selected: "scale"),
            .scope,
        ], moreOptions: [
            .stepper(id: Key.width, label: PagesStrings.width, range: 25...5000, value: 210),
            .stepper(id: Key.height, label: PagesStrings.height, range: 25...5000, value: 297),
        ], primary: ToolButton(PagesStrings.resize(pages.count), isEnabled: !pages.isEmpty))
    }

    static func resizePaper(_ values: ToolValues) -> CGSize {
        switch values.string(Key.paper, default: localPaper) {
        case "letter": PaperSize.letter.size!
        case "custom": CGSize(width: Double(values.int(Key.width, default: 210)) * millimetre, height: Double(values.int(Key.height, default: 297)) * millimetre)
        default: PaperSize.a4.size!
        }
    }

    func runResize(_ request: ToolRequest) async throws -> ToolResult {
        let document = try document(request)
        let source = request.source ?? document.snapshot()
        let pages = request.pages, paper = Self.resizePaper(request.values), padOnly = request.values.string(Key.fit) == "pad"
        let (before, after) = try await Task.detached { () throws -> (Data, Data) in
            (try source.bytes(), try PageEngine.resize(source, pages: pages, paper: paper, padOnly: padOnly))
        }.value
        return .inPlace(undoable: UndoGroup(PagesStrings.Undo.resize, .contents(before: before, after: after)), banner: nil)
    }
}
