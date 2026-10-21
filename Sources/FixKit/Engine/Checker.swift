import CoreGraphics
import Foundation
import NaturalLanguage
import PDFModelKit
import RenderKit
import SuperPDFCore

// The checks of "Check accessibility" (features #97), "Check for printing" (#94) and the PDF/A verifier (#93), each a
// list of `CheckIssue`s (passed ones too, so the panel can group Pass / Needs attention / Failed), and the automatic
// fixes they offer. Everything reads the file through QPDF (and Quartz for colour use); accessibility also reads
// LayoutKit's analysis for language, contrast, headings and figures.

enum Checker {
    // MARK: Accessibility

    /// The language a fix would set: the text's dominant language, else the Mac's.
    struct Language: Hashable {
        var code: String
        var name: String
    }

    struct AccessibilityReport {
        var issues: [CheckIssue]
        /// Pictures that can take a description.
        var figures: [FigureRef]
        var language: Language
    }

    static func accessibility(_ model: PDFModel, layout: LayoutDocument?) -> AccessibilityReport {
        typealias A = FixStrings.Accessibility
        let root = model.root
        var issues: [CheckIssue] = []
        let pageCount = model.pageCount

        let hasTitle = !(title(of: model) ?? "").isEmpty
        issues.append(hasTitle ? CheckIssue(id: "title", severity: .passed, title: A.hasTitle)
                               : CheckIssue(id: "title", severity: .failed, title: A.noTitle, fixTitle: A.addTitle))

        let language = detectLanguage(layout)
        let hasLanguage = !(root["Lang"]?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        issues.append(hasLanguage ? CheckIssue(id: "language", severity: .passed, title: A.hasLanguage)
                                  : CheckIssue(id: "language", severity: .failed, title: A.noLanguage, fixTitle: A.setLanguage(language.name)))

        let tagged = isTagged(model)
        issues.append(tagged ? CheckIssue(id: "tags", severity: .passed, title: A.tagged)
                             : CheckIssue(id: "tags", severity: .failed, title: A.untagged, pages: Array(0..<pageCount), fixTitle: A.tag))
        issues.append(tagged ? CheckIssue(id: "reading-order", severity: .passed, title: A.readingOrder)
                             : CheckIssue(id: "reading-order", severity: .failed, title: A.noReadingOrder))

        // Pictures: Figure elements on a tagged file, LayoutKit's picture figures otherwise.
        let figures: [FigureRef] = tagged ? AutoTagger.figures(in: model).map(\.ref)
            : (layout?.pages ?? []).flatMap { page in
                page.figures.filter { $0.kind == .image }.map { FigureRef(key: "l:\(page.index):\($0.id)", page: page.index, hasDescription: false) }
            }
        let undescribed = figures.filter { !$0.hasDescription }
        issues.append(undescribed.isEmpty ? CheckIssue(id: "alt-text", severity: .passed, title: A.described)
                                          : CheckIssue(id: "alt-text", severity: .failed, title: A.undescribed(undescribed.count),
                                                       pages: Array(Set(undescribed.map(\.page))).sorted()))

        if tagged, let tree = model.structureTree() {
            let elements = flatten(tree.elements)
            let roles = tree.roleMap
            func standard(_ e: PDFStructureElement) -> String { roles[e.type] ?? e.type }
            let tables = elements.filter { standard($0) == "Table" }
            if !tables.isEmpty {
                let headed = tables.allSatisfy { flatten([$0]).contains { standard($0) == "TH" } }
                issues.append(headed ? CheckIssue(id: "table-headers", severity: .passed, title: A.tableHeaders)
                                     : CheckIssue(id: "table-headers", severity: .needsAttention, title: A.noTableHeaders))
            }
            let levels = elements.compactMap { e -> Int? in
                let type = standard(e)
                guard type.count == 2, type.first == "H", let level = Int(type.dropFirst()) else { return type == "H" ? 1 : nil }
                return level
            }
            if levels.isEmpty {
                if pageCount > 2 { issues.append(CheckIssue(id: "headings", severity: .needsAttention, title: A.noHeadings)) }
            } else {
                let skips = zip(levels, levels.dropFirst()).contains { $1 > $0 + 1 } || (levels.first ?? 1) > 1
                issues.append(skips ? CheckIssue(id: "headings", severity: .needsAttention, title: A.skippedHeadings)
                                    : CheckIssue(id: "headings", severity: .passed, title: A.headings))
            }
        }

        let lowContrast = lowContrastPages(layout)
        issues.append(lowContrast.isEmpty ? CheckIssue(id: "contrast", severity: .passed, title: A.contrast)
                                          : CheckIssue(id: "contrast", severity: .needsAttention, title: A.lowContrast, pages: lowContrast))

        let fields = model.formFields().filter { !$0.widgets.isEmpty && $0.type != nil }
        if !fields.isEmpty {
            let unlabelled = fields.filter { ($0.object["TU"]?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            issues.append(unlabelled.isEmpty ? CheckIssue(id: "form-labels", severity: .passed, title: A.labelled)
                                             : CheckIssue(id: "form-labels", severity: .failed, title: A.unlabelled(unlabelled.count),
                                                          pages: Array(Set(unlabelled.flatMap { $0.widgets.compactMap(\.page) })).sorted()))
        }

        if pageCount > 20 {
            let hasBookmarks = !model.outlines().isEmpty
            let headings = !(layout.map(headingOutline) ?? []).isEmpty
            issues.append(hasBookmarks ? CheckIssue(id: "bookmarks", severity: .passed, title: A.bookmarks)
                                       : CheckIssue(id: "bookmarks", severity: .needsAttention, title: A.noBookmarks,
                                                    fixTitle: headings ? A.addBookmarks : nil))
        }

        let annotated = model.pages.enumerated().filter { !$0.element.annotations.isEmpty }
        if !annotated.isEmpty {
            let unordered = annotated.filter { $0.element.object["Tabs"]?.name != "S" }.map(\.offset)
            issues.append(unordered.isEmpty ? CheckIssue(id: "tab-order", severity: .passed, title: A.tabOrder)
                                            : CheckIssue(id: "tab-order", severity: .failed, title: A.noTabOrder, pages: unordered,
                                                         fixTitle: A.setTabOrder))
        }
        return AccessibilityReport(issues: issues, figures: figures, language: language)
    }

    /// Applies the accessibility fixes named in `ids` (and the descriptions, which tag an untagged file).
    static func fixAccessibility(_ ids: Set<String>, model: PDFModel, layout: LayoutDocument, fileName: String?,
                                 descriptions: [String: String]) throws {
        let root = model.root
        if ids.contains("title") {
            model.setInfo("Title", suggestedTitle(layout, fileName: fileName))
            root.dictionary("ViewerPreferences").set("DisplayDocTitle", .bool(true))
        }
        if ids.contains("language") { root.set("Lang", .text(detectLanguage(layout).code)) }
        let wanted = descriptions.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isTagged(model) {
            let figures = AutoTagger.figures(in: model)
            for (ref, object) in figures { if let text = wanted[ref.key] { object.set("Alt", .text(text)) } }
        } else if ids.contains("tags") || ids.contains("reading-order") || !wanted.isEmpty {
            try AutoTagger.tag(model, layout: layout, descriptions: wanted)
        }
        if ids.contains("bookmarks") {
            let outline = headingOutline(layout)
            if !outline.isEmpty { model.setOutlines(outline) }
        }
        if ids.contains("tab-order") { for page in model.pages where !page.annotations.isEmpty { page.object.set("Tabs", .name("S")) } }
    }

    static func isTagged(_ model: PDFModel) -> Bool {
        model.root["StructTreeRoot"]?.type == .dictionary && model.root["MarkInfo"]?["Marked"]?.bool == true
    }

    /// /Title from the information dictionary, else dc:title from the XMP metadata.
    static func title(of model: PDFModel) -> String? {
        if let title = model.info("Title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        guard let xmp = (try? model.root["Metadata"]?.streamData()).flatMap({ String(data: $0, encoding: .utf8) }),
              let range = xmp.range(of: "<dc:title>[\\s\\S]*?</dc:title>", options: .regularExpression) else { return nil }
        let inner = xmp[range].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func flatten(_ elements: [PDFStructureElement]) -> [PDFStructureElement] {
        elements.flatMap { element in
            [element] + flatten(element.kids.compactMap { if case .element(let e) = $0 { e } else { nil } })
        }
    }

    /// The text's dominant language, else the Mac's first preferred language.
    static func detectLanguage(_ layout: LayoutDocument?) -> Language {
        var text = ""
        for page in layout?.pages ?? [] where text.count < 4000 { text += page.blocks.map(\.text).joined(separator: " ") + " " }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(text)
        let code = recogniser.dominantLanguage?.rawValue ?? Locale.preferredLanguages.first.flatMap {
            Locale(identifier: $0).language.languageCode?.identifier
        } ?? "en"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        return Language(code: code, name: name)
    }

    /// A title for an untitled document: its first heading, else its first line, else the file's name.
    static func suggestedTitle(_ layout: LayoutDocument, fileName: String?) -> String {
        let blocks = layout.pages.first?.readingOrder.compactMap { element -> LayoutBlock? in
            if case .block(let id) = element { return layout.pages.first?.blocks.first { $0.id == id } }
            return nil
        } ?? []
        let heading = blocks.first { if case .heading = $0.kind { true } else { false } }
        let candidate = (heading ?? blocks.first)?.lines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !candidate.isEmpty, candidate.count <= 120 { return candidate }
        return fileName.map { ($0 as NSString).deletingPathExtension } ?? "Untitled"
    }

    /// Bookmarks from the headings, nested by level.
    static func headingOutline(_ layout: LayoutDocument) -> [PDFOutlineItem] {
        var roots: [PDFOutlineItem] = []
        var stack: [(level: Int, path: [Int])] = []
        for page in layout.pages {
            for element in page.readingOrder {
                guard case .block(let id) = element, let block = page.blocks.first(where: { $0.id == id }),
                      case .heading(let level) = block.kind else { continue }
                let title = block.lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let item = PDFOutlineItem(title: String(title.prefix(200)),
                                          destination: PDFDestination(page: page.index, view: .xyz(left: nil, top: Double(block.bounds.maxY), zoom: nil)))
                while let last = stack.last, last.level >= level { stack.removeLast() }
                if let parent = stack.last {
                    var path = parent.path
                    insert(item, at: &path, in: &roots)
                    stack.append((level, path))
                } else {
                    roots.append(item)
                    stack.append((level, [roots.count - 1]))
                }
            }
        }
        return roots
    }

    /// Appends `item` as the last child of the item at `path`, and extends `path` to it.
    private static func insert(_ item: PDFOutlineItem, at path: inout [Int], in items: inout [PDFOutlineItem]) {
        func append(_ list: inout [PDFOutlineItem], _ rest: ArraySlice<Int>) -> Int {
            guard let first = rest.first else { list.append(item); return list.count - 1 }
            return append(&list[first].children, rest.dropFirst())
        }
        path.append(append(&items, path[...]))
    }

    /// Pages with text under 4.5:1 against white (3:1 from 18 pt), from the colours LayoutKit read.
    private static func lowContrastPages(_ layout: LayoutDocument?) -> [Int] {
        (layout?.pages ?? []).compactMap { page in
            let low = page.blocks.flatMap(\.lines).flatMap(\.words).contains { word in
                guard let color = word.color, let ratio = contrastAgainstWhite(color) else { return false }
                return ratio < (word.fontSize >= 18 ? 3 : 4.5)
            }
            return low ? page.index : nil
        }
    }

    /// WCAG contrast ratio of "#RRGGBB" against white.
    static func contrastAgainstWhite(_ hex: String) -> Double? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count >= 6, let value = Int(digits.prefix(6), radix: 16) else { return nil }
        func channel(_ shift: Int) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        return 1.05 / (luminance + 0.05)
    }

    // MARK: Printing

    static func printing(_ model: PDFModel, data: Data, password: String?) -> [CheckIssue] {
        typealias P = FixStrings.Printing
        var issues: [CheckIssue] = []
        let missing = Fonts.notEmbedded(in: model)
        if missing.isEmpty {
            issues.append(CheckIssue(id: "fonts", severity: .passed, title: P.fontsEmbedded))
        } else {
            issues.append(CheckIssue(id: "fonts", severity: .failed, title: P.fontsMissing(missing.map(\.name)),
                                     pages: Array(Set(missing.flatMap(\.pages))).sorted(),
                                     fixTitle: Fonts.embeddable(missing).isEmpty ? nil : P.embedFonts))
        }

        var lowImages: Set<Int> = [], lowPages: Set<Int> = []
        var overprint = false
        for (index, page) in model.pages.enumerated() {
            for use in ImageUses.on(page) where use.resolution < 150 && use.rect.width * use.rect.height > 400 {
                lowImages.insert(use.objectID ?? -index - 1); lowPages.insert(index)
            }
            ContentWalker.walk(page) { op, _, scope in
                guard !overprint, op.operator == "gs", let name = op.operands.first?.nameValue, let state = scope.resources?["ExtGState"]?[name] else { return }
                if state["OP"]?.bool == true || state["op"]?.bool == true { overprint = true }
            }
        }
        issues.append(lowImages.isEmpty ? CheckIssue(id: "image-resolution", severity: .passed, title: P.resolution)
                                        : CheckIssue(id: "image-resolution", severity: .needsAttention, title: P.lowResolution(lowImages.count),
                                                     pages: lowPages.sorted()))

        var rgb: [Int] = [], transparent: [Int] = [], spots: [String] = []
        if let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) {
            if document.isEncrypted, !document.isUnlocked { _ = document.unlockWithPassword(password ?? "") }
            for index in 0..<document.numberOfPages {
                guard let page = document.page(at: index + 1) else { continue }
                let usage = ColorUsage.scan(page)
                if usage.usesRGB { rgb.append(index) }
                if usage.usesTransparency { transparent.append(index) }
                for spot in usage.spotColors where !spots.contains(spot) { spots.append(spot) }
            }
        }
        issues.append(rgb.isEmpty ? CheckIssue(id: "rgb", severity: .passed, title: P.noRGB)
                                  : CheckIssue(id: "rgb", severity: .needsAttention, title: P.rgb, pages: rgb, fixTitle: P.convert))
        issues.append(transparent.isEmpty ? CheckIssue(id: "transparency", severity: .passed, title: P.noTransparency)
                                          : CheckIssue(id: "transparency", severity: .needsAttention, title: P.transparency, pages: transparent,
                                                       fixTitle: P.flatten))
        if !spots.isEmpty { issues.append(CheckIssue(id: "spot-colours", severity: .needsAttention, title: P.spotColours(spots))) }

        let pages = model.pages
        let noTrim = pages.enumerated().filter { $0.element.object.inherited("TrimBox") == nil }.map(\.offset)
        let sizes = pages.map { $0.box(.crop).size }
        let mixed = sizes.contains { abs($0.width - sizes[0].width) > 1 || abs($0.height - sizes[0].height) > 1 }
        if mixed {
            issues.append(CheckIssue(id: "page-boxes", severity: .needsAttention, title: P.mixedSizes))
        } else {
            issues.append(noTrim.isEmpty ? CheckIssue(id: "page-boxes", severity: .passed, title: P.boxes)
                                         : CheckIssue(id: "page-boxes", severity: .needsAttention, title: P.noTrimBox, pages: noTrim))
        }

        let hairlines = PrintProduction.pagesWithHairlines(in: model)
        issues.append(hairlines.isEmpty ? CheckIssue(id: "hairlines", severity: .passed, title: P.lines)
                                        : CheckIssue(id: "hairlines", severity: .needsAttention, title: P.hairlines, pages: hairlines, fixTitle: P.thicken))
        if overprint { issues.append(CheckIssue(id: "overprint", severity: .needsAttention, title: P.overprint)) }
        if data.count > 100 << 20 { issues.append(CheckIssue(id: "file-size", severity: .needsAttention, title: P.largeFile)) }
        return issues
    }

    // MARK: PDF/A

    static func pdfA(_ model: PDFModel, level: PDFALevel) -> [CheckIssue] {
        typealias A = FixStrings.PDFA
        var failed: [CheckIssue] = []
        func fail(_ id: String, _ title: String, pages: [Int] = []) { failed.append(CheckIssue(id: id, severity: .failed, title: title, pages: pages)) }
        let root = model.root
        let part = Int(level.rawValue.prefix(1)) ?? 2
        let conformance = level.rawValue.suffix(1).uppercased()

        let version = model.version.split(separator: ".").compactMap { Int($0) }
        let tooNew = part == 1 ? (version.first ?? 1, version.dropFirst().first ?? 0) > (1, 4) : (version.first ?? 1) >= 2
        if tooNew { fail("pdfa-version", A.version(level)) }
        if model.isEncrypted { fail("encryption", A.encrypted) }
        let xmp = (try? root["Metadata"]?.streamData()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        func xmpValue(_ key: String) -> String? {
            for pattern in ["pdfaid:\(key)=\"([^\"]*)\"", "pdfaid:\(key)>([^<]*)<"] {
                if let range = xmp.range(of: pattern, options: .regularExpression) {
                    let match = String(xmp[range])
                    return match.replacingOccurrences(of: "pdfaid:\(key)", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "=\"<>"))
                }
            }
            return nil
        }
        if xmpValue("part") != String(part) || xmpValue("conformance")?.uppercased() != conformance { fail("pdfa-metadata", A.notMarked(level)) }
        let intents = root["OutputIntents"]?.items ?? []
        if !intents.contains(where: { $0["S"]?.name == "GTS_PDFA1" && $0["DestOutputProfile"]?.type == .stream }) {
            fail("output-intent", A.noOutputIntent)
        }
        let missing = Fonts.notEmbedded(in: model)
        if !missing.isEmpty { fail("fonts", A.fonts, pages: Array(Set(missing.flatMap(\.pages))).sorted()) }

        let forbiddenActions: Set<String> = ["JavaScript", "Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "Rendition",
                                             "SetOCGState", "Trans", "GoTo3DView"]
        var scripted = root["Names"]?["JavaScript"] != nil || root["AA"] != nil
            || forbiddenActions.contains(root["OpenAction"]?["S"]?.name ?? "")
        var annotationPages: Set<Int> = []
        for (index, page) in model.pages.enumerated() {
            if page.object["AA"] != nil { scripted = true }
            for annotation in page.annotations {
                if annotation["AA"] != nil || forbiddenActions.contains(annotation["A"]?["S"]?.name ?? "") { scripted = true }
                let subtype = annotation["Subtype"]?.name ?? ""
                guard subtype != "Popup" else { continue }
                let prints = (annotation["F"]?.int ?? 0) & 4 != 0
                let rect = annotation["Rect"]?.rect ?? .zero
                let needsAppearance = subtype != "Link" && rect.width > 0 && rect.height > 0
                if !prints || (needsAppearance && annotation["AP"]?["N"] == nil) { annotationPages.insert(index) }
            }
        }
        if scripted { fail("scripts", A.scripts) }
        if !annotationPages.isEmpty { fail("annotations", A.annotations, pages: annotationPages.sorted()) }

        if part == 1 {
            let transparent = model.pages.enumerated().filter { index, page in
                var found = page.object["Group"]?["S"]?.name == "Transparency"
                ContentWalker.walk(page) { op, _, scope in
                    guard !found else { return }
                    if op.operator == "gs", let name = op.operands.first?.nameValue, let state = scope.resources?["ExtGState"]?[name] {
                        let alpha = min(state["CA"]?.number ?? 1, state["ca"]?.number ?? 1)
                        let smask = state["SMask"].map { $0.name != "None" } ?? false
                        let blend = state["BM"]?.name.map { !["Normal", "Compatible"].contains($0) } ?? false
                        if alpha < 1 || smask || blend { found = true }
                    }
                    if op.operator == "Do", let name = op.operands.first?.nameValue, scope.resources?["XObject"]?[name]?["SMask"] != nil {
                        found = true
                    }
                }
                return found
            }.map(\.offset)
            if !transparent.isEmpty { fail("transparency", A.transparency, pages: transparent) }
        }
        if let tree = root["Names"]?["EmbeddedFiles"] {
            let files = PDFNameTree.entries(of: tree)
            let allowed = part == 3 || (part == 2 && files.allSatisfy { String(decoding: $0.key, as: UTF8.self).lowercased().hasSuffix(".pdf") })
            if !files.isEmpty && !allowed { fail("attachments", A.attachments) }
        }
        if usesLZW(model) { fail("lzw", A.lzw) }
        if level.requiresTags && !isTagged(model) { fail("tags", A.untagged) }
        if model.trailer["ID"] == nil { fail("file-id", A.noID) }
        return failed.isEmpty ? [CheckIssue(id: "pdfa", severity: .passed, title: A.passes(level))] : failed
    }

    private static func usesLZW(_ model: PDFModel) -> Bool {
        var found = false
        for page in model.pages {
            if page.contentStreams.contains(where: { $0.filters.contains("LZWDecode") }) { return true }
            ContentWalker.walk(page) { op, _, scope in
                guard !found, op.operator == "Do", let name = op.operands.first?.nameValue, let x = scope.resources?["XObject"]?[name] else { return }
                if x.filters.contains("LZWDecode") { found = true }
            }
            if found { return true }
        }
        return false
    }
}
