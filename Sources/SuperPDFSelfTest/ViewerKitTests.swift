import AppKit
import CoreText
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers
import ToolsKit
@testable import ViewerKit

// ViewerKit's checks (WP4): the drop-target table of ux §3, the page grid model behind the sidebar and the workspace
// (reorder, multi-select, files mixed in), read-aloud sentences, recent-file dates, the window's metrics against ux §2.1
// and the mockups, page edits through the thumbnails and the menus, the in-window password prompt, ViewerKit's two
// tiles, the workspace (Combine with files converting on their cards, select, rotate, duplicate, sort, preview, Finish),
// offscreen renders of the main window, the result banner, the workspace and the welcome window, and the
// performance budgets on a 500-page document. Windows are made but never shown; nothing is spoken; no panel opens.
//
// Renders go to the scratch folder, or to $SUPERPDF_RENDERS when it is set (to look at them next to docs/mockups).
func registerViewerKitTests() {
    SelfTest.cases.append(("ViewerKit.dropDecisions", { viewerKitDropDecisions() }))
    SelfTest.cases.append(("ViewerKit.pageGridModel", { viewerKitPageGridModel() }))
    SelfTest.cases.append(("ViewerKit.workspaceModel", { viewerKitWorkspaceModel() }))
    SelfTest.cases.append(("ViewerKit.workspace", { viewerKitWorkspace() }))
    SelfTest.cases.append(("ViewerKit.sentences", { viewerKitSentences() }))
    SelfTest.cases.append(("ViewerKit.recentDates", { viewerKitRecentDates() }))
    SelfTest.cases.append(("ViewerKit.window", { viewerKitWindow() }))
    SelfTest.cases.append(("ViewerKit.pageEdits", { viewerKitPageEdits() }))
    SelfTest.cases.append(("ViewerKit.lockedPrompt", { viewerKitLockedPrompt() }))
    SelfTest.cases.append(("ViewerKit.tools", { viewerKitTools() }))
    SelfTest.cases.append(("ViewerKit.cropHandles", { viewerKitCropHandles() }))
    SelfTest.cases.append(("ViewerKit.thumbnailMarkup", { viewerKitThumbnailMarkup() }))
    SelfTest.cases.append(("ViewerKit.renders", { viewerKitRenders() }))
    SelfTest.cases.append(("ViewerKit.performance", { viewerKitPerformance() }))
}

// MARK: - Fixtures

/// Fakes everywhere, the real viewer, and an environment that shows nothing and writes no defaults.
@MainActor
private func installViewer() -> (documents: FakeDocuments, alerts: AlertLog) {
    _ = NSApplication.shared
    installFakes()
    let alerts = AlertLog()
    var environment = ViewerEnvironment()
    environment.persistsWindowState = false
    environment.animates = false
    environment.showsWindows = false
    environment.alert = { message, _ in alerts.messages.append(message) }
    environment.chooseFiles = { _, _, _ in [] }
    environment.share = { _, _ in }
    environment.revealInFinder = { _ in }
    environment.openDocumentPanel = {}
    Viewer.shared.environment = environment
    ViewerKitModule.install()
    (Services.tools as? FakeTools)?.collect()
    return (Services.documents as! FakeDocuments, alerts)
}

@MainActor
private final class AlertLog { var messages: [String] = [] }

/// Turns the run loop until `condition` holds (or `seconds` pass).
@MainActor
private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

private func viewerFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("ViewerKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

/// Opens `url` through the fake document manager and makes its window (as NSDocument would).
@MainActor
private func openWindow(_ url: URL, documents: FakeDocuments) -> DocumentWindowController? {
    guard case .success(let handle)? = complete(30, { try await documents.open(url) }) else { return nil }
    let controller = Viewer.shared.makeWindowController(for: handle) as? DocumentWindowController
    controller?.window?.layoutIfNeeded()
    return controller
}

/// The mockups' lease (docs/mockups/src/shared.js): 12 Letter pages with a title, clauses in Georgia and a footer.
private func makeLeasePDF() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    let scale: CGFloat = 612 / 560
    let sans = { (size: CGFloat, weight: NSFont.Weight) in NSFont.systemFont(ofSize: size * scale, weight: weight) }
    let serif = NSFont(name: "Georgia", size: 11.6 * scale) ?? NSFont.systemFont(ofSize: 11.6 * scale)
    let bold = NSFont(name: "Georgia-Bold", size: 11.6 * scale) ?? serif
    let justified = NSMutableParagraphStyle()
    justified.alignment = .justified
    justified.lineHeightMultiple = 1.32
    justified.paragraphSpacing = 8 * scale
    let headingStyle = NSMutableParagraphStyle()
    headingStyle.paragraphSpacingBefore = 14 * scale
    headingStyle.paragraphSpacing = 4 * scale
    let clauses: [(String, String)] = [
        ("1. PARTIES", "This Residential Lease Agreement (the \"Agreement\") is entered into on 14 September 2026 between |Margaret Ellison| (\"Landlord\"), of 48 Orchard Lane, Bath, and |Priya Natarajan| (\"Tenant\"). The Landlord agrees to let, and the Tenant agrees to take, the premises described below on the terms set out in this Agreement."),
        ("2. PREMISES", "The premises are the two-bedroom flat known as Flat 3, 112 Walcot Street, Bath BA1 5BG, together with the storage locker numbered 3 in the basement and one allocated parking space. The premises are let furnished according to the inventory attached as Schedule A."),
        ("3. TERM", "The tenancy begins on 1 October 2026 and continues for a fixed term of twelve months, ending on 30 September 2027. Either party may give two months' written notice to end the tenancy after the fixed term has expired. Notice must be given in writing and delivered by hand, by post or by email to the addresses in clause 14."),
        ("4. RENT", "The Tenant shall pay rent of £1,450 per calendar month in advance on the first day of each month, by standing order to the Landlord's nominated bank account. The first payment is due on or before the start date. Rent includes water rates but excludes gas, electricity, broadband and council tax."),
        ("5. DEPOSIT", "A deposit of £1,670 is payable on signing and will be protected with an approved tenancy deposit scheme within thirty days. The deposit will be returned within ten working days of the end of the tenancy, less any agreed deductions."),
    ]
    for number in 1...12 {
        context.beginPDFPage(nil)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Residential Lease Agreement\n", attributes: [.font: sans(17, .bold), .foregroundColor: NSColor(white: 0.13, alpha: 1)]))
        let subtitle = number == 1 ? "Prepared 14 September 2026 · 12 pages" : "Page \(number) of 12 — Schedule"
        let subtitleStyle = NSMutableParagraphStyle()
        subtitleStyle.paragraphSpacingBefore = 4 * scale
        subtitleStyle.paragraphSpacing = 12 * scale
        text.append(NSAttributedString(string: subtitle + "\n", attributes: [.font: sans(10.5, .regular), .foregroundColor: NSColor(white: 0.4, alpha: 1),
                                                                             .paragraphStyle: subtitleStyle]))
        for (heading, body) in clauses {
            text.append(NSAttributedString(string: heading + "\n", attributes: [.font: sans(11.6, .bold), .foregroundColor: NSColor(white: 0.27, alpha: 1),
                                                                                .kern: 0.5, .paragraphStyle: headingStyle]))
            for (index, part) in body.split(separator: "|", omittingEmptySubsequences: false).enumerated() {
                text.append(NSAttributedString(string: String(part), attributes: [.font: index % 2 == 1 ? bold : serif,
                                                                                  .foregroundColor: NSColor(white: 0.13, alpha: 1),
                                                                                  .paragraphStyle: justified]))
            }
            text.append(NSAttributedString(string: "\n", attributes: [.font: serif, .paragraphStyle: justified]))
        }
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 56 * scale, y: 60, width: 612 - 112 * scale, height: 792 - 60 - 60 * scale), transform: nil), nil)
        CTFrameDraw(frame, context)
        let footer = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(number) of 12", attributes: [.font: sans(9.5, .regular),
                                                                                                                     .foregroundColor: NSColor.gray]))
        context.textPosition = CGPoint(x: 612 - 56 * scale - CTLineGetTypographicBounds(footer, nil, nil, nil), y: 30)
        CTLineDraw(footer, context)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

// MARK: - Drop decisions (ux §3)

