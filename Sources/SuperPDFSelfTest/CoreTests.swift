import AppKit
import Combine
import PDFKit
import SuperPDFCore

// Owned with SuperPDFCore: the contracts every module builds on.
func registerCoreTests() {
    SelfTest.cases.append(("Core.defaultsRoundTrip", { coreDefaultsRoundTrip() }))
    SelfTest.cases.append(("Core.tokenValues", { coreTokenValues() }))
    SelfTest.cases.append(("Core.toolCatalog", { coreToolCatalog() }))
    SelfTest.cases.append(("Core.strings", { coreStrings() }))
    SelfTest.cases.append(("Core.converterTable", { coreConverterTable() }))
    SelfTest.cases.append(("Core.menus", { coreMenus() }))
    SelfTest.cases.append(("Core.pagesAndNaming", { corePagesAndNaming() }))
    SelfTest.cases.append(("Core.valueTypes", { coreValueTypes() }))
    SelfTest.cases.append(("Core.codable", { coreCodable() }))
    SelfTest.cases.append(("Core.undo", { coreUndo() }))
    SelfTest.cases.append(("Core.documents", { coreDocuments() }))
    SelfTest.cases.append(("Core.fakes", { coreFakes() }))
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    guard let data = try? JSONEncoder().encode(value), let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value
}

/// Copy rules of ux §1.1: curly quotes and apostrophes, a real ellipsis, no exclamation marks.
private func followsTone(_ text: String) -> Bool {
    !text.contains("\"") && !text.contains("'") && !text.contains("...") && !text.contains("!")
}

// MARK: - Defaults (ux §6.6)

@MainActor
private func coreDefaultsRoundTrip() {
    var checked: Set<String> = []
    func roundTrip<V: Codable & Equatable>(_ key: Defaults.Key<V>, _ value: V, native: Bool = false) {
        checked.insert(key.name)
        check(Defaults[key] == key.defaultValue, "\(key.name) starts at its default")
        check(value != key.defaultValue, "\(key.name): the test value differs from the default")
        var seen: [V] = []
        let watcher = Defaults.publisher(key).sink { seen.append($0) }
        Defaults[key] = value
        check(Defaults[key] == value, "\(key.name) reads back what was written")
        check(seen == [key.defaultValue, value], "\(key.name) publishes the default, then the change")
        if native {
            // Plain values stay readable with `defaults read`.
            check(Defaults.store.object(forKey: key.name) is NSNumber || Defaults.store.object(forKey: key.name) is String,
                  "\(key.name) is stored natively")
        }
        Defaults.reset(key)
        check(Defaults[key] == key.defaultValue, "\(key.name) resets to its default")
        watcher.cancel()
    }

    roundTrip(.openFilesInTabs, true, native: true)
    roundTrip(.saveBehaviour, .alwaysSaveCopy, native: true)
    roundTrip(.authorName, "Udaya", native: true)
    roundTrip(.defaultZoom, .actualSize, native: true)
    roundTrip(.textSize, .largest, native: true)
    roundTrip(.toolbarTools, [.makeSmaller, .sign])
    roundTrip(.dockMenuTools, [.combineFiles])
    roundTrip(.showRecentlyUsed, false, native: true)
    roundTrip(.showJargonInHints, true, native: true)
    roundTrip(.libreOfficePath, URL(fileURLWithPath: "/Applications/LibreOffice.app"), native: true)
    roundTrip(.addTrustedTimestamp, true, native: true)
    roundTrip(.timestampServer, URL(string: "https://freetsa.org/tsr"), native: true)
    roundTrip(.defaultCertificateID, "0a1b2c", native: true)
    roundTrip(.scanResolution, 600, native: true)
    roundTrip(.scanColorMode, .grayscale, native: true)
    roundTrip(.cleanUpScans, false, native: true)
    roundTrip(.checkForUpdates, false, native: true)
    roundTrip(.pdfServicesOffered, true, native: true)
    check(checked.count == 18, "every key is exercised (\(checked.count) of 18)")

    check(Defaults.Keys.saveBehaviour.defaultValue == .ask, "the first save asks (ux §7.1)")
    check(Defaults.Keys.checkForUpdates.defaultValue && Defaults.Keys.showRecentlyUsed.defaultValue, "updates and the recent row on")
    check(!Defaults.Keys.addTrustedTimestamp.defaultValue && Defaults.Keys.timestampServer.defaultValue == nil,
          "no timestamp server by default (features §3.5 item 4)")
    check(TextSize.allCases.map(\.bodySize) == [13, 15, 17], "text sizes 13 → 15 → 17 (ux §9)")
}

// MARK: - Design tokens (ux §2)

