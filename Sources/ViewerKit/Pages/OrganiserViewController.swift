import AppKit
import PDFKit
import SuperPDFCore

/// The page organiser (ux §6.2, organizer.png): every page in a grid on the document well's grey, 160 pt thumbnails
/// (80–320 with the toolbar's slider) 24 pt apart. Drag to rearrange with the 3 pt insertion line, drop files to add
/// them (their pages keep the file's colour bar until saved), drag pages to Finder to extract them, ⟲ ⟳ ✕ on hover,
/// ⌫ deletes, ⌘R / ⌘L rotate, the "+ Add pages" tile at the end. Combining shows the files in a column on the left.
/// The status line always says what the two gestures do. Done or Esc goes back; nothing is written until Save.
@MainActor
final class OrganiserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let owner: DocumentWindowController
    let grid: PageGridViewController
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: ViewerStrings.Organiser.hint)
    private let files = NSTableView()
    private let filesScroll = NSScrollView()
    private var filesWidth: NSLayoutConstraint!
    private var fileList: [(origin: PageOrigin, pages: [Int])] = []
    private static let fileDragType = NSPasteboard.PasteboardType("com.udsy.superpdf.organiser-file")
    static let widthKey = Defaults.Key<Double>("viewerKit.organiserThumbnailWidth", default: Double(SPMetrics.Organiser.defaultThumbnailWidth))

    init(owner: DocumentWindowController) {
        self.owner = owner
        grid = PageGridViewController(kind: .organiser, owner: owner)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = WellView()
        addChild(grid)
        grid.organiserWidth = CGFloat(Defaults[Self.widthKey])
        grid.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        owner.toolbarController.sizeSlider.doubleValue = Defaults[Self.widthKey]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        files.addTableColumn(column)
        files.headerView = nil
        files.style = .sourceList
        files.rowHeight = 36
        files.dataSource = self
        files.delegate = self
        files.registerForDraggedTypes([Self.fileDragType])
        filesScroll.documentView = files
        filesScroll.drawsBackground = false
        filesScroll.hasVerticalScroller = true

        let bar = StatusBarView()
        for label in [status, hint] {
            label.font = SPFont.secondary.font()
            label.textColor = SPColor.secondaryLabel.color
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(label)
        }
        hint.alignment = .right
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [filesScroll, grid.view, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        filesWidth = filesScroll.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            filesScroll.topAnchor.constraint(equalTo: root.topAnchor),
            filesScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filesScroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            filesWidth,
            grid.view.topAnchor.constraint(equalTo: root.topAnchor),
            grid.view.leadingAnchor.constraint(equalTo: filesScroll.trailingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.view.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(grid.collectionView)
    }

    func reload(selecting selection: IndexSet?) {
        _ = view
        grid.reload(selecting: selection)
        reloadFiles()
        updateStatus()
    }

    private func updateStatus() {
        status.stringValue = owner.pageActions.model(selection: grid.selection).statusLine
    }

    func rotateSelection(_ turns: Int) {
        let pages = Array(grid.selection)
        guard !pages.isEmpty else { return }
        owner.pageActions.rotate(pages, quarterTurns: turns)
    }

    func setThumbnailWidth(_ width: CGFloat) {
        let range = SPMetrics.Organiser.thumbnailWidthRange
        let clamped = min(max(width, range.lowerBound), range.upperBound)
        grid.organiserWidth = clamped.rounded()
        if owner.environment.persistsWindowState { Defaults[Self.widthKey] = Double(clamped) }
    }

    // MARK: The files column (Combine, ux §6.2)

    private func reloadFiles() {
        let model = owner.pageActions.model(selection: [])
        var order: [PageOrigin] = []
        var pages: [PageOrigin: [Int]] = [:]
        for (index, entry) in model.entries.enumerated() {
            guard let origin = entry.origin else { continue }
            if pages[origin] == nil { order.append(origin) }
            pages[origin, default: []].append(index)
        }
        fileList = order.map { ($0, pages[$0]!) }
        let combining = owner.handle.state.origin == .createdHere && fileList.count > 1
        filesWidth.constant = combining ? 200 : 0
        filesScroll.isHidden = !combining
        files.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { fileList.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = fileList[row]
        let chip = ColorChip(color: PageOrigin.palette[file.origin.colorIndex].color)
        let name = NSTextField(labelWithString: file.origin.fileName)
        name.font = SPFont.body.font()
        name.lineBreakMode = .byTruncatingMiddle
        let count = NSTextField(labelWithString: ViewerStrings.pages(file.pages.count))
        count.font = SPFont.secondary.font()
        count.textColor = SPColor.secondaryLabel.color
        let text = NSStackView(views: [name, count])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [chip, text])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.toolTip = file.origin.fileName
        return stack
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.fileDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    /// Moving a file in the column moves all of its pages before the next file's first page.
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = info.draggingPasteboard.string(forType: Self.fileDragType).flatMap(Int.init), fileList.indices.contains(from) else { return false }
        let gap = row < fileList.count ? fileList[row].pages.first ?? owner.handle.pageCount : owner.handle.pageCount
        owner.pageActions.move(fileList[from].pages, toGap: gap)
        return true
    }
}

/// The organiser's background: the document well's grey.
final class WellView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SPColor.underPageBackground.color.setFill()
        dirtyRect.fill()
    }
}

/// The status line under the grid: window background with a 1 pt separator above (organizer.html).
final class StatusBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SPColor.windowBackground.color.setFill()
        bounds.fill()
        SPColor.separator.color.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A file's colour as a small round chip (the name shows beside it, so colour is never the only signal, ux §9).
final class ColorChip: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        widthAnchor.constraint(equalToConstant: 12).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