@MainActor
private func viewerKitDropDecisions() {
    let me = UUID(), other = UUID()
    let pdf = DroppedFile(url: URL(fileURLWithPath: "/tmp/Inventory.pdf"), isPDF: true, canConvert: true, pageCount: 3)
    let pdf2 = DroppedFile(url: URL(fileURLWithPath: "/tmp/Annex.pdf"), isPDF: true, canConvert: true, pageCount: 2)
    let word = DroppedFile(url: URL(fileURLWithPath: "/tmp/Letter.docx"), isPDF: false, canConvert: true)
    let sketch = DroppedFile(url: URL(fileURLWithPath: "/tmp/Logo.sketch"), isPDF: false, canConvert: false)
    let folder = DroppedFile(url: URL(fileURLWithPath: "/tmp/Scans"), isDirectory: true, isPDF: false, canConvert: false)
    typealias Row = (payload: DropPayload, zone: DropZone, locked: Bool, option: Bool, outcome: DropOutcome, label: String?)
    let table: [Row] = [
        // Files on the page area open (converted first when needed): "Open".
        (.files([pdf]), .pageArea, false, false, .open([pdf.url]), "Open"),
        (.files([word, pdf]), .pageArea, false, false, .open([word.url, pdf.url]), "Open"),
        // Between thumbnails: the file's pages go in there, with the count when it's known.
        (.files([pdf]), .sidebarGap(2), false, false, .insertFiles([pdf.url], atGap: 2), "Add 3 pages here"),
        (.files([pdf, pdf2]), .workspaceGap(12), false, false, .insertFiles([pdf.url, pdf2.url], atGap: 12), "Add 5 pages here"),
        (.files([word]), .sidebarGap(0), false, false, .insertFiles([word.url], atGap: 0), "Add here"),
        // Welcome window: one file opens, several combine.
        (.files([pdf]), .welcome, false, false, .open([pdf.url]), "Open"),
        (.files([pdf, word]), .welcome, false, false, .combine([pdf.url, word.url]), "Combine files"),
        // Drops that can't work say why.
        (.files([folder]), .sidebarGap(1), false, false, .refuse("Can’t add a folder. Drop the files inside it."), nil),
        (.files([sketch]), .pageArea, false, false,
         .refuse("Super PDF can’t turn “.sketch” files into a PDF. Try opening the file in its app and using Print › Save as PDF."), nil),
        (.files([pdf]), .sidebarGap(1), true, false, .refuse(Strings.Errors.passwordPrompt), nil),
        // Thumbnails within the window reorder; dropping them back where they are does nothing.
        (.pages(from: me, indices: [4, 2]), .sidebarGap(0), false, false, .movePages([2, 4], toGap: 0), nil),
        (.pages(from: me, indices: [2, 3]), .sidebarGap(2), false, false, .none, nil),
        (.pages(from: me, indices: [2, 3]), .workspaceGap(4), false, false, .none, nil),
        (.pages(from: me, indices: [2, 3]), .workspaceGap(5), false, false, .movePages([2, 3], toGap: 5), nil),
        // From another window: copy, ⌥ moves.
        (.pages(from: other, indices: [0, 1]), .sidebarGap(3), false, false, .copyPages(from: other, [0, 1], toGap: 3, removingFromSource: false), "Add 2 pages here"),
        (.pages(from: other, indices: [0]), .workspaceGap(3), false, true, .copyPages(from: other, [0], toGap: 3, removingFromSource: true), "Add 1 page here"),
        (.pages(from: other, indices: [0]), .pageArea, false, false, .none, nil),
        // Text on a page: a new text box.
        (.text("Approved"), .pageArea, false, false, .addText("Approved"), "Add text"),
        (.text("Approved"), .sidebarGap(1), false, false, .none, nil),
    ]
    for (index, row) in table.enumerated() {
        let decision = DropDecision.decide(row.payload, onto: row.zone, of: me, isLocked: row.locked, optionKey: row.option)
        check(decision.outcome == row.outcome, "row \(index): \(decision.outcome) ≠ \(row.outcome)")
        check(decision.label == row.label, "row \(index): label \(decision.label ?? "nil") ≠ \(row.label ?? "nil")")
        if case .refuse = row.outcome { check(!decision.isAllowed, "row \(index): refused drops aren't allowed") }
    }
}

// MARK: - Page grid model (ux §6.2)

@MainActor
private func viewerKitPageGridModel() {
    var model = PageGridModel(pageCount: 12)
    check(model.count == 12 && model.selection.isEmpty, "12 pages, nothing selected")
    check(PageGridModel.destination(of: [2], toGap: 0) == 0 && PageGridModel.destination(of: [2], toGap: 5) == 4
          && PageGridModel.destination(of: [1, 3], toGap: 5) == 3, "destination counts pages taken out before the gap")

    // Reorder one page: page 7 (index 6) before page 3.
    model.select([6])
    check(model.move([6], toGap: 2) == .move([6], to: 2), "drag before page 3")
    let key = model.entries[6].key
    model.applyMove([6], toGap: 2)
    check(model.entries[2].key == key && model.selection == [2], "the page lands at 3 and stays selected")
    check(model.move([2], toGap: 2) == nil && model.move([2], toGap: 3) == nil, "dropping it back is no move")

    // Multi-select and move a scattered selection to the end.
    model.select([0, 4, 9])
    let keys = [0, 4, 9].map { model.entries[$0].key }
    check(model.move(model.selected, toGap: 12) == .move([0, 4, 9], to: 9), "three pages to the end")
    model.applyMove(model.selected, toGap: 12)
    check(model.entries.suffix(3).map(\.key) == keys && model.selection == [9, 10, 11], "they keep their order and stay selected")
    model.select(IndexSet(integersIn: 0..<20))
    check(model.selection.count == 12, "selection stays inside the pages")

    // Insert a second file: its pages take the next colour (the document's own pages have the first).
    let inventory = PageOrigin(fileName: "Inventory.pdf", colorIndex: model.nextOriginColor)
    check(inventory.colorIndex == 1 && inventory.pill == SPColor.pills[1], "the first mixed-in file is pink, after the document's sky")
    check(model.insertion(of: .file(URL(fileURLWithPath: "/tmp/Inventory.pdf")), atGap: 7)
          == .insertFile(.file(URL(fileURLWithPath: "/tmp/Inventory.pdf")), pages: [], at: 7), "insert before page 8")
    model.applyInsert(keys: [100, 101, 102], atGap: 7, origin: inventory)
    check(model.count == 15 && model.entries[7...9].allSatisfy { $0.origin == inventory } && model.selection == [7, 8, 9],
          "three pages from the file, selected")
    check(model.nextOriginColor == 2, "a second file gets the next colour")

    // Delete, rotate; never the last page.
    check((try? model.deletion([7, 8])) == .delete([7, 8]), "delete two")
    model.applyDelete([7, 8])
    check(model.count == 13 && model.entries.filter { $0.origin == inventory }.count == 1, "one Inventory page left")
    check(model.rotation([3, 1, 3], quarterTurns: -1) == .rotate([1, 3], quarterTurns: -1), "rotate left, sorted, once each")
    let single = PageGridModel(pageCount: 1)
    do { _ = try single.deletion([0]); check(false, "the last page can't go") } catch {
        check((error as? PageEditError) == .lastPage && error.localizedDescription == "A PDF needs at least one page.", "says why")
    }
    let combined = PageGridModel(entries: [PageGridModel.Entry(key: 1, origin: PageOrigin(fileName: "A.pdf", colorIndex: 0))])
    check(combined.nextOriginColor == 1, "a combined document's files take the colours in turn")
}

// MARK: - The workspace model (ux §6.2)

@MainActor
private func viewerKitWorkspaceModel() {
    let lease = PageOrigin(fileName: "Lease agreement.pdf", colorIndex: 0), plan = PageOrigin(fileName: "Floor plan.png", colorIndex: 1)
    let schedule = PageOrigin(fileName: "Schedule.pdf", colorIndex: 3)
    // Lease (3 pages), the plan (1), Schedule (2), then a page of the lease moved to the end.
    let origins = [lease, lease, lease, plan, schedule, schedule, lease]
    var model = WorkspaceModel(entries: origins.enumerated().map { PageGridModel.Entry(key: 10 + $0.offset, origin: $0.element) }, documentName: "Combined")
    check(model.files.map(\.origin) == [lease, plan, schedule] && model.files.map(\.pages) == [[0, 1, 2, 6], [3], [4, 5]],
          "files in the order of their first page, with all their pages")
    let files = model.items(.files)
    check(files.count == 4 && files.last == .add && files[0] == .file(lease, pages: [0, 1, 2, 6]), "a card per file and the add card")
    check(model.items(.pages).count == 8 && model.items(.pages)[3] == .page(3, key: 13, file: plan), "a card per page, each with its file")
    check(model.pages(of: [.file(plan), .file(schedule)], in: .files) == [3, 4, 5], "two file cards mean their pages")

    // Gaps between cards are gaps between pages: before the card's first page, or the end.
    check(model.pageGap(forCardGap: 1, in: .files) == 3 && model.pageGap(forCardGap: 3, in: .files) == 7, "a file card's gap")
    check(model.pageGap(forCardGap: 1, in: .files, excluding: [.file(plan)]) == 4, "the dragged card is left out")
    check(model.pageGap(forCardGap: 2, in: .pages) == 2 && model.pageGap(forCardGap: 7, in: .pages) == 7, "a page card's gap")

    // A file converting before page 4 waits as a card there, in both views.
    model.pending = [PendingFile(name: "Budget.xlsx", colorIndex: 4, gap: 4, fraction: 0.5)]
    if case .pending(let file) = model.items(.files)[2] { check(file.name == "Budget.xlsx", "converting card before Schedule") } else {
        check(false, "converting card before Schedule (\(model.items(.files).map(\.id)))")
    }
    if case .pending = model.items(.pages)[4] {} else { check(false, "converting card before page 5 in Pages") }
    check(model.items(.files).filter(\.isContent).count == 3 && model.pageGap(forCardGap: 2, in: .files) == 4,
          "converting cards aren't counted in gaps")
    check(model.statusLine(.files, selectedCards: 1) == "4 files · 7 pages · 1 selected", "Files status (\(model.statusLine(.files, selectedCards: 1)))")
    check(model.statusLine(.pages, selectedCards: 0) == "7 pages from 4 files", "Pages status (\(model.statusLine(.pages, selectedCards: 0)))")
    model.pending = []

    // Sorting moves whole files; reversing turns the order round.
    check(model.arrangement(.nameAscending, in: .files) == [[3], [0, 1, 2, 6], [4, 5]], "A to Z: Floor plan, Lease, Schedule")
    check(model.arrangement(.nameDescending, in: .files) == [[4, 5], [0, 1, 2, 6], [3]], "Z to A")
    check(model.arrangement(.reverse, in: .files) == [[4, 5], [3], [0, 1, 2, 6]], "files back to front")
    check(model.arrangement(.reverse, in: .pages)?.flatMap { $0 } == [6, 5, 4, 3, 2, 1, 0], "pages back to front")
    let sorted = WorkspaceModel(entries: [PageGridModel.Entry(key: 1, origin: plan), PageGridModel.Entry(key: 2, origin: lease)], documentName: "x")
    check(sorted.arrangement(.nameAscending, in: .files) == nil, "already in order: nothing to do")

    // The document's own pages are a file named after it, in the first colour.
    let own = WorkspaceModel(entries: [PageGridModel.Entry(key: 1), PageGridModel.Entry(key: 2, origin: plan)], documentName: "Report.pdf")
    check(own.files.map(\.origin) == [PageOrigin(fileName: "Report.pdf", colorIndex: 0), plan], "own pages are the document's file")
}

// MARK: - Read aloud, recents

@MainActor
private func viewerKitSentences() {
    let text = "The tenancy begins on 1 October 2026. Either party may give notice! Is rent due monthly? Yes."
    let sentences = SentenceSplitter.sentences(in: text)
    let strings = sentences.map { (text as NSString).substring(with: $0).trimmingCharacters(in: .whitespaces) }
    check(strings == ["The tenancy begins on 1 October 2026.", "Either party may give notice!", "Is rent due monthly?", "Yes."],
          "four sentences (\(strings))")
    let spoken = (text as NSString).range(of: "notice")
    check(SentenceSplitter.sentence(containing: spoken, in: sentences) == sentences[1], "the word's sentence is highlighted")
}