@MainActor
private func coreTokenValues() {
    func pair(_ token: SPColorToken, _ light: String, _ dark: String, _ line: Int = #line) {
        check(token.light == light && token.dark == dark, "\(token.name) is \(light) / \(dark) (line \(line))")
    }
    pair(SPColor.windowBackground, "#ECECEC", "#323232")
    pair(SPColor.sidebar, "#F2F2F2", "#2A2A2A")
    pair(SPColor.underPageBackground, "#E6E6E6", "#1E1E1E")
    pair(SPColor.controlBackground, "#FFFFFF", "#1E1E1E")
    pair(SPColor.separator, "#0000001A", "#FFFFFF1A")
    pair(SPColor.label, "#000000D9", "#FFFFFFD9")
    pair(SPColor.secondaryLabel, "#00000080", "#FFFFFF8C")
    pair(SPColor.tertiaryLabel, "#00000040", "#FFFFFF40")
    pair(SPColor.accent, "#007AFF", "#0A84FF")
    pair(SPColor.destructive, "#FF3B30", "#FF453A")
    pair(SPColor.categoryBlue, "#007AFF", "#0A84FF")
    pair(SPColor.categoryGreen, "#34C759", "#30D158")
    pair(SPColor.categoryOrange, "#FF9500", "#FF9F0A")
    pair(SPColor.categoryYellow, "#FFCC00", "#FFD60A")
    pair(SPColor.categoryPurple, "#AF52DE", "#BF5AF2")
    pair(SPColor.categoryRed, "#FF3B30", "#FF453A")
    pair(SPColor.categoryTeal, "#30B0C7", "#40C8E0")
    pair(SPColor.categoryBrown, "#A2845E", "#AC8E68")
    pair(SPColor.highlightYellow, "#FACD5A", "#5E4613")
    pair(SPColor.highlightGreen, "#7CC868", "#294714")
    pair(SPColor.highlightBlue, "#69B0F1", "#1F3466")
    pair(SPColor.highlightPink, "#FB5C89", "#5E2D42")
    pair(SPColor.highlightPurple, "#C885DA", "#422D61")
    pair(SPColor.noteYellow, "#FFEB6B", "#FFEB6B")
    check(Set(SPColor.all.map(\.name)).count == SPColor.all.count && SPColor.all.count == 25, "25 uniquely named colour tokens")
    let hex = try! NSRegularExpression(pattern: "^#[0-9A-F]{6}([0-9A-F]{2})?$")
    for token in SPColor.all {
        for value in [token.light, token.dark] {
            check(hex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil, "\(token.name): \(value) is #RRGGBB(AA)")
        }
    }
    check(SPColor.accent.system == .controlAccentColor && SPColor.categoryTeal.system == .systemTeal, "semantic system colours draw")
    check(SPColor.highlightYellow.system == nil && NSColor(hex: SPColor.highlightYellow.light).hexRGBA == "#FACD5AFF",
          "markup colours are fixed (Preview's)")
    check(ToolSection.allCases.map(\.color.name) == ["categoryBlue", "categoryGreen", "categoryOrange", "categoryYellow", "categoryPurple",
                                                       "categoryRed", "categoryTeal", "categoryBrown"],
          "section colours in ux §2.3 order")

    // Type (ux §2.2)
    check(SPFont.body.size == 13 && SPFont.body.weight == .regular && SPFont.secondary.size == 11, "body 13, secondary 11")
    check(SPFont.panelTitle == SPTextStyle(15, .semibold) && SPFont.sheetTitle == SPTextStyle(20, .semibold), "titles 15 / 20 semibold")
    check(SPFont.welcomeTitle == SPTextStyle(28, .bold) && SPFont.welcomeSubtitle == SPTextStyle(15), "welcome 28 bold / 15")
    check(SPFont.tileName == SPTextStyle(13, .semibold) && SPFont.tileHint == SPTextStyle(11), "tile 13 semibold / 11")
    check(SPFont.body.font(.larger).pointSize == 15 && SPFont.body.font(.largest).pointSize == 17, "text size scales body")
    check(SPFont.all.allSatisfy { $0.font().familyName == NSFont.systemFont(ofSize: 13).familyName }, "system font only")

    // Metrics (ux §2.1)
    check(SPMetrics.Window.defaultSize == NSSize(width: 1100, height: 760) && SPMetrics.Window.minimumSize == NSSize(width: 640, height: 440),
          "window 1100 × 760, min 640 × 440")
    check(SPMetrics.Window.toolbarHeight == 52 && SPMetrics.Toolbar.toolsButtonHeight == 28 && SPMetrics.Toolbar.searchFieldWidth == 180,
          "toolbar 52, Tools button 28, search 180")
    check(SPMetrics.Sidebar.defaultWidth == 197 && SPMetrics.Sidebar.minimumWidth == 140 && SPMetrics.Sidebar.maximumWidth == 360
          && SPMetrics.Sidebar.bottomBarHeight == 29, "sidebar 197 (140…360), bottom bar 29")
    check(SPMetrics.ToolPanel.width == 320 && SPMetrics.ToolPanel.headerHeight == 52 && SPMetrics.ToolPanel.footerHeight == 76
          && SPMetrics.ToolPanel.contentInset == 20 && SPMetrics.ToolPanel.overlayBelowWindowWidth == 1000, "panel 320, 52/76, inset 20")
    check(SPMetrics.PrimaryButton.height == 36 && SPMetrics.PrimaryButton.radius == 10 && SPMetrics.PrimaryButton.disabledOpacity == 0.4,
          "primary button 36 tall, radius 10, 40% disabled")
    check(SPMetrics.ToolsSheet.size == NSSize(width: 880, height: 620) && SPMetrics.ToolsSheet.columns == 5
          && SPMetrics.Tile.size == NSSize(width: 150, height: 116) && SPMetrics.Tile.iconCircle == 36 && SPMetrics.Tile.symbolSize == 18, "sheet 880 × 620, 5 × 150 × 116 tiles")
    check(SPMetrics.Banner.height == 44 && SPMetrics.Banner.autoHideDelay == 8 && SPMetrics.MarkupBar.height == 31, "banner 44 / 8 s, markup bar 31")
    check(SPMetrics.Organiser.defaultThumbnailWidth == 160 && SPMetrics.Organiser.thumbnailWidthRange == 80...320
          && SPMetrics.Organiser.insertionLine == 3, "organiser 160 (80–320), 3 pt insertion line")
    check(SPMetrics.Welcome.size == NSSize(width: 760, height: 520) && SPMetrics.Welcome.targetSize == NSSize(width: 160, height: 140),
          "welcome 760 × 520, targets 160 × 140")
    check(NSImage(systemSymbolName: SPMetrics.Toolbar.toolsSymbol, accessibilityDescription: nil) != nil, "the Tools symbol exists")

    // Motion (ux §2.5)
    check(SPMotion.sheet == 0.25 && SPMotion.tileStagger == 0.04 && SPMotion.panelOpen == 0.22 && SPMotion.panelContentFadeIn == 0.12,
          "sheet 250 ms, stagger 40 ms, panel 220 ms / 120 ms")
    check(SPMotion.toolSwitch == 0.15 && SPMotion.banner == 0.3 && SPMotion.previewDebounce == 0.08 && SPMotion.pageRotate == 0.25,
          "switch 150 ms, banner 300 ms, preview 80 ms, rotate 250 ms")
    check(SPMotion.thumbnailShift == SPSpring(response: 0.3, dampingFraction: 0.8) && SPMotion.dragLiftScale == 1.05, "drag spring")
}

