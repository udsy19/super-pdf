import AppKit
import PDFKit
import SuperPDFCore

/// Search results (ux §6.3, features #4): typed in the toolbar's Search field, found asynchronously page by page, one
/// row per page with its picture, the line of the first match and the count; sorted by Page Order or Search Rank.
/// Return and ⌘G go to the next match, ⇧⌘G to the previous.
@MainActor
final class SearchSidebarController: SidebarListController {
    private(set) var query = ""
    private(set) var matches: [PDFSelection] = []
    private var current = -1
    private var byRank = false
    private var finished = false
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        rowHeight = SPMetrics.Sidebar.searchThumbnail.height + 12
        super.loadView()
    }

    override func setUpHeader() {
        let sort = NSPopUpButton(frame: .zero, pullsDown: false)
        sort.addItems(withTitles: [ViewerStrings.Sidebar.pageOrder, ViewerStrings.Sidebar.searchRank])
        sort.controlSize = .small
        sort.target = self
        sort.action = #selector(sortChanged(_:))
        header.addArrangedSubview(sort)
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        byRank = sender.indexOfSelectedItem == 1
        refresh()
    }

    /// Starts a search (an empty query clears it).
    func search(_ text: String) {
        let pdf = document.pdf
        if pdf.isFinding { pdf.cancelFindString() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = []
        current = -1
        finished = query.isEmpty
        refresh()
        guard !query.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidFindMatch, object: pdf, queue: .main) { [weak self] note in
            guard let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            MainActor.assumeIsolated {
                self?.matches.append(selection)
                self?.scheduleRefresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidEndFind, object: pdf, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finished = true
                self?.refresh()
            }
        })
        pdf.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private var refreshScheduled = false
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    override func refresh() {
        var pages: [Int: [PDFSelection]] = [:]
        var order: [Int] = []
        for match in matches {
            guard let page = match.pages.first else { continue }
            let index = document.pdf.index(for: page)
            if pages[index] == nil { order.append(index) }
            pages[index, default: []].append(match)
        }
        if byRank { order.sort { (pages[$0]!.count, -$0) > (pages[$1]!.count, -$1) } } else { order.sort() }
        let rows = order.map { index -> SidebarRow in
            let found = pages[index]!
            let line = (found[0].copy() as? PDFSelection).map { $0.extendForLineBoundaries(); return $0.string ?? "" } ?? ""
            let label = document.pdf.page(at: index)?.label ?? "\(index + 1)"
            return SidebarRow(page: index, title: line.trimmingCharacters(in: .whitespacesAndNewlines),
                              detail: "\(ViewerStrings.Sidebar.page(label)) · \(ViewerStrings.Sidebar.matches(found.count))",
                              onClick: { [weak self] in self?.select(found[0]) })
        }
        show(rows, empty: finished && !query.isEmpty ? Strings.Empty.searchNoResults(query) : "")
    }

    /// Next (or previous) match after the current one, wrapping.
    func step(_ direction: Int) {
        guard !matches.isEmpty else { return }
        current = (current + direction + matches.count) % matches.count
        select(matches[current])
    }

    private func select(_ selection: PDFSelection) {
        if let index = matches.firstIndex(of: selection) { current = index }
        owner.pdfView.setCurrentSelection(selection, animate: true)
        owner.pdfView.go(to: selection)
    }
}
