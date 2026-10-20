import CoreGraphics
import Foundation
import SuperPDFCore

/// The analysis pipeline (features §2.4) over plain values: runs off the main actor, needs no PDFKit, and takes the same
/// `PageInput` whether the words came from PDFKit or from Vision.
public enum LayoutAnalyzer {
    /// Analyses pages together, so heading levels and running headers are consistent across them.
    public static func analyze(_ inputs: [PageInput], options: LayoutOptions = LayoutOptions()) -> [LayoutPage] {
        let bodySize = Typography.bodyFontSize(inputs.flatMap(\.words))
        var pages = inputs.map { analyzePage($0, bodySize: bodySize, options: options) }
        confirmRunningBlocks(&pages)
        assignHeadingLevels(&pages)
        return pages.map { finish($0, options: options) }
    }

    public static func analyze(_ input: PageInput, options: LayoutOptions = LayoutOptions()) -> LayoutPage {
        analyze([input], options: options)[0]
    }

    // MARK: Per page

    struct PageDraft {
        var input: PageInput
        var bodySize: CGFloat
        var blocks: [BlockDraft]
        var tables: [LayoutTable]
        var figures: [LayoutFigure]
    }

    static func analyzePage(_ input: PageInput, bodySize documentBodySize: CGFloat, options: LayoutOptions) -> PageDraft {
        let bodySize = input.words.isEmpty ? documentBodySize : (input.words.count < 20 ? documentBodySize : Typography.bodyFontSize(input.words))
        var tables: [LayoutTable] = []
        var words = input.words
        if options.detectTables {
            let rows = LineBuilder.baselineRows(words)
            tables = TableDetector.detect(lines: rows, rulings: input.graphics.rulings, bodySize: bodySize, pageSize: input.size)
            if !tables.isEmpty {
                let claimed = Set(tables.flatMap { TableDetector.wordsInside($0.bounds, lines: rows) })
                words = words.filter { !claimed.contains($0) }
            }
        }
        let lines = LineBuilder.lines(from: words)
        let figures = FigureDetector.figures(from: input.graphics, tables: tables.map(\.bounds), pageSize: input.size)
        let obstacles = tables.map(\.bounds) + figures.map(\.bounds)
        let drafts = ParagraphBuilder.blocks(from: lines, obstacles: obstacles)
        let blocks = BlockClassifier.classify(drafts, bodySize: bodySize, pageSize: input.size, origin: input.origin, figures: figures.map(\.bounds), tables: tables.map(\.bounds))
        return PageDraft(input: input, bodySize: bodySize, blocks: blocks, tables: tables, figures: figures)
    }

    // MARK: Across pages