// MARK: - Tool catalog (ux §4.1)

@MainActor
private func coreToolCatalog() {
    let tiles = ToolCatalog.tiles
    check(tiles.count == 52, "52 tiles (\(tiles.count))")
    check(Set(tiles.map(\.id)) == Set(ToolID.allCases) && tiles.map(\.id) == ToolID.allCases, "every ToolID once, in catalogue order")
    check(Set(tiles.map(\.name)).count == tiles.count, "unique names")
    check(tiles.map(\.section).reduce(into: [ToolSection]()) { if $0.last != $1 { $0.append($1) } } == ToolSection.allCases,
          "sections contiguous, in the order of a document's life")
    check(ToolSection.allCases.map { ToolCatalog.tiles(in: $0).count } == [11, 8, 8, 5, 5, 5, 7, 3], "tiles per section")
    for tile in tiles {
        check(!tile.name.isEmpty && !tile.hint.isEmpty, "\(tile.id): name and hint")
        check(followsTone(tile.name) && followsTone(tile.hint), "\(tile.id): curly quotes, real ellipsis")
        check(tile.name.first?.isUppercase == true, "\(tile.id): starts with a capital")
        check(!tile.synonyms.isEmpty && tile.synonyms.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty }, "\(tile.id): synonyms lower-cased")
        check(Set(tile.synonyms).count == tile.synonyms.count, "\(tile.id): no repeated synonym")
        check(!tile.features.isEmpty && tile.features.allSatisfy { (1...124).contains($0) }, "\(tile.id): features.md numbers")
        check(NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil) != nil, "\(tile.id): SF Symbol \(tile.symbol) exists")
        check(![.documentKit, .toolsKit, .settingsKit].contains(tile.owner), "\(tile.id): owned by a tool module")
        check(ToolCatalog.tile(tile.id) == tile, "\(tile.id): lookup")
    }
    check(Set(tiles.map(\.symbol)).count == tiles.count, "one symbol per tile")
    check(Set(tiles.filter { !$0.needsDocument }.map(\.id))
          == [.combineFiles, .imagesToPDF, .anyFileToPDF, .manyFiles, .scanWithIPhone, .scanWithScanner, .fromPhoto],
          "tools that start from files")
    // Archetypes of ux §5.2.
    let archetypes: [ToolID: ToolArchetype] = [
        .rotatePages: .oneChoice, .deletePages: .oneChoice, .extractPages: .oneChoice, .lockIn: .oneChoice, .removePassword: .oneChoice,
        .repair: .oneChoice, .readAloud: .oneChoice, .makeSmaller: .presetAndMore, .forArchiving: .presetAndMore, .toImages: .presetAndMore,
        .split: .presetAndMore, .booklet: .presetAndMore, .resizePages: .presetAndMore, .watermark: .livePreview,
        .headersAndFooters: .livePreview, .numberPages: .livePreview, .batesNumbering: .livePreview, .crop: .livePreview,
        .stamps: .livePreview, .links: .livePreview, .editTextAndImages: .mode, .drawAndShapes: .mode, .highlightAndNotes: .mode,
        .fillForm: .mode, .makeForm: .mode, .measure: .mode, .blackOut: .mode, .sign: .mode, .rearrangePages: .mode,
        .compareFiles: .mode, .toWord: .convert, .toExcel: .convert, .toPowerPoint: .convert, .toTextOrWeb: .convert,
        .anyFileToPDF: .convert, .imagesToPDF: .convert, .combineFiles: .convert, .requestSignatures: .flow,
        .scanWithIPhone: .flow, .scanWithScanner: .flow, .fromPhoto: .flow, .certificates: .flow,
    ]
    for (id, archetype) in archetypes { check(ToolCatalog.tile(id).archetype == archetype, "\(id) is archetype \(archetype.letter)") }
    // Spot checks against ux §4.1.
    let smaller = ToolCatalog.tile(.makeSmaller)
    check(smaller.name == "Make smaller" && smaller.hint == "Shrink the file so it’s easier to send" && smaller.section == .fixAndCheck
          && smaller.synonyms.contains("compress") && smaller.features == [91] && smaller.owner == .fixKit, "Make smaller row")
    check(ToolCatalog.tile(.watermark).hint == "Stamp “Draft” or a logo across every page", "watermark hint keeps its curly quotes")
    check(ToolCatalog.tile(.anyFileToPDF).features == Array(35...49), "Any file → PDF covers #35–#49")
    check(ToolCatalog.tiles(ownedBy: .pagesKit).count == 11 && ToolCatalog.tiles(ownedBy: .viewerKit).map(\.id) == [.contents, .readAloud],
          "ownership by module")
    // Menu titles (ux §4: Tools › Pages › Rotate Pages…).
    check(ToolCatalog.tile(.rotatePages).menuTitle == "Rotate Pages…", "Rotate Pages…")
    check(ToolCatalog.tile(.scanWithIPhone).menuTitle == "Scan with iPhone…", "iPhone keeps its case")
    check(ToolCatalog.tile(.blackOut).menuTitle == "Black Out…" && ToolCatalog.tile(.lockIn).menuTitle == "Lock In Notes & Fields…",
          "particles are capitalised")
    check(ToolCatalog.tile(.manyFiles).menuTitle == "Do This to Many Files…" && ToolCatalog.tile(.forArchiving).menuTitle == "For Archiving (PDF/A)…",
          "minor words stay lower case")
}

// MARK: - Strings (ux §3, §4, §7)