@MainActor
private func viewerKitRecentDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let locale = Locale(identifier: "en_GB")
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!
    let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 16, minute: 12))!
    let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
    let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 9))!
    let lastYear = calendar.date(from: DateComponents(year: 2025, month: 9, day: 12, hour: 9))!
    let weekAgo = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
    check(RecentDates.string(for: yesterday, now: now, calendar: calendar, locale: locale).hasPrefix("Yesterday, "), "yesterday with the time")
    check(RecentDates.string(for: weekAgo, now: now, calendar: calendar, locale: locale) == "Friday", "this week: the day")
    check(RecentDates.string(for: monday, now: now, calendar: calendar, locale: locale) == "12 Oct", "older: day and month")
    check(RecentDates.string(for: september, now: now, calendar: calendar, locale: locale) == "12 Sept"
          || RecentDates.string(for: september, now: now, calendar: calendar, locale: locale) == "12 Sep", "12 Sep")
    check(RecentDates.string(for: lastYear, now: now, calendar: calendar, locale: locale).hasSuffix("2025"), "another year shows it")
}

// MARK: - Window metrics (ux §2.1, main-window.png)

@MainActor
private func viewerKitWindow() {
    let (documents, _) = installViewer()
    let folder = viewerFolder("window")
    let url = folder.appendingPathComponent("Lease agreement.pdf")
    try? makeLeasePDF().write(to: url)
    guard let controller = openWindow(url, documents: documents), let window = controller.window else { check(false, "window"); return }
    check(Services.viewer === Viewer.shared && Services.toolProviders.contains { $0 is ViewerTools }, "installs the viewer and its tiles")
    check(window.frame.size == SPMetrics.Window.defaultSize && window.minSize == SPMetrics.Window.minimumSize,
          "1100 × 760, at least 640 × 440 (\(window.frame.size), \(window.minSize))")
    check(window.toolbarStyle == .unified && window.titleVisibility == .visible, "unified toolbar, native title")
    check(window.title == "Lease agreement.pdf" && window.subtitle.contains("page") && window.representedURL == url, "native title, page-count subtitle and proxy icon (\(window.subtitle))")
    check(window.frame.height - window.contentLayoutRect.height == SPMetrics.Window.toolbarHeight,
          "52 pt title and toolbar (\(window.frame.height - window.contentLayoutRect.height))")
    let identifiers = window.toolbar?.items.map(\.itemIdentifier) ?? []
    check(identifiers == [.viewMenu, .sidebarTrackingSeparator, .zoom, .flexibleSpace, .markup, .rotate,
                          .space, .tools, .space, .share, .space, .search], "Preview's toolbar plus Tools (\(identifiers.map(\.rawValue)))")
    let tools = window.toolbar?.items.first { $0.itemIdentifier == .tools }
    check(tools?.isBordered == true && tools?.title == "Tools" && tools?.image != nil && tools?.visibilityPriority == .high, "Tools is a native bordered titled item")
    let search = window.toolbar?.items.first { $0.itemIdentifier == .search } as? NSSearchToolbarItem
    check(search?.preferredWidthForSearchField == 180 && search?.searchField.placeholderString == "Search", "180 pt Search")
    check(controller.sidebar.view.frame.width == SPMetrics.Sidebar.defaultWidth, "197 pt sidebar (\(controller.sidebar.view.frame.width))")
    check(controller.sidebar.bottomBar.frame.height == SPMetrics.Sidebar.bottomBarHeight, "29 pt bottom bar")
    check(controller.pdfView.displayMode == .singlePageContinuous && controller.pdfView.pageShadowsEnabled && controller.pdfView.displaysPageBreaks,
          "continuous scroll, shadows, page breaks")
    check(controller.pdfView.pageBreakMargins.top == 4.75 && controller.pdfView.pageBreakMargins.left == 4, "Preview's page-break margins")

    // Thumbnails: sidebar − 32 wide, 12 pt apart, numbered under the page.
    let grid = controller.sidebar.thumbnails
    grid.collectionView.layoutSubtreeIfNeeded()
    let items = (0..<2).compactMap { grid.collectionView.item(at: IndexPath(item: $0, section: 0)) as? PageItem }
    if items.count == 2 {
        let first = items[0].thumbnail.convert(items[0].thumbnail.pageRect, to: grid.collectionView)
        let second = items[1].thumbnail.convert(items[1].thumbnail.pageRect, to: grid.collectionView)
        check(first.width == SPMetrics.Sidebar.defaultWidth - SPMetrics.Sidebar.thumbnailInset, "thumbnail = sidebar − 32 (\(first.width))")
        check(abs(first.minX - 16) < 0.5 && abs(first.minY - 14) < 0.5, "16 pt in, 14 pt down (\(first.origin))")
        let gap = second.minY - (first.maxY + ThumbnailStyle.sidebar.labelGap + ThumbnailStyle.labelHeight)
        check(abs(gap - SPMetrics.Sidebar.thumbnailGap) < 0.5, "12 pt between thumbnails (\(gap))")
        check(items[0].thumbnail.label == "1" && items[1].thumbnail.label == "2", "page numbers")
    } else { check(false, "two thumbnails laid out") }
    check(controller.selectedPages == [0], "the first page starts selected")

    // The tool panel: 320 pt inline at this width; a card over the document below 1000 pt.
    let panel = NSViewController()
    panel.view = NSView()
    Viewer.shared.showToolPanel(panel, in: controller.handle)
    window.layoutIfNeeded()
    check(!controller.panelItem.isCollapsed && controller.panelSlot.view.frame.width == SPMetrics.ToolPanel.width, "320 pt inline panel")
    Viewer.shared.showToolPanel(nil, in: controller.handle)
    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 900, height: 700)), display: false)
    Viewer.shared.showToolPanel(panel, in: controller.handle)
    check(controller.panelItem.isCollapsed && controller.documentArea.overlayPanel === panel, "narrow window: the panel floats")
    Viewer.shared.showToolPanel(nil, in: controller.handle)
    check(controller.documentArea.overlayPanel == nil, "panel closes")
    window.setFrame(NSRect(origin: window.frame.origin, size: SPMetrics.Window.defaultSize), display: false)

    // The banner slot: 44 pt under the toolbar, gone when dismissed.
    Viewer.shared.showBanner(Strings.Banner.madeSmaller(before: 6_100_000, after: 1_700_000), in: controller.handle)
    check(controller.root.bannerSlotHeight == SPMetrics.Banner.height && controller.root.banner != nil, "44 pt banner")

    // Sidebar modes and the View menu's checks.
    Viewer.shared.showSidebar(.tableOfContents, in: controller.handle)
    check(controller.sidebar.mode == .tableOfContents, "Table of Contents")
    let item = NSMenuItem(title: "Thumbnails", action: #selector(DocumentWindowController.performMenuCommand(_:)), keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier(MenuCommand.thumbnails.rawValue)
    controller.performMenuCommand(item)
    check(controller.sidebar.mode == .thumbnails && controller.validateMenuItem(item) && item.state == .on, "View › Thumbnails, ticked")
    let hide = NSMenuItem(title: "", action: #selector(DocumentWindowController.performMenuCommand(_:)), keyEquivalent: "")
    hide.identifier = NSUserInterfaceItemIdentifier(MenuCommand.hideSidebar.rawValue)
    controller.performMenuCommand(hide)
    check(controller.sidebarItem.isCollapsed && controller.validateMenuItem(hide) && hide.title == "Show Sidebar", "Hide Sidebar ⌥⌘1 toggles")
    controller.performMenuCommand(hide)
    let twoPages = NSMenuItem(title: "", action: #selector(DocumentWindowController.performMenuCommand(_:)), keyEquivalent: "")
    twoPages.identifier = NSUserInterfaceItemIdentifier(MenuCommand.twoPages.rawValue)
    controller.performMenuCommand(twoPages)
    check(controller.displayMode == .twoPages && controller.pdfView.displaysAsBook, "Two Pages ⌘3 shows a book")
    // Save a Copy… and Enter Password… go on to the document, never handled here.
    let copy = NSMenuItem(title: "", action: #selector(DocumentWindowController.performMenuCommand(_:)), keyEquivalent: "")
    copy.identifier = NSUserInterfaceItemIdentifier(MenuCommand.saveACopy.rawValue)
    check(controller.validate(.saveACopy, copy) == nil && controller.validate(.enterPassword, copy) == nil
          && !controller.perform(.saveACopy, from: copy) && !controller.perform(.enterPassword, from: copy), "document commands pass through")
    // The context menu (main-window.png).
    let menu = controller.pageMenu(for: [0])
    check(menu.items.map(\.title) == ["Rotate Left", "Rotate Right", "Delete Page", "", "Extract Page…", "Insert Page", "Duplicate", "",
                                      "Black out this page…", "Make smaller…", "Share Page…"], "page menu (\(menu.items.map(\.title)))")
    check(menu.items[0].keyEquivalent == "l" && menu.items[1].keyEquivalent == "r" && menu.items[2].keyEquivalent == KeyCombo.deleteKey,
          "⌘L ⌘R ⌫")
    check(controller.pageMenu(for: [0, 1]).items[2].title == "Delete Pages", "plural for several pages")
    check(controller.pageIndex(forTyped: "3") == 2 && controller.pageIndex(forTyped: "13") == nil, "Go to Page…")
    window.close()
}

// MARK: - Page edits through the window

@MainActor
private func viewerKitPageEdits() {
    let (documents, alerts) = installViewer()
    let folder = viewerFolder("edits")
    let url = folder.appendingPathComponent("Report.pdf")
    try? makePDF(pages: 4).write(to: url)
    guard let controller = openWindow(url, documents: documents) else { check(false, "window"); return }
    let pages = Services.pages as! FakePages
    let undo = controller.handle.undoManager

    // ⌘R on the selected thumbnail.
    controller.sidebar.thumbnails.select([1], scroll: false)
    let rotate = NSMenuItem(title: "", action: #selector(DocumentWindowController.performMenuCommand(_:)), keyEquivalent: "")
    rotate.identifier = NSUserInterfaceItemIdentifier(MenuCommand.rotateRight.rawValue)
    controller.performMenuCommand(rotate)
    wait { controller.handle.pdf.page(at: 1)?.rotation == 90 }
    check(pages.performed.last == .rotate([1], quarterTurns: 1) && controller.handle.pdf.page(at: 1)?.rotation == 90, "⌘R rotates the selection")
    check(undo?.canUndo == true, "one undo step")
    undo?.undo()
    check(controller.handle.pdf.page(at: 1)?.rotation == 0, "⌘Z puts it back")

    // ⌫ deletes; the next page is selected; never the last one.
    controller.sidebar.thumbnails.select([2, 3], scroll: false)
    controller.sidebar.thumbnails.deleteSelection()
    wait { controller.handle.pageCount == 2 }
    check(controller.handle.pageCount == 2 && controller.sidebar.bottomBar.text == "2 pages", "deleted two; “2 pages”")
    check(controller.selectedPages == [1], "selection moves to the page before (\(controller.selectedPages))")
    controller.sidebar.thumbnails.select([0, 1], scroll: false)
    controller.sidebar.thumbnails.deleteSelection()
    wait { !alerts.messages.isEmpty }
    check(alerts.messages == ["A PDF needs at least one page."] && controller.handle.pageCount == 2, "can't delete every page")

    // Rearranging asks PagesKit for a move to the right place.
    controller.pageActions.move([0], toGap: 2)
    wait { pages.performed.last == .move([0], to: 1) }
    check(pages.performed.last == .move([0], to: 1), "drag page 1 after page 2")

    // The workspace: in and out, Esc going back.
    Viewer.shared.showOrganiser(for: controller.handle, adding: [])
    check(controller.workspace != nil && controller.window?.toolbar?.identifier == DocumentToolbar.workspaceToolbarID, "the workspace shows")
    let ids = controller.window?.toolbar?.items.map(\.itemIdentifier) ?? []
    check(ids == [.viewMenu, .workspaceMode, .flexibleSpace, .workspaceAdd, .workspaceRotateLeft, .workspaceRotateRight, .workspaceDelete, .space,
                  .workspaceSelectAll, .workspaceSort, .workspaceLayout, .space, .workspaceFinish], "workspace toolbar (\(ids.map(\.rawValue)))")
    controller.cancelOperation(nil)
    check(controller.workspace == nil && controller.window?.toolbar?.identifier == DocumentToolbar.documentToolbarID, "Esc goes back")
    controller.window?.close()
}

// MARK: - The workspace (ux §6.2)

/// A converter for the workspace's checks and renders: a picture becomes a landscape page with a picture on it, a
/// spreadsheet a page with a table, and while `hold` is set a conversion waits half done (its card shows the progress).
@MainActor
final class WorkspaceConvert: Converting {
    var hold = false
    private(set) var waiting = 0

    func converters(for input: UTType, to output: ConversionFormat) -> [ConverterOffer] { [] }
    func canConvertToPDF(_ url: URL) -> Bool { true }

    func convert(_ job: ConversionJob, progress: ToolProgress) async throws -> ConversionResult {
        progress.report(completed: 62, of: 100)
        waiting += 1
        while hold { try await Task.sleep(nanoseconds: 20_000_000) }
        waiting -= 1
        let ext = job.inputs.first?.pathExtension.lowercased() ?? ""
        try Self.page(picture: ext == "png").write(to: job.destination)
        return ConversionResult(outputs: [job.destination], engine: .builtIn(.attributedText))
    }

    static func page(picture: Bool) -> Data {
        let data = NSMutableData()
        var box = picture ? CGRect(x: 0, y: 0, width: 800, height: 600) : CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        if picture {
            let colors = [CGColor(srgbRed: 0.81, green: 0.89, blue: 1, alpha: 1), CGColor(srgbRed: 0.62, green: 0.76, blue: 0.97, alpha: 1),
                          CGColor(srgbRed: 0.91, green: 0.82, blue: 1, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.45, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 800, y: 600), options: [])
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(10)
            context.stroke(CGRect(x: 110, y: 100, width: 580, height: 400))
            context.setFillColor(CGColor(gray: 1, alpha: 0.85))
            for rect in [CGRect(x: 170, y: 330, width: 170, height: 110), CGRect(x: 170, y: 160, width: 170, height: 120), CGRect(x: 400, y: 160, width: 220, height: 280)] {
                context.fill(rect)
            }
        } else {
            context.setFillColor(CGColor(srgbRed: 0.36, green: 0.56, blue: 0.36, alpha: 1))
            context.fill(CGRect(x: 72, y: 700, width: 220, height: 14))
            context.setFillColor(CGColor(srgbRed: 0.87, green: 0.94, blue: 0.87, alpha: 1))
            context.fill(CGRect(x: 72, y: 640, width: 468, height: 30))
            context.setStrokeColor(CGColor(srgbRed: 0.79, green: 0.84, blue: 0.79, alpha: 1))
            for row in 0..<14 { context.stroke(CGRect(x: 72, y: 640 - CGFloat(row) * 30, width: 468, height: 30)) }
            for x in [228, 384] as [CGFloat] { context.strokeLineSegments(between: [CGPoint(x: x, y: 250), CGPoint(x: x, y: 670)]) }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

@MainActor
private func viewerKitWorkspace() {
    let (documents, alerts) = installViewer()
    let folder = viewerFolder("workspace")
    let lease = folder.appendingPathComponent("Lease agreement.pdf"), schedule = folder.appendingPathComponent("Schedule.pdf")
    let plan = folder.appendingPathComponent("Floor plan.png"), budget = folder.appendingPathComponent("Budget 2026.xlsx")
    try? makeLeasePDF().write(to: lease)
    try? makePDF(pages: 3).write(to: schedule)
    try? Data("png".utf8).write(to: plan)
    try? Data("xlsx".utf8).write(to: budget)
    let convert = WorkspaceConvert()
    Services.convert = convert
    documents.makesWindows = true
    defer { documents.makesWindows = false }

    // Four files dropped on the app: the first PDF opens at once, the others come in around it on their cards.
    convert.hold = true
    Viewer.shared.combine([lease, plan, budget, schedule])
    wait { documents.openDocuments.contains { $0.displayName == "Combined" } && convert.waiting > 0 }
    guard let handle = documents.openDocuments.last(where: { $0.displayName == "Combined" }), let controller = Viewer.shared.controller(for: handle),
          let workspace = controller.workspace else { check(false, "Combine opens the workspace"); return }
    check(handle.pageCount == 12 && workspace.mode == .files, "the lease is in at once; Files shows (\(handle.pageCount) pages)")
    wait { workspace.model.pending.count == 3 && workspace.model.pending.first?.fraction != nil }
    check(workspace.model.pending.map(\.name) == ["Floor plan.png", "Budget 2026.xlsx", "Schedule.pdf"]
          && workspace.model.pending.first?.fraction == 0.62, "the others wait on their cards, the first half converted")
    check(workspace.grid.items.map(\.id).count == 5 && workspace.fileCount == 4, "four file cards and the add card")
    convert.hold = false
    wait { workspace.model.pending.isEmpty && handle.pageCount == 17 }
    let files = workspace.model.files
    check(files.map(\.origin.fileName) == ["Lease agreement.pdf", "Floor plan.png", "Budget 2026.xlsx", "Schedule.pdf"]
          && files.map(\.pages.count) == [12, 1, 1, 3], "in the order dropped (\(files.map(\.origin.fileName)))")
    check(files.map(\.origin.colorIndex) == [0, 1, 2, 3], "each its own pill colour, in turn")
    check(controller.window?.subtitle.hasPrefix("4 files · 17 pages") == true, "the title says it (\(controller.window?.subtitle ?? ""))")

    // Cards: 184 × 242, 36 apart, 28 from the top, centred; a "+" between neighbours.
    controller.window?.layoutIfNeeded()
    workspace.view.layoutSubtreeIfNeeded()
    workspace.grid.relayout(animated: false)
    let ids = workspace.grid.items.map(\.id)
    if let a = workspace.grid.frame(of: ids[0]), let b = workspace.grid.frame(of: ids[1]) {
        check(a.size == SPMetrics.Workspace.fileCard && b.minX - a.maxX == SPMetrics.Workspace.fileGap.width && a.minY == SPMetrics.Workspace.margin,
              "file cards \(a.size), \(b.minX - a.maxX) apart, \(a.minY) down")
        let row = workspace.grid.items.compactMap { workspace.grid.frame(of: $0.id) }.filter { $0.minY == a.minY }
        let left = a.minX, right = workspace.grid.bounds.width - (row.last?.maxX ?? 0)
        check(abs(left - right) <= 1, "the row is centred (\(left) / \(right))")
    } else { check(false, "card frames") }
    let inserters = workspace.grid.subviews.compactMap { $0 as? WorkspaceInserter }.filter { !$0.isHidden }
    check(inserters.count >= 3 && inserters.map(\.gap).sorted().prefix(3) == [1, 2, 3], "a + between each pair of neighbours (\(inserters.map(\.gap)))")

    // Select a file: the menus' page commands act on its pages; rotate, then Pages keeps the selection.
    let pages = Services.pages as! FakePages
    workspace.grid.select([.file(files[3].origin)])
    check(controller.selectedPages == [14, 15, 16] && workspace.model.statusLine(.files, selectedCards: 1).hasSuffix("1 selected"), "Schedule selected")
    workspace.rotateSelection(1)
    wait { pages.performed.last == .rotate([14, 15, 16], quarterTurns: 1) }
    check(handle.pdf.page(at: 15)?.rotation == 90, "rotated Schedule's pages")
    workspace.setMode(.pages)
    check(workspace.grid.selection.count == 3 && controller.selectedPages == [14, 15, 16], "Pages keeps the selection")
    check((controller.window?.toolbar?.items.first { $0.itemIdentifier == .workspaceMode }?.view as? NSSegmentedControl)?.selectedSegment == 1,
          "the toolbar says Pages")

    // A page duplicated in Pages stays in its file; a file duplicated in Files is a file of its own.
    workspace.grid.select([.page(key: workspace.model.entries[13].key)])
    workspace.perform(.duplicate, on: workspace.grid.card(for: .page(key: workspace.model.entries[13].key)) ?? WorkspaceCardView())
    wait { handle.pageCount == 18 }
    check(workspace.model.file(of: 14) == files[2].origin, "the copy is still Budget's")
    workspace.setMode(.files)
    if let planCard = workspace.grid.card(for: .file(files[1].origin)) { workspace.perform(.duplicate, on: planCard) } else { check(false, "plan card") }
    wait { handle.pageCount == 19 }
    check(workspace.model.files.count == 5 && workspace.model.files[2].origin.fileName == "Floor plan.png"
          && workspace.model.files[2].origin.colorIndex == 4, "a second Floor plan card in a new colour")

    // Sort: whole files move, as one undo step.
    workspace.sort(.nameAscending)
    wait { workspace.model.files.first?.origin.fileName == "Budget 2026.xlsx" }
    check(workspace.model.files.map(\.origin.fileName) == ["Budget 2026.xlsx", "Floor plan.png", "Floor plan.png", "Lease agreement.pdf", "Schedule.pdf"],
          "A to Z (\(workspace.model.files.map(\.origin.fileName)))")
    handle.undoManager?.undo()
    controller.documentChanged()   // DocumentKit reports the undone pages; the fake doesn't
    wait { workspace.model.files.first?.origin.fileName == "Lease agreement.pdf" }
    check(workspace.model.files.first?.origin.fileName == "Lease agreement.pdf", "⌘Z puts the old order back in one step")

    // Every page can't go.
    workspace.selectAll()
    workspace.deleteSelection()
    wait { !alerts.messages.isEmpty }
    check(alerts.messages.last == "A PDF needs at least one page." && handle.pageCount == 19, "never the last page")

    // Quick Look (never opened here: a fake panel stands in): the whole list starting at the selected card, so the panel's
    // arrows and strip walk the workspace; several selected cards show just those; each is a temporary PDF of its pages.
    let panel = FakePanel()
    let quickLook = QuickLookController(source: workspace, host: panel)
    let firstFile = workspace.model.files[0].origin
    workspace.grid.select([.file(firstFile)])
    var shown = workspace.quickLookSelection()
    check(shown.items.map(\.title) == workspace.model.files.map(\.origin.fileName) && shown.current == 0 && !shown.showsSelectedOnly,
          "one card selected: every file, starting at it (\(shown.items.map(\.title)))")
    workspace.grid.select([.file(workspace.model.files[1].origin), .file(workspace.model.files[2].origin)])
    shown = workspace.quickLookSelection()
    check(shown.items.count == 2 && shown.showsSelectedOnly, "two cards selected: just those two")
    workspace.grid.select([.file(workspace.model.files[2].origin)])
    quickLook.toggle()
    check(panel.shown == 1 && quickLook.items.count == workspace.model.files.count, "Space opens the panel on the cards")
    check(quickLook.numberOfPreviewItems(in: nil) == quickLook.items.count && quickLook.previewPanel(nil, previewItemAt: 99) == nil, "the data source")
    let leaseItem = quickLook.items[0]
    let leaseFile = leaseItem.previewItemURL
    check(leaseFile?.lastPathComponent == "Lease agreement.pdf" && PDFDocument(url: leaseFile!)?.pageCount == 12
          && leaseFile!.path.hasPrefix(FileManager.default.temporaryDirectory.path), "its file is a temporary PDF of the file's 12 pages")
    check(quickLook.previewPanel(nil, sourceFrameOnScreenFor: leaseItem) == .zero, "no zoom frame while the window isn't on screen")
    quickLook.panelMoved(to: 1)
    check(workspace.grid.selection == [.file(workspace.model.files[1].origin)], "moving in the panel moves the selection")
    quickLook.reloadIfOpen()
    check(panel.reloads == 1 && panel.currentIndex == 1, "a change under the open panel reloads it on the selection")
    quickLook.toggle()
    check(panel.hidden == 1, "Space again closes it")
    let leaseFolder = leaseFile!.deletingLastPathComponent()
    leaseItem.discard()
    check(!FileManager.default.fileExists(atPath: leaseFolder.path), "the temporary file and its folder go with the item")
    workspace.setMode(.pages)
    workspace.grid.select([workspace.grid.items[1].id])
    let pageItems = workspace.quickLookSelection()
    check(pageItems.items.count == handle.pageCount && pageItems.current == 1 && pageItems.items[1].title == "Lease agreement.pdf – Page 2",
          "Pages mode: a card per page (\(pageItems.items[1].title))")
    let pageFile = pageItems.items[1].previewItemURL
    check(PDFDocument(url: pageFile!)?.pageCount == 1, "a page is a one-page temporary PDF")
    pageItems.items.forEach { $0.discard() }
    check(pageFile.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "and is removed")
    workspace.setMode(.files)

    // List view, then Finish: back to the document with the banner that offers to save.
    workspace.setLayout(.list)
    if let row = workspace.grid.frame(of: workspace.grid.items[0].id) { check(row.height == SPMetrics.Workspace.listRowHeight, "list rows") }
    workspace.setLayout(.grid)
    ToolsKitModule.install()
    controller.finishWorkspace()
    check(controller.workspace == nil && controller.root.banner != nil, "Finish shows the document and the banner")
    if let banner = controller.root.banner { controller.root.hideBanner(banner, animated: false) }
    Services.convert = FakeConvert()
    controller.window?.close()
}

// MARK: - The locked PDF's in-window prompt

@MainActor
private func viewerKitLockedPrompt() {
    _ = installViewer()
    var answers: [String?] = []
    Task { @MainActor in answers.append(await Viewer.shared.password(forLocked: "Secret.pdf", retry: false)) }
    wait { Viewer.shared.lockedPrompt(named: "Secret.pdf") != nil }
    guard let prompt = Viewer.shared.lockedPrompt(named: "Secret.pdf") else { check(false, "the prompt window exists"); return }
    let window = prompt.window
    check(window?.frame.size == SPMetrics.Window.defaultSize && window?.title == "Secret.pdf", "a document-sized window titled with the file")
    check(prompt.lockView.openButton.title == "Open" && prompt.lockView.accessibilityLabel() == "This PDF is locked. Enter the password to open it.",
          "lock, sentence, Open")
    prompt.lockView.field.stringValue = "wrong"
    prompt.lockView.openButton.performClick(nil)
    wait { answers.count == 1 }
    check(answers == ["wrong"], "Open answers with the typed password")
    Task { @MainActor in answers.append(await Viewer.shared.password(forLocked: "Secret.pdf", retry: true)) }
    wait { prompt.lockView.field.isEnabled }
    check(prompt.lockView.field.stringValue.isEmpty, "a wrong password clears the field (and shakes it)")
    prompt.lockView.field.stringValue = "open sesame"
    prompt.lockView.openButton.performClick(nil)
    wait { answers.count == 2 }
    check(answers.last == "open sesame", "second try")
    // The document's window is this window.
    let handle = DocumentHandle(url: URL(fileURLWithPath: "/tmp/Secret.pdf"), pdf: PDFDocument(data: makePDF(pages: 1))!, undoManager: makeUndoManager())
    let controller = Viewer.shared.makeWindowController(for: handle)
    check(controller.window === window && Viewer.shared.lockedPrompt(named: "Secret.pdf") == nil, "the window becomes the document's")
    // Closing the window cancels.
    Task { @MainActor in answers.append(await Viewer.shared.password(forLocked: "Other.pdf", retry: false)) }
    wait { Viewer.shared.lockedPrompt(named: "Other.pdf") != nil }
    Viewer.shared.lockedPrompt(named: "Other.pdf")?.window?.close()
    wait { answers.count == 3 }
    check(answers.count == 3 && answers[2] == nil, "closing the window is Cancel")
    controller.window?.close()
}

// MARK: - Contents and Read aloud tiles

@MainActor
private func viewerKitTools() {
    _ = installViewer()
    guard let provider = Services.toolProviders.first(where: { $0 is ViewerTools }) else { check(false, "provider"); return }
    check(provider.tools == [.contents, .readAloud], "Contents and Read aloud")
    check(ToolCatalog.tile(.readAloud).section == .fixAndCheck && !ToolSection.allCases.map(\.title).contains("Understand"),
          "Read aloud sits with Fix & check; no Understand section")
    let document = makeDocument(pages: 2)
    let read = provider.panel(for: .readAloud, context: ToolContext(tool: .readAloud, document: document))
    check(read.archetype == .oneChoice && read.primary.title == "Read from this page" && read.controls.count <= 3, "Read aloud panel (A)")
    if case .popup(_, _, let voices, _) = read.controls.last { check((1...7).contains(voices.count), "at most seven voices") }
    let contents = provider.panel(for: .contents, context: ToolContext(tool: .contents, document: document))
    check(contents.archetype == .oneChoice && contents.primary.title == "Find headings", "Contents panel (A)")
    // Headings nest under the closest bigger one.
    let tree = OutlineBuilder.tree([.init(title: "1", level: 1, page: 0, top: 700), .init(title: "1.1", level: 2, page: 0, top: 600),
                                    .init(title: "1.2", level: 2, page: 1, top: 700), .init(title: "2", level: 1, page: 1, top: 400)])
    check(tree.map(\.heading.title) == ["1", "2"] && tree[0].children.map(\.heading.title) == ["1.1", "1.2"], "outline nesting")
}

// MARK: - Offscreen renders against the mockups

/// Where renders go: $SUPERPDF_RENDERS, else the scratch folder.
private var renderFolder: URL {
    if let path = ProcessInfo.processInfo.environment["SUPERPDF_RENDERS"] { return SuperPDFPaths.ensure(URL(fileURLWithPath: path, isDirectory: true)) }
    return SuperPDFPaths.ensure(scratch.appendingPathComponent("ViewerKit-renders", isDirectory: true))
}

/// Draws a window as the window server would, offscreen and at 2×: system materials (sidebar, document well) are
/// painted with their reference colours, every view draws itself, then PDFKit draws the visible pages.
@MainActor
@discardableResult
private func render(_ window: NSWindow, _ name: String, dark: Bool = false, sidebar: NSView? = nil) -> NSBitmapImageRep? {
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.layoutIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let frameView = window.contentView?.superview else { return nil }
    let bounds = frameView.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = bounds.size
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    (window.appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
        SPColor.windowBackground.color.setFill()
        bounds.fill()
        if let sidebar, !sidebar.isHiddenOrHasHiddenAncestor { SPColor.sidebar.color.setFill(); sidebar.convert(sidebar.bounds, to: frameView).fill() }
        for view in allViews(frameView).compactMap({ $0 as? PDFView }) { SPColor.underPageBackground.color.setFill(); view.convert(view.bounds, to: frameView).fill() }
        // The title bar's glass needs the window server; hide it while the views draw, then draw the toolbar as it lays out.
        let titlebar = allViews(frameView).filter { String(describing: type(of: $0)) == "NSTitlebarContainerView" }
        titlebar.forEach { $0.isHidden = true }
        frameView.displayIgnoringOpacity(bounds, in: context)
        titlebar.forEach { $0.isHidden = false }
        drawTitlebar(of: window, in: frameView)
        drawToolbar(of: window, in: frameView)
        for view in allViews(frameView).compactMap({ $0 as? PDFView }) { drawPages(of: view, in: frameView) }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: renderFolder.appendingPathComponent(name + ".png"))
    return rep
}

private func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }

/// The title bar's background, bottom line and the traffic lights at (20, 18) (ux §2.1), as the window server draws them.
@MainActor
private func drawTitlebar(of window: NSWindow, in frameView: NSView) {
    let height = window.frame.height - window.contentLayoutRect.height
    let bar = NSRect(x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
    SPColor.windowBackground.color.setFill()
    bar.fill()
    if window.toolbar != nil {
        SPColor.separator.color.setFill()
        NSRect(x: 0, y: bar.minY, width: bar.width, height: 1).fill()
    }
    if window.titleVisibility == .visible, window.toolbar?.identifier == DocumentToolbar.documentToolbarID {
        // The window server places the title; stand in for it just after the zoom group.
        let zoom = allViews(frameView).first { String(describing: type(of: $0)).contains("ToolbarItemViewer") && ($0.value(forKey: "item") as? NSToolbarItem)?.itemIdentifier == .zoom }
        let x = (zoom.map { $0.convert($0.bounds, to: frameView).maxX } ?? 200) + 16
        let midY = bar.midY
        NSWorkspace.shared.icon(for: .pdf).draw(in: NSRect(x: x, y: midY - 8, width: 16, height: 16))
        NSAttributedString(string: window.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: SPColor.label.color])
            .draw(at: NSPoint(x: x + 22, y: midY - 1))
        NSAttributedString(string: window.subtitle, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: SPColor.secondaryLabel.color])
            .draw(at: NSPoint(x: x + 22, y: midY - 15))
    }
    for (index, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
        NSColor(hex: hex).setFill()
        let center = NSPoint(x: SPMetrics.Window.trafficLights.x + CGFloat(index) * 20, y: frameView.bounds.height - (window.toolbar == nil ? 18 : 26))
        NSBezierPath(ovalIn: NSRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)).fill()
    }
}

/// The toolbar where NSToolbar placed each item. The window server draws the system's own controls (buttons, the
/// segmented zoom, the search field), so they are drawn here as stand-ins at their real frames; ViewerKit's own item
/// views (the title, Tools, Done) draw themselves.
@MainActor
private func drawToolbar(of window: NSWindow, in frameView: NSView) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let ink = SPColor.label.color.withAlphaComponent(0.72)
    func symbol(_ image: NSImage?, centredIn rect: NSRect, size: CGFloat = 17) {
        guard let image = image?.withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: [ink]))) else { return }
        let imageSize = image.size
        image.draw(in: NSRect(x: rect.midX - imageSize.width / 2, y: rect.midY - imageSize.height / 2, width: imageSize.width, height: imageSize.height))
    }
    for viewer in allViews(frameView) where String(describing: type(of: viewer)).contains("ToolbarItemViewer") {
        guard let item = viewer.value(forKey: "item") as? NSToolbarItem else { continue }
        let rect = viewer.convert(viewer.bounds, to: frameView)
        let kind = viewer.subviews.first.map { String(describing: type(of: $0)) } ?? ""
        if let control = item.view as? NSSegmentedControl {
            // The workspace's Files | Pages: a track, the chosen segment raised, each with its picture and word.
            let frame = control.convert(control.bounds, to: frameView)
            let track = NSRect(x: frame.minX, y: frame.midY - 14, width: frame.width, height: 28)
            SPColor.label.color.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
            let width = track.width / CGFloat(max(control.segmentCount, 1))
            for segment in 0..<control.segmentCount {
                let rect = NSRect(x: track.minX + CGFloat(segment) * width, y: track.minY, width: width, height: track.height)
                if control.isSelected(forSegment: segment) {
                    SPColor.controlBackground.color.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
                }
                let text = NSAttributedString(string: control.label(forSegment: segment) ?? "", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: control.isSelected(forSegment: segment) ? .semibold : .regular), .foregroundColor: SPColor.label.color])
                let image = control.image(forSegment: segment)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [ink])))
                let total = text.size().width + (image.map { $0.size.width + 6 } ?? 0)
                var x = rect.midX - total / 2
                if let image { image.draw(in: NSRect(x: x, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height)); x += image.size.width + 6 }
                text.draw(at: NSPoint(x: x, y: rect.midY - text.size().height / 2))
            }
            continue
        }
        if let view = item.view, view is TitleView {
            let frame = view.convert(view.bounds, to: frameView)
            context.saveGState()
            context.translateBy(x: frame.minX, y: view.isFlipped ? frame.maxY : frame.minY)
            if view.isFlipped { context.scaleBy(x: 1, y: -1) }
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: view.isFlipped)
            view.draw(view.bounds)
            NSGraphicsContext.current = previous
            context.restoreGState()
            continue
        }
        if item.itemIdentifier == .tools || item.itemIdentifier == .workspaceFinish {
            let capsule = NSRect(x: rect.minX + 2, y: rect.midY - 14, width: rect.width - 4, height: 28)
            SPColor.accent.color.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 14, yRadius: 14).fill()
            let text = NSAttributedString(string: item.title, attributes: [.font: SPFont.primaryButton.font(), .foregroundColor: NSColor.white])
            let icon = item.image?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white])))
            let total = text.size().width + (icon.map { $0.size.width + 6 } ?? 0)
            var x = capsule.midX - total / 2
            if let icon { icon.draw(in: NSRect(x: x, y: capsule.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)); x += icon.size.width + 6 }
            text.draw(at: NSPoint(x: x, y: capsule.midY - text.size().height / 2))
            continue
        }
        switch kind {
        case "NSToolbarButton":
            symbol(item.image, centredIn: rect)
        case "NSToolbarPullDownButton":
            symbol(item.image, centredIn: rect.offsetBy(dx: -6, dy: 0))
            symbol(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil), centredIn: NSRect(x: rect.midX + 8, y: rect.minY, width: 12, height: rect.height), size: 9)
        case "NSToolbarItemGroupPickerView":
            let group = item as? NSToolbarItemGroup
            let images = group?.subitems.compactMap(\.image) ?? []
            let capsule = NSRect(x: rect.minX + 4, y: rect.midY - 14, width: rect.width - 8, height: 28)
            let path = NSBezierPath(roundedRect: capsule, xRadius: 8, yRadius: 8)
            SPColor.label.color.withAlphaComponent(0.06).setFill()
            path.fill()
            SPColor.separator.color.setStroke()
            path.stroke()
            let width = capsule.width / CGFloat(max(images.count, 1))
            for (index, image) in images.enumerated() {
                let segment = NSRect(x: capsule.minX + CGFloat(index) * width, y: capsule.minY, width: width, height: capsule.height)
                symbol(image, centredIn: segment, size: 14)
                if index > 0 { SPColor.separator.color.setFill(); NSRect(x: segment.minX, y: segment.minY, width: 1, height: segment.height).fill() }
            }
        case "NSSearchToolbarItemView":
            let field = NSRect(x: rect.maxX - SPMetrics.Toolbar.searchFieldWidth - 12, y: rect.midY - 14, width: SPMetrics.Toolbar.searchFieldWidth, height: 28)
            let path = NSBezierPath(roundedRect: field.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            SPColor.controlBackground.color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.16).setStroke()
            path.stroke()
            symbol(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil), centredIn: NSRect(x: field.minX + 4, y: field.minY, width: 20, height: field.height), size: 12)
            NSAttributedString(string: "Search", attributes: [.font: SPFont.body.font(), .foregroundColor: SPColor.tertiaryLabel.color])
                .draw(at: NSPoint(x: field.minX + 28, y: field.midY - 8))
        case "NSSeparatorToolbarItemView":
            SPColor.separator.color.setFill()
            NSRect(x: rect.midX, y: rect.midY - 11, width: 1, height: 22).fill()
        default:
            break
        }
    }
}