    /// Headers and footers that repeat on other pages (digits ignored) are confirmed even without clearance; short
    /// blocks in the bands that repeat become headers or footers.
    static func confirmRunningBlocks(_ pages: inout [PageDraft]) {
        guard pages.count >= 2 else { return }
        func key(_ block: BlockDraft) -> String {
            block.text.replacingOccurrences(of: "\\d+", with: "#", options: .regularExpression).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seen: [String: Set<Int>] = [:]
        for (pageIndex, page) in pages.enumerated() {
            for block in page.blocks where block.lines.count <= 3 && block.characterCount <= 160 {
                let height = page.input.size.height
                guard block.bounds.minY >= height * 0.85 || block.bounds.maxY <= height * 0.15 else { continue }
                seen[key(block), default: []].insert(pageIndex)
            }
        }
        for pageIndex in pages.indices {
            let height = pages[pageIndex].input.size.height
            for blockIndex in pages[pageIndex].blocks.indices {
                let block = pages[pageIndex].blocks[blockIndex]
                guard block.lines.count <= 3, block.characterCount <= 160, (seen[key(block)]?.count ?? 0) >= 2 else { continue }
                if case .pageNumber = block.kind { continue }
                if block.bounds.minY >= height * 0.85 { pages[pageIndex].blocks[blockIndex].kind = .header; pages[pageIndex].blocks[blockIndex].headingSize = nil }
                else if block.bounds.maxY <= height * 0.15 { pages[pageIndex].blocks[blockIndex].kind = .footer; pages[pageIndex].blocks[blockIndex].headingSize = nil }
            }
        }
    }

    /// Level 1 is the largest heading size in the document; bold body-size headings take the lowest level.
    static func assignHeadingLevels(_ pages: inout [PageDraft]) {
        var sizes: [CGFloat] = []
        for page in pages { for block in page.blocks { if let size = block.headingSize { sizes.append((size * 2).rounded() / 2) } } }
        let distinct = Array(Set(sizes)).sorted(by: >)
        for pageIndex in pages.indices {
            for blockIndex in pages[pageIndex].blocks.indices {
                guard let size = pages[pageIndex].blocks[blockIndex].headingSize else { continue }
                let level = (distinct.firstIndex(of: (size * 2).rounded() / 2) ?? distinct.count) + 1
                pages[pageIndex].blocks[blockIndex].kind = .heading(level: min(level, 6))
            }
        }
    }

    // MARK: Output

    static func finish(_ draft: PageDraft, options: LayoutOptions) -> LayoutPage {
        func isRunning(_ kind: LayoutBlockKind) -> Bool {
            switch kind { case .header, .footer, .pageNumber: true; default: false }
        }
        var items: [OrderedItem] = []
        var excluded: [Int] = []
        for (index, block) in draft.blocks.enumerated() {
            if options.excludeHeadersAndFooters && isRunning(block.kind) { excluded.append(index) } else { items.append(OrderedItem(element: .block(index), bounds: block.bounds)) }
        }
        for table in draft.tables { items.append(OrderedItem(element: .table(table.id), bounds: table.bounds)) }
        for figure in draft.figures { items.append(OrderedItem(element: .figure(figure.id), bounds: figure.bounds)) }
        let ordered = ReadingOrder.order(items, bodySize: draft.bodySize)

        // Blocks are numbered in reading order; excluded running blocks follow, top-down.
        var blocks: [LayoutBlock] = []
        var newID: [Int: Int] = [:]
        var readingOrder: [LayoutElement] = []
        for item in ordered {
            switch item.element {
            case .block(let old):
                let draftBlock = draft.blocks[old]
                newID[old] = blocks.count
                blocks.append(LayoutBlock(id: blocks.count, kind: draftBlock.kind, bounds: draftBlock.bounds.rounded, lines: draftBlock.lines.map(\.layoutLine), column: item.column))
                readingOrder.append(.block(blocks.count - 1))
            case .table, .figure:
                readingOrder.append(item.element)
            }
        }
        for old in excluded.sorted(by: { draft.blocks[$0].bounds.maxY > draft.blocks[$1].bounds.maxY }) {
            let draftBlock = draft.blocks[old]
            newID[old] = blocks.count
            blocks.append(LayoutBlock(id: blocks.count, kind: draftBlock.kind, bounds: draftBlock.bounds.rounded, lines: draftBlock.lines.map(\.layoutLine)))
        }
        var figures = draft.figures
        for index in figures.indices {
            let captions = draft.blocks.indices.filter { index2 in
                if case .caption = draft.blocks[index2].kind { return Captions.isNextTo(draft.blocks[index2], figure: figures[index].bounds, bodySize: draft.bodySize) }
                return false
            }
            if let nearest = captions.min(by: { draft.blocks[$0].bounds.gap(to: figures[index].bounds) < draft.blocks[$1].bounds.gap(to: figures[index].bounds) }) {
                figures[index].captionBlockID = newID[nearest]
            }
        }
        return LayoutPage(index: draft.input.index, size: draft.input.size, rotation: draft.input.rotation, origin: draft.input.origin,
                          blocks: blocks, tables: draft.tables, figures: figures, readingOrder: readingOrder)
    }
}