@MainActor
private func coreStrings() {
    let banners: [ResultBanner] = [
        Strings.Banner.madeSmaller(before: 6_100_000, after: 1_700_000), Strings.Banner.recognised(pages: 14),
        Strings.Banner.blackedOut(items: 12, pages: 5, fileName: "Report (blacked out).pdf"), Strings.Banner.combined(files: 3, pages: 41),
        Strings.Banner.saved("Report.docx", openIn: "Word"), Strings.Banner.savedImages(12, folder: "Report images"),
        Strings.Banner.savedFiles(4, folder: "Report parts"), Strings.Banner.archived("Report (archive).pdf", level: .a2b, unfixed: 0),
        Strings.Banner.archived("Report (archive).pdf", level: .a2b, unfixed: 2), Strings.Banner.protected("Report (protected).pdf"),
        Strings.Banner.signed("Contract (signed).pdf"), Strings.Banner.requestSent(people: 2),
    ]
    check(banners[0].text == "Done. The file is 72% smaller (6.1 MB → 1.7 MB)." && banners[0].emphasis == ["72%", "6.1 MB", "1.7 MB"]
          && banners[0].actions == [.showInFinder, .share, .undo], "make smaller banner (\(banners[0].text))")
    check(banners[1].text == "Recognised 14 pages. You can now search and copy the text." && banners[1].actions == [.undo], "OCR banner")
    check(banners[2].text == "Blacked out 12 items on 5 pages and saved “Report (blacked out).pdf”.", "black out banner")
    check(banners[3].text == "Combined 3 files into 41 pages." && banners[3].actions == [.save], "combine banner")
    check(banners[4].text == "Saved “Report.docx”." && banners[4].actions == [.openIn(appName: "Word"), .showInFinder]
          && banners[4].actions[0].title == "Open in Word", "convert banner")
    check(banners[5].text == "Saved 12 images in “Report images”." && banners[6].text == "Saved 4 files in “Report parts”.", "folder banners")
    check(banners[7].text == "Saved “Report (archive).pdf”. It passes the PDF/A-2b check.", "PDF/A banner")
    check(banners[8].text == "Saved “Report (archive).pdf”. 2 things couldn’t be fixed." && banners[8].actions == [.showDetails], "PDF/A problems")
    check(banners[9].text == "Saved “Report (protected).pdf”. Keep the password somewhere safe.", "password banner")
    check(banners[10].text == "Signed and saved “Contract (signed).pdf”." && banners[10].actions == [.share], "sign banner")
    check(banners[11].text == "Sent to 2 people. We’ll match their files when they come back." && banners[11].actions == [.showRequests],
          "request banner")
    check(Strings.Banner.requestSent(people: 1).text.hasPrefix("Sent to 1 person."), "singular")

    let copy: [String] = banners.map(\.text) + banners.flatMap(\.actions).map(\.title) + [
        Strings.ToolsSheet.title, Strings.ToolsSheet.searchPlaceholder, Strings.ToolsSheet.recentlyUsed, Strings.ToolsSheet.noResults("pdf"),
        Strings.ToolsSheet.badgeNeedsDevice, Strings.ToolsSheet.badgeInstallConverter, Strings.ToolsSheet.addToToolbar,
        Strings.ToolsSheet.addToDockMenu, Strings.ToolsSheet.allTools, Strings.Panel.moreOptions, Strings.Panel.change,
        Strings.Panel.savesNextToOriginal("Report (smaller).pdf"), Strings.Panel.progress(page: 14, of: 120),
        Strings.Drop.addPages(3), Strings.Drop.cantAddFolder, Strings.Drop.combineFiles(3), Strings.Save.title("Report.pdf"),
        Strings.Save.saveCopy, Strings.Save.closeMessage, Strings.Save.reviewChanges, Strings.Errors.passwordPrompt,
        Strings.Errors.invalidPassword, Strings.Errors.ownerRestricted(.printing), Strings.Errors.damaged("Report.pdf"),
        Strings.Errors.repaired("Report.pdf"), Strings.Errors.notConvertible("sketch"),
        Strings.Errors.needsLibreOffice(kind: "Spreadsheets", fileExtension: "ods"), Strings.Errors.needsOfficeApp(.excel),
        Strings.Errors.iWorkMissing(.pages), Strings.Errors.noIPhone, Strings.Errors.noScanner,
        Strings.Errors.fontMissing("Garamond Premier", substitute: "Georgia"), Strings.Errors.lastPage, Strings.Errors.redactConfirm(items: 12),
        Strings.Errors.conversionFailed("Budget.xlsx"), Strings.Errors.signatureInvalid, Strings.Errors.formHasScripts, Strings.Errors.xfaForm,
        Strings.Empty.welcomeRecents, Strings.Empty.tableOfContents, Strings.Empty.highlightsAndNotes, Strings.Empty.attachments,
        Strings.Empty.searchNoResults("lease"), Strings.Empty.commentsUnresolved, Strings.Empty.signatureRequests, Strings.Empty.compare,
    ] + ConverterEngineSamples.all.map(Strings.Panel.engineLine)
    for text in copy { check(followsTone(text), "tone: \(text)") }

    // Exact copy of ux §7.
    check(Strings.ToolsSheet.noResults("pdf") == "Nothing called “pdf”. Try “smaller”, “sign” or “Word”.", "no-results copy")
    check(Strings.Errors.ownerRestricted(.printing)
          == "This file doesn’t allow printing. If you know the owner password you can remove the limit.", "owner restriction copy")
    check(Strings.Errors.damaged("Report.pdf") == "“Report.pdf” couldn’t be opened. It may be damaged. We can try to repair it.", "damaged copy")
    check(Strings.Errors.needsLibreOffice(kind: "Spreadsheets", fileExtension: "ods")
          == "Spreadsheets saved as “.ods” need the free Office converter (LibreOffice, about 800 MB).", "LibreOffice copy")
    check(Strings.Errors.needsOfficeApp(.excel) == "To convert this with full fidelity, Excel needs to open it briefly.", "Office app copy")
    check(Strings.Errors.redactConfirm(items: 12) == "This permanently removes 12 items from the new file. Your original stays as it is.",
          "redact confirm copy")
    check(Strings.Save.title("Report.pdf") == "Save changes to “Report.pdf”?" && Strings.Save.saveCopy == "Save a copy…", "save sheet copy")
    check(Strings.Panel.scope(.all, pageCount: 12) == "All 12 pages" && Strings.Panel.scope(.current, pageCount: 12) == "This page"
          && Strings.Panel.scope(.selected([1, 2, 3, 4]), pageCount: 12) == "Selected pages"
          && Strings.Panel.scope(.ranges(PageRanges([2...4])), pageCount: 12) == "3–5", "scope popup titles")
    check(Strings.Panel.savesOriginalUntouched("Lease agreement (signed).pdf")
          == "Saves “Lease agreement (signed).pdf” · the original is untouched", "untouched output line")
    check(Strings.Panel.engineLine(.app(.pages)) == "Pages will open to export this file"
          && Strings.Panel.engineLine(.libreOffice) == "Converted by: LibreOffice", "engine lines (ux §5.3)")
    check(ToolAvailability.needsDevice.badge == "Needs iPhone nearby" && ToolAvailability.needsConverter.badge == "Install converter"
          && ToolAvailability.ready.badge == nil, "badges (ux §4)")
    check(Formatting.percentSaved(before: 100, after: 100) == 0 && Formatting.percentSaved(before: 0, after: 0) == 0, "no gain is 0%")
}