/// PDFKit's pages where the PDFView shows them, with Preview's page shadow.
@MainActor
private func drawPages(of view: PDFView, in frameView: NSView) {
    guard let document = view.document, let context = NSGraphicsContext.current?.cgContext else { return }
    let visible = view.convert(view.bounds, to: frameView)
    context.saveGState()
    context.clip(to: visible)
    for page in view.visiblePages {
        let rect = view.convert(view.convert(page.bounds(for: view.displayBox), from: page), to: frameView)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.white.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        let box = page.bounds(for: view.displayBox)
        context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        page.draw(with: view.displayBox, to: context)
        context.restoreGState()
        _ = document
    }
    context.restoreGState()
}

/// The colour of the pixel at a point (top-left origin, points).
private func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
    rep.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB)
}

private func isAccent(_ color: NSColor?) -> Bool {
    guard let color else { return false }
    let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
    return abs(color.redComponent - accent.redComponent) < 0.12 && abs(color.greenComponent - accent.greenComponent) < 0.12
        && abs(color.blueComponent - accent.blueComponent) < 0.12
}

@MainActor
private func viewerKitRenders() {
    let (documents, _) = installViewer()
    let folder = viewerFolder("renders")
    let url = folder.appendingPathComponent("Lease agreement.pdf")
    try? makeLeasePDF().write(to: url)
    guard let controller = openWindow(url, documents: documents), let window = controller.window else { check(false, "window"); return }
    let renderer = ThumbnailRenderer.shared
    wait { controller.sidebar.thumbnails.collectionView.visibleItems().allSatisfy { ($0 as? PageItem)?.thumbnail.image != nil } }

    // main-window.png: the window with the thumbnail sidebar, page 1 selected.
    if let rep = render(window, "main-window", sidebar: controller.sidebar.view) {
        if let viewer = allViews(window.contentView!.superview!).first(where: {
            String(describing: type(of: $0)).contains("ToolbarItemViewer") && ($0.value(forKey: "item") as? NSToolbarItem)?.itemIdentifier == .tools
        }), let frameView = window.contentView?.superview {
            let frame = viewer.convert(viewer.bounds, to: frameView)
            check(isAccent(pixel(rep, frame.minX + 8, frameView.bounds.height - frame.midY)), "the Tools stand-in is the accent colour")
        }
        if let first = controller.sidebar.thumbnails.collectionView.item(at: IndexPath(item: 0, section: 0)) as? PageItem,
           let frameView = window.contentView?.superview {
            let page = first.thumbnail.convert(first.thumbnail.pageRect, to: frameView)
            check(isAccent(pixel(rep, page.midX, frameView.bounds.height - page.maxY - 3)), "a 2 pt accent ring round the selected page")
        }
    }
    render(window, "main-window-dark", dark: true, sidebar: controller.sidebar.view)
    let originalFrame = window.frame
    for width in [900, 1200, 1600] {
        window.setFrame(NSRect(origin: originalFrame.origin, size: NSSize(width: CGFloat(width), height: originalFrame.height)), display: false)
        render(window, "toolbar-\(width)", sidebar: controller.sidebar.view)
        render(window, "toolbar-\(width)-dark", dark: true, sidebar: controller.sidebar.view)
    }
    window.setFrame(originalFrame, display: false)

    // main-window-result.png: ToolsKit's banner in the 44 pt slot under the toolbar.
    ToolsKitModule.install()
    Viewer.shared.showBanner(ResultBanner("Done. The file is 72% smaller (6.1 MB → 1.7 MB). Saved next to the original.", emphasis: ["72% smaller"],
                                          actions: [.showInFinder, .share, .undo]), in: controller.handle)
    render(window, "main-window-result", sidebar: controller.sidebar.view)
    if let banner = controller.root.banner { controller.root.hideBanner(banner, animated: false) }

    // workspace.png: four files combined, the lease selected, the floor plan hovered with its toolbar, the budget still
    // converting; then Pages, the list, the preview, and the dark appearance.
    window.close()
    renderWorkspace(documents)

    // welcome.png: the four targets and three recents, the first target hovered as in the mockup.
    let now = Date()
    documents.recentDocuments = [
        RecentDocument(url: url, lastOpened: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.date(bySettingHour: 16, minute: 12, second: 0, of: now)!)!,
                       pageCount: 12, fileSize: 6_100_000),
        RecentDocument(url: folder.appendingPathComponent("Tax return 2025.pdf"), lastOpened: now.addingTimeInterval(-3 * 86_400), pageCount: 44, fileSize: 8_000_000),
        RecentDocument(url: folder.appendingPathComponent("Grandma’s recipes.pdf"), lastOpened: now.addingTimeInterval(-38 * 86_400), pageCount: 6, fileSize: 310_000),
    ]
    let welcome = WelcomeWindowController(viewer: Viewer.shared)
    welcome.welcomeView.targets.first?.isHovered = true
    if let welcomeWindow = welcome.window {
        check(welcomeWindow.contentLayoutRect.size == SPMetrics.Welcome.size || welcomeWindow.contentView?.frame.size == SPMetrics.Welcome.size,
              "760 × 520")
        check(!welcomeWindow.styleMask.contains(.resizable), "not resizable")
        let targets = welcome.welcomeView.targets.map(\.frame)
        check(targets.count == 4 && targets.allSatisfy { $0.size == SPMetrics.Welcome.targetSize } && targets[1].minX - targets[0].maxX == 16,
              "four 160 × 140 targets 16 pt apart")
        check(abs(targets[0].minX - (760 - targets[3].maxX)) < 1, "centred")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        render(welcomeWindow, "welcome")
        render(welcomeWindow, "welcome-dark", dark: true)
    }
    // Quick Look on the recent files: the files themselves, starting at the highlighted row, the panel's moves highlight.
    let recentPanel = FakePanel()
    let recentLook = QuickLookController(source: welcome, host: recentPanel)
    let recentSelection = welcome.quickLookSelection()
    check(recentSelection.items.map(\.title) == [url.lastPathComponent, "Tax return 2025.pdf", "Grandma’s recipes.pdf"]
          && recentSelection.current == 0 && recentSelection.items[1].previewItemURL.lastPathComponent == "Tax return 2025.pdf", "the welcome window's recents preview as the files")
    recentLook.toggle()
    check(recentPanel.shown == 1, "Space on the welcome window opens the panel")
    recentLook.panelMoved(to: 2)
    check(welcome.welcomeView.highlightedRow == 2, "moving in the panel highlights that recent file")
    recentSelection.items.forEach { $0.discard() }
    // The sidebar's thumbnails: every page, starting at the selected one; a real file would not be touched.
    let thumbnails = controller.sidebar.thumbnails
    thumbnails.select([1], scroll: false)
    let pageLook = thumbnails.quickLookSelection()
    check(pageLook.items.count == controller.handle.pageCount && pageLook.current == 1 && !pageLook.showsSelectedOnly, "the thumbnails preview every page from the selected one")
    thumbnails.select([0, 2], scroll: false)
    check(thumbnails.quickLookSelection().items.count == 2 && thumbnails.quickLookSelection().showsSelectedOnly, "two selected pages: just those")
    let pagePanel = FakePanel()
    let thumbnailLook = QuickLookController(source: thumbnails, host: pagePanel)
    thumbnails.select([1], scroll: false)
    thumbnailLook.toggle()
    thumbnailLook.panelMoved(to: 3)
    check(pagePanel.shown == 1 && thumbnails.selection == [3], "moving in the panel selects that thumbnail")
    thumbnailLook.items.forEach { $0.discard() }
    _ = renderer
}

/// The workspace's renders (workspace.png, workspace-pages.png, workspace-list.png).
@MainActor
private func renderWorkspace(_ documents: FakeDocuments) {
    let folder = viewerFolder("workspace-renders")
    let lease = folder.appendingPathComponent("Lease agreement.pdf"), schedule = folder.appendingPathComponent("Schedule.pdf")
    let plan = folder.appendingPathComponent("Floor plan.png"), budget = folder.appendingPathComponent("Budget 2026.xlsx")
    try? makeLeasePDF().write(to: lease)
    try? makePDF(pages: 3).write(to: schedule)
    try? Data("png".utf8).write(to: plan)
    try? Data("xlsx".utf8).write(to: budget)
    let convert = WorkspaceConvert()
    Services.convert = convert
    documents.makesWindows = true
    defer { documents.makesWindows = false; Services.convert = FakeConvert() }
    // The plan converts; the budget is held half done for the picture.
    Viewer.shared.combine([lease, plan, schedule])
    wait { documents.openDocuments.last?.displayName == "Combined" && documents.openDocuments.last?.pageCount == 16 }
    guard let handle = documents.openDocuments.last, let controller = Viewer.shared.controller(for: handle), let workspace = controller.workspace,
          let window = controller.window else { check(false, "the workspace for the renders"); return }
    convert.hold = true
    controller.pageActions.insertFiles([budget], atGap: 13, tagged: true, firstColor: 3)
    wait { !workspace.model.pending.isEmpty && workspace.model.pending[0].fraction != nil }
    window.layoutIfNeeded()
    workspace.view.layoutSubtreeIfNeeded()
    workspace.grid.relayout(animated: false)
    func settle() {
        workspace.grid.updateVisibleCards()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // the thumbnails render off the main thread
    }
    let ids = workspace.grid.items.map(\.id)
    workspace.grid.select([ids[0]])
    workspace.grid.card(for: ids[1])?.isHovered = true
    settle()
    if let rep = render(window, "workspace") {
        // The canvas is the soft blue (ux §2.3), the selected card has the accent ring.
        let canvas = pixel(rep, 40, 300)
        check(canvas.map { abs($0.redComponent - 0xED / 255) < 0.03 && abs($0.blueComponent - 0xFE / 255) < 0.03 } ?? false,
              "the canvas is #EDF3FE (\(String(describing: canvas)))")
        if let frame = workspace.grid.frame(of: ids[0]), let frameView = window.contentView?.superview {
            let onScreen = workspace.grid.convert(frame, to: frameView)
            check(isAccent(pixel(rep, onScreen.midX, frameView.bounds.height - onScreen.maxY - 1)), "the selected card's accent ring")
        }
    }
    render(window, "workspace-dark", dark: true)
    workspace.grid.card(for: ids[1])?.isHovered = false
    workspace.setMode(.pages)
    workspace.grid.select([workspace.grid.items[1].id])
    workspace.grid.card(for: workspace.grid.items[4].id)?.isHovered = true
    settle()
    render(window, "workspace-pages")
    workspace.setMode(.files)
    workspace.setLayout(.list)
    settle()
    render(window, "workspace-list")
    workspace.setLayout(.grid)
    convert.hold = false
    wait { workspace.model.pending.isEmpty }
    window.close()
}