/// One engine of each kind, for the engine-line copy check.
private enum ConverterEngineSamples {
    static let all: [ConverterEngine] = [.builtIn(.attributedText), .libreOffice, .app(.word), .printFromOwningApp]
}

// MARK: - Converter registry (features §3.2)

@MainActor
private func coreConverterTable() {
    let inputs = ConverterTable.toPDF.flatMap(\.inputs)
    check(Set(inputs).count == inputs.count, "no extension in two routes")
    check(inputs.allSatisfy { $0 == $0.lowercased() && !$0.hasPrefix(".") }, "extensions lower-case, no dot")
    check(ConverterTable.toPDF.allSatisfy { !$0.engines.isEmpty && $0.output == .pdf }, "every route has engines into PDF")
    check(ConverterTable.engines(forExtension: "DOCX") == [.builtIn(.attributedText), .libreOffice, .app(.word)], "docx ranking")
    check(ConverterTable.engines(forExtension: "xls") == [.libreOffice, .app(.excel)], "xls has no built-in reader")
    check(ConverterTable.engines(forExtension: "pages") == [.app(.pages), .builtIn(.iWorkPreview)], "iWork: the app first")
    check(ConverterTable.engines(forExtension: "hwpx") == [.libreOffice, .builtIn(.hwpx)], "hwpx: LibreOffice then own reader")
    check(ConverterTable.engines(forExtension: "ods") == [.libreOffice], "ods needs LibreOffice")
    check(ConverterTable.engines(forExtension: "html") == [.builtIn(.webKit), .libreOffice], "HTML through WebKit")
    check(ConverterTable.engines(forExtension: "sketch") == ConverterTable.fallback, "unknown types fall back to Quick Look")
    let outputs = ConverterTable.fromPDF.map(\.output)
    check(Set(outputs).count == outputs.count && Set(outputs) == Set(ConversionFormat.allCases).subtracting([.pdf]),
          "one native route out of PDF per format")
    check(ConverterTable.fromPDF.allSatisfy { $0.inputs == ["pdf"] && $0.engines.count == 1 && $0.engines.allSatisfy {
        if case .builtIn = $0 { true } else { false }
    } }, "PDF → anything is always native")
    check(ConverterTable.engines(forExtension: "pdf", to: .docx) == [.builtIn(.wordWriter)], "PDF → Word")
    check(OfficeApp.allCases.allSatisfy { $0.bundleIdentifier.contains(".") && !$0.name.isEmpty }, "office apps named")
}

// MARK: - Menus and shortcuts (ux §8)

@MainActor
private func coreMenus() {
    check(MenuTree.main.map(\.title) == ["Super PDF", "File", "Edit", "View", "Go", "Tools", "Window", "Help"], "menu bar order")
    let items = MenuTree.main.flatMap(\.entries).flatMap(\.items)
    let chords = MenuTree.shortcuts.map(\.shortcut)
    let duplicates = Dictionary(grouping: chords, by: { $0 }).filter { $1.count > 1 }.keys.map(\.description)
    check(duplicates.isEmpty, "no chord used twice in the menus: \(duplicates)")
    check(Set(items.map(\.command)).count == items.count, "every command once")
    func chord(_ command: MenuCommand) -> String? { items.first { $0.command == command }?.shortcut?.description }
    check(chord(.allTools) == "⌘T" && chord(.pageOrganiser) == "⌥⌘6" && chord(.saveACopy) == "⇧⌘S", "new shortcuts (ux §8)")
    check(chord(.rotateLeft) == "⌘L" && chord(.rotateRight) == "⌘R" && chord(.cropPage) == "⌘K" && chord(.addBookmark) == "⌘D",
          "Preview's Tools shortcuts")
    check(chord(.hideSidebar) == "⌥⌘1" && chord(.thumbnails) == "⌥⌘2" && chord(.contactSheet) == "⌥⌘7" && chord(.continuousScroll) == "⌘1",
          "View shortcuts")
    check(chord(.goToPage) == "⌥⌘G" && chord(.previousItem) == "⌥↑" && chord(.back) == "⌘[", "Go shortcuts")
    check(chord(.highlightText) == "⌃⌘H" && chord(.loupe) == "⌃⌘L" && chord(.showMarkupToolbar) == "⇧⌘A", "markup shortcuts (ux §6.4)")
    check(chord(.showMagnifier) == "`" && chord(.slideshow) == "⇧⌘F" && chord(.enterFullScreen) == "⌃⌘F", "magnifier, slideshow")
    // Tools › one submenu per section with every tile.
    let toolItems = items.compactMap { item in item.command.tool.map { (item.title, $0) } }
    check(toolItems.map(\.1) == ToolID.allCases && toolItems.allSatisfy { $0.0 == ToolCatalog.tile($0.1).menuTitle },
          "every tile in the Tools menu, titled")
    check(MenuTree.toolSections.count == ToolSection.allCases.count, "a submenu per section")
    check(MenuCommand.tool(.makeSmaller).rawValue == "tool.make-smaller" && MenuCommand("tool.make-smaller").tool == .makeSmaller
          && MenuCommand.open.tool == nil, "tool commands round-trip")
    check(items.allSatisfy { followsTone($0.title) && ($0.title.hasSuffix("…") || !$0.title.hasSuffix(".")) }, "menu titles: real ellipsis")
    // Context shortcuts.
    let sheet = ContextShortcut.all.filter { $0.context == .toolsSheet && $0.combo.modifiers == .command }
    check(sheet.map(\.combo.description) == (1...8).map { "⌘\($0)" } && sheet.map(\.title) == ToolSection.allCases.map(\.title),
          "⌘1–8 jump to sections in the sheet")
    check(KeyCombo(KeyCombo.deleteKey, []).description == "⌫" && KeyCombo("-").description == "⌘−", "key names")
    check(KeyModifiers([.control, .option, .shift, .command]).symbols == "⌃⌥⇧⌘", "modifier order")
}