// MARK: - Performance budgets (lightweight like Preview)

/// The process's memory footprint (what Activity Monitor shows), in bytes.
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

@MainActor
private func viewerKitPerformance() {
    let (documents, _) = installViewer()
    let folder = viewerFolder("performance")
    let url = folder.appendingPathComponent("Long.pdf")
    try? makePDF(pages: 500).write(to: url)
    ThumbnailRenderer.shared.removeAll()
    var pdfViewSize = NSSize.zero
    var scale: CGFloat = 1

    autoreleasepool {
        let rendersBefore = ThumbnailRenderer.shared.renders

        // Open a 500-page PDF and show page 1: under 150 ms.
        let start = Date()
        guard let pdf = PDFDocument(url: url) else { check(false, "500-page fixture"); return }
        let handle = DocumentHandle(url: url, pdf: pdf, undoManager: makeUndoManager())
        documents.openDocuments.append(handle)
        let controller = Viewer.shared.makeWindowController(for: handle) as! DocumentWindowController
        controller.window?.layoutIfNeeded()
        controller.window?.displayIfNeeded()
        let shown = Date().timeIntervalSince(start)
        check(controller.pdfView.currentPage === pdf.page(at: 0) && controller.pdfView.visiblePages.contains(pdf.page(at: 0)!),
              "page 1 is on screen (\(controller.pdfView.visiblePages.map { pdf.index(for: $0) }))")
        // Budgets hold for optimised builds; a debug build on a busy machine only reports the time.
        #if !DEBUG
        check(shown < 0.150, String(format: "500-page PDF to page 1 in %.0f ms (budget 150)", shown * 1000))
        #endif
        print(String(format: "  open 500 pages → page 1: %.1f ms", shown * 1000))

        // A window from nothing (the share of a cold launch ViewerKit owns): well under 0.5 s.
        let windowStart = Date()
        let small = DocumentHandle(url: nil, displayName: "Small", pdf: PDFDocument(data: makePDF(pages: 2))!, undoManager: makeUndoManager())
        let second = Viewer.shared.makeWindowController(for: small)
        second.window?.layoutIfNeeded()
        second.window?.displayIfNeeded()
        let windowTime = Date().timeIntervalSince(windowStart)
        check(windowTime < 0.5, String(format: "a document window in %.0f ms (budget 500)", windowTime * 1000))
        print(String(format: "  new window: %.1f ms", windowTime * 1000))
        second.window?.close()

        // Thumbnails: only what shows (and a screenful the collection view prepares) renders, all off the main thread.
        wait { controller.sidebar.thumbnails.collectionView.visibleItems().allSatisfy { ($0 as? PageItem)?.thumbnail.image != nil } }
        let visible = controller.sidebar.thumbnails.collectionView.visibleItems().count
        let rendered = ThumbnailRenderer.shared.renders - rendersBefore
        check(rendered > 0 && rendered <= 40, "thumbnails render lazily (\(rendered) for \(visible) visible of 500)")
        check(ThumbnailRenderer.shared.offMainRenders >= rendered, "thumbnails render off the main thread")

        // Scrolling: each step of the sidebar and of the document stays inside a 120 Hz frame (8.3 ms).
        let collection = controller.sidebar.thumbnails.collectionView
        let clip = controller.sidebar.thumbnails.scrollView.contentView
        var steps = 0
        let scrollStart = Date()
        var y: CGFloat = 0
        while y < min(collection.frame.height, 40_000) && steps < 200 {
            clip.scroll(to: NSPoint(x: 0, y: y))
            controller.sidebar.thumbnails.scrollView.reflectScrolledClipView(clip)
            collection.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
            y += 180
            steps += 1
        }
        let perStep = Date().timeIntervalSince(scrollStart) / Double(max(steps, 1))
        check(perStep < 1.0 / 120, String(format: "thumbnail scrolling %.2f ms a step (budget 8.3)", perStep * 1000))
        print(String(format: "  sidebar scroll: %.2f ms/step over %d steps", perStep * 1000, steps))
        let documentStart = Date()
        for index in stride(from: 0, to: 400, by: 4) {
            if let page = pdf.page(at: index) { controller.pdfView.go(to: page) }
            controller.pdfView.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
        }
        let perPage = Date().timeIntervalSince(documentStart) / 100
        check(perPage < 1.0 / 120, String(format: "document scrolling %.2f ms a step (budget 8.3)", perPage * 1000))
        print(String(format: "  document scroll: %.2f ms/step", perPage * 1000))
        pdfViewSize = controller.pdfView.bounds.size
        scale = controller.pdfView.scaleFactor
        documents.openDocuments.removeAll { $0 === handle }
        controller.window?.close()
    }

    // Idle memory. PDFKit keeps a fixed GPU tile pool (about 120 MB on macOS 26, the same for a 1-page or a 500-page
    // file) for every PDFView at any zoom but 100 %; every viewer built on PDFKit pays it, Preview included. ViewerKit's
    // budget is what it adds on top of a bare PDFView showing the same pages at the same zoom: the sidebar and its
    // thumbnails, the toolbar and the rest of the window.
    func settled() -> Double { RunLoop.main.run(until: Date().addingTimeInterval(1.5)); return Double(footprint()) / 1_048_576 }
    var bare = 0.0
    autoreleasepool {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: pdfViewSize), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = PDFView(frame: NSRect(origin: .zero, size: pdfViewSize))
        view.document = PDFDocument(url: url)
        view.scaleFactor = scale
        window.contentView = view
        window.displayIfNeeded()
        bare = settled()
        window.close()
    }
    var full = 0.0
    autoreleasepool {
        guard let handle = complete(30, { try await documents.open(url) }).flatMap({ try? $0.get() }) else { return }
        let controller = Viewer.shared.makeWindowController(for: handle) as! DocumentWindowController
        controller.window?.displayIfNeeded()
        wait { controller.sidebar.thumbnails.collectionView.visibleItems().allSatisfy { ($0 as? PageItem)?.thumbnail.image != nil } }
        full = settled()
        controller.window?.close()
    }
    check(full - bare < 40, String(format: "ViewerKit adds %.0f MB over a bare PDFView (budget 40)", full - bare))
    print(String(format: "  idle footprint: %.0f MB with the 500-page document at %.0f%% (a bare PDFView at that zoom: %.0f MB)",
                 full, scale * 100, bare))
}

// MARK: - Crop handles (ux §5.3 Crop) and thumbnails with markup (features #11)

@MainActor
private func viewerKitCropHandles() {
    // The drag maths: sides move, stay inside the page and never get smaller than the minimum.
    let page = CGRect(x: 0, y: 0, width: 600, height: 800), kept = CGRect(x: 50, y: 60, width: 500, height: 680)
    let topLeft = CropFrame.Handle(dx: -1, dy: 1), right = CropFrame.Handle(dx: 1, dy: 0)
    check(CropFrame.dragged(kept, handle: topLeft, by: CGSize(width: 20, height: -30), within: page, minimum: 18)
          == CGRect(x: 70, y: 60, width: 480, height: 650), "the top-left corner moves its two sides")
    check(CropFrame.dragged(kept, handle: right, by: CGSize(width: 500, height: 40), within: page, minimum: 18).maxX == 600,
          "a side stops at the page's edge")
    check(CropFrame.dragged(kept, handle: right, by: CGSize(width: -900, height: 0), within: page, minimum: 18).width == 18,
          "and never crops below the minimum")
    check(CropFrame.handle(at: CGPoint(x: 52, y: 738), on: kept, slop: 7) == topLeft, "a corner is found under the pointer")
    check(CropFrame.handle(at: CGPoint(x: 548, y: 400), on: kept, slop: 7) == right, "an edge anywhere along it")
    check(CropFrame.handle(at: CGPoint(x: 300, y: 400), on: kept, slop: 7) == nil, "the middle of the page isn't a handle")

    // The handles live over the PDF view while the panel is open, and go with it.
    let (documents, _) = installViewer()
    let url = viewerFolder("crop").appendingPathComponent("Crop.pdf")
    try? makePDF(pages: 3).write(to: url)
    guard let controller = openWindow(url, documents: documents) else { check(false, "window"); return }
    var changes: [PageInsets] = []
    let panel = NSViewController()
    panel.view = NSView()
    Viewer.shared.showToolPanel(panel, in: controller.handle)
    Viewer.shared.showCropHandles(CropHandles(pages: [0], insets: PageInsets(top: 10, left: 20, bottom: 30, right: 40)) { changes.append($0) },
                                  in: controller.handle)
    guard let view = controller.cropHandlesView else { check(false, "crop handles shown"); return }
    check(view.superview === controller.pdfView, "the handles sit over the document")
    Viewer.shared.showCropHandles(CropHandles(pages: [0, 1], insets: .zero) { changes.append($0) }, in: controller.handle)
    check(controller.cropHandlesView === view && view.handles.pages == [0, 1], "new margins update the same handles")
    Viewer.shared.showToolPanel(nil, in: controller.handle)
    check(controller.cropHandlesView == nil && view.superview == nil, "closing the panel removes them")
    check(changes.isEmpty, "nothing reported without a drag")
    controller.close()
}