// MARK: - Pages, scope and output names (ux §5.1, §7.2)

@MainActor
private func corePagesAndNaming() {
    let ranges = PageRanges.parse("1-3, 7, 12–9", pageCount: 12)
    check(ranges?.ranges == [0...2, 6...6, 8...11] && ranges?.indices == [0, 1, 2, 6, 8, 9, 10, 11], "ranges parse 1-based, reversed fixed")
    check(ranges?.display == "1–3, 7, 9–12", "ranges display with en dashes")
    check(PageRanges.parse("0", pageCount: 3) == nil && PageRanges.parse("2-9", pageCount: 3) == nil
          && PageRanges.parse("x", pageCount: 3) == nil && PageRanges.parse(" ", pageCount: 3) == nil, "bad ranges rejected")
    check(PageRanges.parse("2,2", pageCount: 3)?.indices == [1], "repeats once")
    check(Scope.all.pages(count: 3, current: 1) == [0, 1, 2] && Scope.current.pages(count: 3, current: 1) == [1], "all, this page")
    check(Scope.selected([5, 2, 2, 0]).pages(count: 4, current: 0) == [0, 2], "selection sorted, unique, in range")
    check(Scope.ranges(PageRanges([1...9])).pages(count: 4, current: 0) == [1, 2, 3], "ranges clipped")

    check(OutputSuffix.smaller.fileName(base: "Report", ext: "pdf") == "Report (smaller).pdf", "Report (smaller).pdf")
    check(OutputSuffix.blackedOut.fileName(base: "Report", ext: "pdf") == "Report (blacked out).pdf", "blacked out")
    check(OutputSuffix.noPassword.fileName(base: "Report", ext: "pdf") == "Report (no password).pdf", "no password")
    check(OutputSuffix.edited.fileName(base: "Report", ext: "pdf") == "Report (edited).pdf", "edited (ux §7.1)")
    check(OutputSuffix.part(1).fileName(base: "Report", ext: "pdf") == "Report – part 1.pdf", "Split parts (ux §5.3)")
    check(OutputSuffix.pages(PageRanges([2...4])).fileName(base: "Report", ext: "pdf") == "Report – pages 3-5.pdf", "page drags (ux §3)")
    check(OutputFolder.parts.folderName(base: "Report") == "Report parts" && OutputFolder.images.folderName(base: "Report") == "Report images",
          "output folders")
    let suffixes: [OutputSuffix] = [.edited, .smaller, .blackedOut, .protected, .noPassword, .lockedIn, .signed, .archive, .clean, .repaired]
    check(suffixes.map(\.word) == ["edited", "smaller", "blacked out", "protected", "no password", "locked in", "signed", "archive", "clean",
                                   "repaired"], "ux §7.2 suffix words")
}

// MARK: - Value types

@MainActor
private func coreValueTypes() {
    check(PageNumberStyle.allCases.map { $0.text(1, of: 12) } == ["1", "Page 1", "Page 1 of 12", "– 1 –", "i", "A-1"], "number styles")
    check(PageNumberStyle.roman(4) == "iv" && PageNumberStyle.roman(1994) == "mcmxciv" && PageNumberStyle.roman(0) == "0", "roman numerals")
    check(BatesNumbering(prefix: "ABC", suffix: "-X").label(42) == "ABC000042-X" && BatesNumbering(digits: 2).label(1234) == "1234",
          "Bates labels")
    let scale = MeasureScale(pageDistance: 72, realDistance: 10, unit: .m)
    check(scale.length(144) == 20 && scale.area(72 * 72) == 100 && MeasureScale(pageDistance: 0).length(10) == 0, "measure maths")
    check(PaperSize.a4.size == CGSize(width: 595.28, height: 841.89) && PaperSize.fitContent.size == nil, "paper sizes")
    check(PDFALevel.a2a.requiresTags && !PDFALevel.a2b.requiresTags && !PDFALevel.a2u.requiresTags && PDFALevel.a2b.title == "PDF/A-2b",
          "PDF/A levels")
    check(Imposition.nUp(4) != .booklet && PDFXLevel.x4.title == "PDF/X-4", "imposition and PDF/X")
    check(DocumentPermissions.all.isRestricted == false && DocumentPermissions(printing: .none).isRestricted, "permissions")

    var values = ToolValues()
    values["n"] = .int(3); values["on"] = .bool(true); values["name"] = .string("DRAFT"); values["files"] = .files([URL(fileURLWithPath: "/a")])
    check(values.int("n") == 3 && values.double("n") == 3 && values.bool("on") && values.string("name") == "DRAFT"
          && values.files("files").count == 1 && values.int("missing", default: 7) == 7 && values.strings("n").isEmpty, "typed accessors")
    let panel = ToolPanel(.livePreview, controls: [
        .text(id: "text", label: nil, placeholder: "", value: "DRAFT", isSecure: false),
        .slider(id: "lightness", label: "Lightness", range: 0...100, step: 1, value: 30, format: .percent),
        .note("Now: 6.1 MB"),
    ], moreOptions: [.positionGrid(id: "position", columns: 3, rows: 3, selected: 4), .toggle(id: "print", label: "Only when printing", isOn: false)],
       primary: ToolButton("Add watermark"))
    check(panel.initialValues == ToolValues(["text": .string("DRAFT"), "lightness": .double(30), "position": .int(4), "print": .bool(false)]),
          "a panel's initial values")
    check(panel.secondary?.title == "Cancel" && panel.output == .inPlace, "panel defaults: Cancel, in place")

    let progressBox = ProgressBox()
    let progress = ToolProgress { update in progressBox.append(update) }
    progress.report(completed: 14, of: 120, page: 13)
    check(progressBox.updates.first?.fraction == 14.0 / 120 && progressBox.updates.first?.page == 13, "progress updates")

    let alice = Signer(name: "Alice", email: "a@example.com", color: "#FF9500", order: 1)
    let bob = Signer(name: "Bob", email: "b@example.com", color: "#007AFF", order: 0)
    var request = SignatureRequest(documentName: "Lease", signers: [alice, bob], signInOrder: true)
    check(request.manifest.signers.map(\.name) == ["Bob", "Alice"] && request.manifest.requestID == request.id
          && SigningPackageManifest.attachmentName == "request.json", "manifest in signing order")
    check(!request.isComplete, "not complete while waiting")
    request.signers = request.signers.map { var s = $0; s.state = .done; return s }
    check(request.isComplete && !SignatureRequest(documentName: "x", signers: []).isComplete, "complete when everyone signed")
}