@MainActor
private func viewerKitThumbnailMarkup() {
    _ = installViewer()
    let document = PDFDocument(data: makePDF(pages: 1))!
    let page = document.page(at: 0)!
    check(ThumbnailRenderer.markupSignature(of: page) == 0, "a page without annotations has no markup")
    func thumbnail() -> CGImage? {
        var image: CGImage?
        ThumbnailRenderer.shared.image(for: page, pixelWidth: 306) { image = $0 }
        let deadline = Date().addingTimeInterval(10)
        while image == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return image
    }
    /// The colour at a point of the page (points from the bottom left) in a 306 px wide picture of a Letter page.
    func pixel(_ image: CGImage?, at point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let scale = CGFloat(image.width) / 612
        let x = Int(point.x * scale), y = image.height - 1 - Int(point.y * scale)
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }
    let plain = thumbnail()
    check(pixel(plain, at: CGPoint(x: 300, y: 300)).map { $0.r > 240 && $0.g > 240 && $0.b > 240 } == true, "white page")

    let square = PDFAnnotation(bounds: CGRect(x: 250, y: 250, width: 100, height: 100), forType: .square, withProperties: nil)
    square.color = .systemRed
    square.interiorColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    page.addAnnotation(square)
    let signature = ThumbnailRenderer.markupSignature(of: page)
    check(signature != 0, "an added box changes the page's markup")
    let marked = thumbnail()
    check(pixel(marked, at: CGPoint(x: 300, y: 300)).map { $0.r > 200 && $0.g < 80 && $0.b < 80 } == true,
          "the thumbnail shows the box: \(String(describing: pixel(marked, at: CGPoint(x: 300, y: 300))))")
    square.bounds = CGRect(x: 50, y: 50, width: 100, height: 100)
    check(ThumbnailRenderer.markupSignature(of: page) != signature, "moving it changes the markup again")
    page.removeAnnotation(square)
    check(ThumbnailRenderer.markupSignature(of: page) == 0, "removing it brings the plain page back")
    check(pixel(thumbnail(), at: CGPoint(x: 300, y: 300)).map { $0.r > 240 && $0.g > 240 } == true, "and its plain picture")
    let link = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 50, height: 50), forType: .link, withProperties: nil)
    page.addAnnotation(link)
    check(ThumbnailRenderer.markupSignature(of: page) == 0, "links don't show in thumbnails")
}

/// Quick Look's panel, as far as the controller uses it; counts instead of opening anything.
@MainActor
final class FakePanel: PreviewPanelHosting {
    var isVisible = false
    var currentIndex = 0
    private(set) var shown = 0, hidden = 0, reloads = 0
    func show() { isVisible = true; shown += 1 }
    func hide() { isVisible = false; hidden += 1 }
    func reload() { reloads += 1 }
}