/// Collects progress updates from any thread.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolProgress.Update] = []
    func append(_ update: ToolProgress.Update) { lock.withLock { stored.append(update) } }
    var updates: [ToolProgress.Update] { lock.withLock { stored } }
}

// MARK: - Codable (fixtures, routines, view state, packages)

@MainActor
private func coreCodable() {
    let layout = LayoutDocument(pages: [LayoutPage(index: 0, size: CGSize(width: 612, height: 792), blocks: [
        LayoutBlock(id: 0, kind: .heading(level: 1), bounds: CGRect(x: 72, y: 700, width: 300, height: 24),
                    lines: [LayoutLine(words: [LayoutWord(text: "Lease", bounds: CGRect(x: 72, y: 700, width: 60, height: 24), fontSize: 24, isBold: true)],
                                       bounds: CGRect(x: 72, y: 700, width: 60, height: 24), baseline: 704)]),
        LayoutBlock(id: 1, kind: .listItem(level: 0, marker: "•"), bounds: .zero, lines: []),
    ], tables: [LayoutTable(id: 0, bounds: .zero, rowCount: 1, columnCount: 2,
                            cells: [LayoutTableCell(row: 0, column: 0, bounds: .zero, text: "Rent"), LayoutTableCell(row: 0, column: 1, bounds: .zero, text: "900")])],
       figures: [LayoutFigure(id: 0, kind: .image, bounds: .zero)], readingOrder: [.block(0), .table(0), .figure(0), .block(1)])])
    check(roundTrips(layout), "LayoutDocument")
    check(layout.pages[0].text == "Lease\n\nRent\t900\n\n", "page text in reading order")
    check(roundTrips(Routine(name: "OCR, compress, PDF/A", pipeline: BatchPipeline(steps: [
        BatchStep(tool: .recogniseText), BatchStep(tool: .makeSmaller, values: ToolValues(["preset": .string("email")])), BatchStep(tool: .forArchiving),
    ]))), "Routine")
    check(roundTrips(SignatureRequest(documentName: "Lease", signers: [Signer(name: "A", email: "a@x", color: "#FF0000", order: 0)],
                                      fields: [RequestField(kind: .initials, signerID: UUID(), page: 2, rect: CGRect(x: 1, y: 2, width: 3, height: 4))])),
          "SignatureRequest")
    check(roundTrips(DocumentViewState(pageIndex: 4, scale: 1.5, displayMode: .twoPages, sidebarMode: .tableOfContents)), "view state")
    check(roundTrips(Decoration.headerFooter(HeaderFooter(fields: [.topLeft: [.text("Lease – "), .pageNumber], .bottomRight: [.date]]))),
          "header and footer")
    check(roundTrips(Decoration.watermark(Watermark(content: .text("DRAFT", DecorationStyle(fontSize: 72))))), "watermark")
    check(roundTrips(Scope.ranges(PageRanges([0...2]))) && roundTrips(Scope.selected([1, 3])), "scope")
    check(roundTrips(OutputPolicy.sibling(.pages(PageRanges([2...4])), ext: "pdf")) && roundTrips(OutputPolicy.folder(.parts)), "output policy")
    check(roundTrips(ConversionJob(inputs: [URL(fileURLWithPath: "/a.docx")], output: .pdf, engine: .app(.word), paper: .custom(width: 100, height: 200),
                                   destination: URL(fileURLWithPath: "/a.pdf"))), "conversion job")
    check(roundTrips(FormField(id: "Total", kind: .number, page: 0, bounds: .zero, scripts: [.calculate: "AFSimple_Calculate(\"SUM\", [\"A\"])"])),
          "form field with scripts")
    check(roundTrips(CertificateSignOptions(identityID: "x", rect: CGRect(x: 1, y: 1, width: 2, height: 2), lockDocument: true)), "sign options")
    check(roundTrips(ToolValues(["a": .strings(["x"]), "b": .double(0.5)])) && roundTrips([ToolID.makeSmaller, .sign]), "values, ids")
    let manifest = SignatureRequest(documentName: "x", signers: [Signer(name: "A", email: "a@x", color: "#000000", order: 0)]).manifest
    check(roundTrips(manifest) && manifest.version == 1, "package manifest")
    check(ToolID.allCases.allSatisfy { ToolID(rawValue: $0.rawValue) == $0 && !$0.rawValue.contains(" ") }, "stable tool raw values")
}

// MARK: - Undo (features §2.3)

@MainActor
private func coreUndo() {
    let manager = UndoManager()
    manager.groupsByEvent = false
    var value = 1
    manager.beginUndoGrouping()
    value = 2
    manager.register(UndoGroup("Change Value", undo: { value = 1 }, redo: { value = 2 }))
    manager.endUndoGrouping()
    check(manager.undoActionName == "Change Value", "action name")
    manager.undo()
    check(value == 1 && manager.canRedo, "undo")
    manager.redo()
    check(value == 2 && manager.canUndo, "redo")
    manager.undo()
    check(value == 1, "undo again")

    var log: [String] = []
    let combined = UndoGroup.combined("Insert 2 Pages", [UndoGroup("a", undo: { log.append("-a") }, redo: { log.append("+a") }),
                                                          UndoGroup("b", undo: { log.append("-b") }, redo: { log.append("+b") })])
    combined.undo(); combined.redo()
    check(log == ["-b", "-a", "+a", "+b"] && combined.actionName == "Insert 2 Pages", "combined groups undo last to first")
    let contents = UndoGroup("Recognise Text", .contents(before: Data([1]), after: Data([2])))
    let other = UndoManager()
    other.register(contents)
    check(!other.canUndo, "contents changes are DocumentKit's to register")
}

// MARK: - Documents

@MainActor
private func coreDocuments() {
    let url = SuperPDFPaths.work.appendingPathComponent("selftest-\(UUID().uuidString).pdf")
    try? makePDF(pages: 3).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, password: "pw")
    check(document.displayName == url.deletingPathExtension().lastPathComponent && document.pageCount == 3, "name and pages")
    check(document.snapshot() == .file(url, password: "pw"), "an unedited document hands engines its file")
    document.state.isEdited = true
    if case .data(let data, let password) = document.snapshot() {
        check(PDFDocument(data: data)?.pageCount == 3 && password == "pw", "an edited one hands PDFKit's bytes")
    } else {
        check(false, "edited snapshot is data")
    }
    check((try? PDFSource.file(url).bytes())?.isEmpty == false, "file sources read")
    check(DocumentState().origin == .opened && !DocumentState().isLocked && PageRef(documentID: document.id, index: 2).number == 3, "defaults")
    check(SuperPDFPaths.support.path.hasPrefix(SuperPDFPaths.base.path) && SuperPDFPaths.request(UUID()).path.contains("/Requests/"),
          "paths live under the scratch base")
}

// MARK: - Fakes

@MainActor
private func coreFakes() {
    installFakes()
    check(Services.documents != nil && Services.tools != nil && Services.viewer != nil && Services.updates != nil && Services.fix != nil,
          "every slot filled")
    let document = makeDocument(pages: 3)
    check(document.pageCount == 3 && document.pdf.page(at: 1)?.string?.contains("Page 2") == true, "generated PDF")

    // Page edits register undo through the document's undo manager.
    if case .success(let group)? = complete(60, { try await Services.pages.perform(.rotate([0, 2], quarterTurns: 1), in: document) }) {
        document.undoManager?.beginUndoGrouping()
        document.undoManager?.register(group)
        document.undoManager?.endUndoGrouping()
        check(document.pdf.page(at: 0)?.rotation == 90 && document.pdf.page(at: 1)?.rotation == 0, "rotate")
        document.undoManager?.undo()
        check(document.pdf.page(at: 0)?.rotation == 0 && document.pdf.page(at: 2)?.rotation == 0, "undo rotate")
        document.undoManager?.redo()
        check(document.pdf.page(at: 2)?.rotation == 90, "redo rotate")
    } else {
        check(false, "rotate ran")
    }
    if case .failure(let error)? = complete(60, { try await Services.pages.perform(.delete([0, 1, 2]), in: document) }) {
        check(error as? PageEditError == .lastPage && error.localizedDescription == "A PDF needs at least one page.", "never the last page")
    } else {
        check(false, "deleting every page throws")
    }

    // Output names next to the original, " 2" on collisions.
    let folder = SuperPDFPaths.work.appendingPathComponent("names-\(UUID().uuidString)", isDirectory: true)
    SuperPDFPaths.ensure(folder)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("Report.pdf")
    try? makePDF(pages: 1).write(to: original)
    let opened = DocumentHandle(url: original, pdf: PDFDocument(url: original)!)
    let first = Services.documents.destination(for: .sibling(.smaller, ext: "pdf"), of: opened, source: nil)
    check(first?.lastPathComponent == "Report (smaller).pdf", "Report (smaller).pdf")
    try? Data().write(to: first!)
    check(Services.documents.destination(for: .sibling(.smaller, ext: "pdf"), of: opened, source: nil)?.lastPathComponent
          == "Report (smaller) 2.pdf", "collision gets “ 2”")
    check(Services.documents.destination(for: .inPlace, of: opened, source: nil) == nil, "in place has no destination")

    // A tool result applied: a new unsaved document.
    let request = ToolRequest(tool: .combineFiles, workFolder: folder)
    _ = complete(60, { try await Services.documents.apply(.newDocument(makePDF(pages: 2), name: "Combined", banner: nil), of: request) })
    check(Services.documents.frontmost?.displayName == "Combined" && Services.documents.frontmost?.state.origin == .createdHere,
          "Combined opens unsaved")

    // Providers are collected by the registry.
    let provider = FakeToolProvider([.rotatePages])
    Services.toolProviders.append(provider)
    (Services.tools as? FakeTools)?.collect()
    check(Services.tools.provider(for: .rotatePages) === provider && Services.tools.provider(for: .crop) == nil, "provider lookup")
    let context = ToolContext(tool: .rotatePages, document: document)
    check(provider.panel(for: .rotatePages, context: context).primary.title == "Rotate pages" && provider.availability(of: .rotatePages) == .ready,
          "provider panel and default availability")
    check(Services.tools.search("compress").first?.id == .makeSmaller && Services.tools.search("merge").first?.id == .combineFiles,
          "fake search finds synonyms")

    check(FakeAFEmulator().run("AFSimple_Calculate(\"SUM\", [\"A\", \"B\"])", action: .calculate, value: "", fields: ["A": "2", "B": "3"])
          == .value("5"), "AF sum emulation")
}
