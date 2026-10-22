import AppKit
import QuickLookUI
import SuperPDFCore

/// What the grid asks of the workspace: the cards' pictures and actions (`WorkspaceCardHost`), and what selection, the
/// "+" between cards, the add card and drags mean.
@MainActor
protocol WorkspaceGridDelegate: WorkspaceCardHost {
    func gridSelectionChanged()
    func gridPreview(_ id: WorkspaceItemID)
    /// The Quick Look panel for the cards, taken over while the grid is in the responder chain.
    var quickLook: QuickLookController { get }
    /// The "+" between two cards: the add menu for that gap (cards before it, counting only cards with pages).
    func gridInsert(atCardGap gap: Int, from view: NSView)
    func gridAddFiles()
    func gridDeleteSelection()
    /// Esc: closes the preview, else goes back to the document.
    func gridEscape()
    /// What a drag over a gap would do: the operation, and the words the hole shows ("Add 3 pages here").
    func gridValidateDrop(_ info: NSDraggingInfo, atCardGap gap: Int, excluding: Set<WorkspaceItemID>) -> (NSDragOperation, String?)
    func gridAcceptDrop(_ info: NSDraggingInfo, atCardGap gap: Int, excluding: Set<WorkspaceItemID>) -> Bool
    /// What a drag of these cards carries (pages for another window, a PDF for Finder).
    func gridPasteboardWriters(for ids: [WorkspaceItemID]) -> [NSPasteboardWriting]
}

/// The workspace's cards (ux §6.2): a centred grid (or a list) on the canvas, laid out by hand so that cards can spring
/// out of the way while something is dragged over them, slide to their new places after a change, and pop in when they
/// arrive. Only the cards on screen exist (500 pages scroll as lightly as 5). In the Files view a round "+" sits
/// between neighbouring cards; in the Pages view it appears in the gap under the pointer. Click selects (⌘ and ⇧ add),
/// the checkbox toggles, double-click or Space previews (Quick Look), ⌫ deletes, arrows move, pinch or ⌘+ / ⌘− resize.
@MainActor
final class WorkspaceGridView: NSView, NSDraggingSource {
    weak var delegate: WorkspaceGridDelegate?
    private(set) var items: [WorkspaceItem] = []
    private(set) var mode: WorkspaceMode = .files
    private(set) var layoutKind: WorkspaceLayout = .grid
    /// Card size: pinch, ⌘+ and ⌘− (`SPMetrics.Workspace.scaleRange`).
    var scale: CGFloat = 1 { didSet { if scale != oldValue { relayout(animated: false); reloadVisibleThumbnails() } } }
    var selection: Set<WorkspaceItemID> = [] { didSet { if selection != oldValue { updateSelectionMarks() } } }
    /// Moves animate (off in the self-test, and with Reduce Motion).
    var animates = true

    private var cards: [WorkspaceItemID: WorkspaceCardView] = [:]
    private var pool: [WorkspaceCardView] = []
    private var frames: [WorkspaceItemID: NSRect] = [:]
    private var anchor: WorkspaceItemID?
    private var hovered: WorkspaceItemID?
    /// Cards being dragged from here: out of the layout until the drag ends.
    private var excluded: Set<WorkspaceItemID> = []
    /// The gap (counting cards with pages, without the dragged ones) a drag would drop into; the cards make room there.
    private var hole: Int?
    private let holeView = WorkspaceHoleView()
    /// A drop of cards from here was taken: they stay out, and the hole open, until the document's change comes back.
    private var awaitingMove = false
    private var inserters: [WorkspaceInserter] = []
    private let floatingInserter = WorkspaceInserter()
    private var mouseDown: (id: WorkspaceItemID?, point: NSPoint, dragged: Bool)?

    private var moves: Bool { animates && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        holeView.isHidden = true
        addSubview(holeView)
        floatingInserter.isHidden = true
        floatingInserter.onPress = { [weak self] view in self?.delegate?.gridInsert(atCardGap: view.gap, from: view) }
        addSubview(floatingInserter)
        registerForDraggedTypes([.superPDFPages, .fileURL])
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Content

    /// New cards: the ones that stay slide to their new places, new ones pop in, gone ones fade.
    func show(_ items: [WorkspaceItem], mode: WorkspaceMode, layout: WorkspaceLayout, animated: Bool) {
        if awaitingMove {
            awaitingMove = false
            excluded = []
            hole = nil
        }
        let modeChanged = mode != self.mode || layout != layoutKind
        self.items = items
        self.mode = mode
        layoutKind = layout
        let ids = Set(items.map(\.id))
        selection = selection.filter { ids.contains($0) }
        if modeChanged {
            for card in cards.values { recycle(card) }
            cards = [:]
        }
        setAccessibilityLabel(mode == .files ? ViewerStrings.Workspace.files : ViewerStrings.Workspace.pages)
        relayout(animated: animated && !modeChanged)
    }

    var contentIDs: [WorkspaceItemID] { items.filter(\.isContent).map(\.id) }

    func card(for id: WorkspaceItemID) -> WorkspaceCardView? { cards[id] }

    func frame(of id: WorkspaceItemID) -> NSRect? { frames[id] }

    // MARK: Layout

    private var cardSize: NSSize {
        layoutKind == .list ? NSSize(width: listWidth, height: SPMetrics.Workspace.listRowHeight) : WorkspaceCardView.cardSize(mode, scale: scale)
    }

    private var gapSize: NSSize {
        layoutKind == .list ? NSSize(width: 0, height: 8) : mode == .files ? SPMetrics.Workspace.fileGap : SPMetrics.Workspace.pageGap
    }

    private var listWidth: CGFloat { min(bounds.width - 2 * SPMetrics.Workspace.margin, SPMetrics.Workspace.listMaxWidth) }

    var columns: Int {
        guard layoutKind == .grid else { return 1 }
        let available = bounds.width - 2 * SPMetrics.Workspace.margin
        return max(1, Int((available + gapSize.width) / (cardSize.width + gapSize.width)))
    }

    /// Frames of cards in slots: column by column, row by row, centred.
    private func slotFrame(_ slot: Int) -> NSRect {
        let size = cardSize, gap = gapSize, columns = self.columns
        let used = CGFloat(columns) * size.width + CGFloat(columns - 1) * gap.width
        let left = ((bounds.width - used) / 2).rounded(.down)
        let column = slot % columns, row = slot / columns
        return NSRect(x: left + CGFloat(column) * (size.width + gap.width), y: SPMetrics.Workspace.margin + CGFloat(row) * (size.height + gap.height),
                      width: size.width, height: size.height)
    }

    /// The cards in their slots, the dragged ones left out and the hole kept free.
    private func layoutSlots() -> (cards: [(WorkspaceItem, Int)], hole: Int?) {
        var shown = items.filter { !excluded.contains($0.id) }
        var holeSlot: Int?
        if let hole {
            // The hole counts cards with pages; converting cards stay where they are around it.
            var seen = 0, slot = shown.count - 1
            for (index, item) in shown.enumerated() where item.isContent {
                if seen == hole { slot = index; break }
                seen += 1
            }
            if seen < hole || shown.allSatisfy({ !$0.isContent }) { slot = max(shown.count - 1, 0) }
            holeSlot = min(slot, max(shown.count - 1, 0))
            shown.insert(.add, at: holeSlot!)  // a placeholder; skipped below
        }
        var result: [(WorkspaceItem, Int)] = []
        for (slot, item) in shown.enumerated() where slot != holeSlot { result.append((item, slot)) }
        return (result, holeSlot)
    }

    func relayout(animated: Bool) {
        let (slots, holeSlot) = layoutSlots()
        var newFrames: [WorkspaceItemID: NSRect] = [:]
        for (item, slot) in slots { newFrames[item.id] = slotFrame(slot) }
        let old = frames
        frames = newFrames
        let lastSlot = max((slots.map(\.1).max() ?? 0), holeSlot ?? 0)
        let bottom = slotFrame(lastSlot).maxY + SPMetrics.Workspace.margin + 8
        let height = max(bottom, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        if let holeSlot {
            let target = slotFrame(holeSlot)
            if holeView.isHidden {
                holeView.frame = target
                holeView.isHidden = false
                if animated && moves { holeView.popIn() }
            } else {
                move(holeView, to: target, animated: animated)
            }
        } else {
            holeView.isHidden = true
        }
        updateVisibleCards(previous: old, animated: animated)
        layoutInserters()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if oldSize.width != bounds.width { relayout(animated: false) }
    }

    /// Makes the cards on screen (and a row more each way), reusing the ones that scrolled off.
    func updateVisibleCards(previous: [WorkspaceItemID: NSRect]? = nil, animated: Bool = false) {
        let visible = (enclosingScrollView?.documentVisibleRect ?? bounds).insetBy(dx: 0, dy: -cardSize.height)
        let wanted = Set(frames.filter { $0.value.intersects(visible) }.map(\.key))
        for (id, card) in cards where !wanted.contains(id) {
            cards[id] = nil
            if animated, moves, previous?[id] != nil, frames[id] == nil, !excluded.contains(id) { fadeOut(card) } else { recycle(card) }
        }
        let scale = window?.backingScaleFactor ?? 2
        for item in items where wanted.contains(item.id) {
            guard let target = frames[item.id] else { continue }
            let outer = target.insetBy(dx: -WorkspaceCardView.outset, dy: -WorkspaceCardView.outset)
            if let card = cards[item.id] {
                card.configure(item, mode: mode, layout: layoutKind, pixelScale: scale)
                move(card, to: outer, animated: animated)
            } else {
                let card = dequeue()
                card.frame = outer
                card.configure(item, mode: mode, layout: layoutKind, pixelScale: scale)
                card.isSelected = selection.contains(item.id)
                card.isHovered = hovered == item.id
                addSubview(card, positioned: .below, relativeTo: holeView)
                cards[item.id] = card
                // A card that is new to the workspace (not one scrolled into view) pops in.
                if animated, moves, previous != nil, previous?[item.id] == nil { card.layer.map(Self.popIn) }
            }
        }
    }

    private func dequeue() -> WorkspaceCardView {
        let card = pool.popLast() ?? WorkspaceCardView()
        card.host = delegate
        card.isHidden = false
        card.alphaValue = 1
        return card
    }

    private func recycle(_ card: WorkspaceCardView) {
        card.prepareForReuse()
        card.removeFromSuperview()
        if pool.count < 24 { pool.append(card) }
    }

    /// Slides a view to a frame on the workspace spring (its layer's position, whichever way the layer is flipped).
    private func move(_ view: NSView, to target: NSRect, animated: Bool) {
        guard view.frame != target else { return }
        let sameSize = view.frame.size == target.size
        guard animated, moves, sameSize, let layer = view.layer else { view.frame = target; return }
        let from = layer.presentation()?.position ?? layer.position
        view.frame = target
        let spring = SPMotion.thumbnailShift.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position))
        layer.add(spring, forKey: "reflow")
    }

    private static func popIn(_ layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        layer.add(fade, forKey: "fadeIn")
        let size = layer.bounds.size
        var small = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        small = CATransform3DScale(small, 0.86, 0.86, 1)
        small = CATransform3DTranslate(small, -size.width / 2, -size.height / 2, 0)
        layer.add(SPMotion.thumbnailShift.animation("transform", from: NSValue(caTransform3D: small), to: NSValue(caTransform3D: CATransform3DIdentity)),
                  forKey: "popIn")
    }

    private func fadeOut(_ card: WorkspaceCardView) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak card] in
            MainActor.assumeIsolated {
                guard let self, let card, !self.cards.values.contains(card) else { return }
                self.recycle(card)
            }
        })
    }

    private func updateSelectionMarks() {
        for (id, card) in cards { card.isSelected = selection.contains(id) }
    }

    func reloadVisibleThumbnails() {
        let scale = window?.backingScaleFactor ?? 2
        for (id, card) in cards { if let item = items.first(where: { $0.id == id }) { card.configure(item, mode: mode, layout: layoutKind, pixelScale: scale) } }
    }

    // MARK: The "+" between cards

    /// Gaps between neighbouring file or page cards in a row (a converting file counts as a neighbour), with where their
    /// "+" goes and the gap counted in cards with pages.
    private func inserterSpots() -> [(gap: Int, center: NSPoint)] {
        guard layoutKind == .grid, hole == nil, excluded.isEmpty else { return [] }
        var spots: [(Int, NSPoint)] = []
        var contentBefore = 0
        let ordered = items.compactMap { item in frames[item.id].map { (item, $0) } }
        func isCard(_ item: WorkspaceItem) -> Bool { if case .add = item { false } else { true } }
        for (index, (item, frame)) in ordered.enumerated() {
            if item.isContent { contentBefore += 1 }
            guard isCard(item), index + 1 < ordered.count else { continue }
            let (next, nextFrame) = ordered[index + 1]
            guard isCard(next), abs(nextFrame.minY - frame.minY) < 1 else { continue }
            let middle = WorkspaceCardView.pictureMiddle(mode, cardHeight: frame.height)
            spots.append((contentBefore, NSPoint(x: (frame.maxX + nextFrame.minX) / 2, y: frame.minY + middle)))
        }
        return spots
    }

    private func layoutInserters() {
        let spots = mode == .files ? inserterSpots() : []
        while inserters.count < spots.count {
            let inserter = WorkspaceInserter()
            inserter.onPress = { [weak self] view in self?.delegate?.gridInsert(atCardGap: view.gap, from: view) }
            addSubview(inserter)
            inserters.append(inserter)
        }
        let d = SPMetrics.Workspace.inserter
        for (index, inserter) in inserters.enumerated() {
            inserter.isHidden = index >= spots.count
            guard index < spots.count else { continue }
            inserter.gap = spots[index].gap
            inserter.frame = NSRect(x: spots[index].center.x - d / 2 - 4, y: spots[index].center.y - d / 2 - 4, width: d + 8, height: d + 8)
        }
        if mode == .files || layoutKind == .list { floatingInserter.isHidden = true }
    }

    /// Pages view: the "+" appears in the gap the pointer is in.
    private func updateFloatingInserter(at point: NSPoint) {
        guard mode == .pages, layoutKind == .grid else { return }
        let d = SPMetrics.Workspace.inserter
        let spot = inserterSpots().first { abs($0.center.x - point.x) < gapSize.width / 2 + 4 && abs($0.center.y - point.y) < cardSize.height / 2 }
        floatingInserter.isHidden = spot == nil
        if let spot {
            floatingInserter.gap = spot.gap
            floatingInserter.frame = NSRect(x: spot.center.x - d / 2 - 4, y: spot.center.y - d / 2 - 4, width: d + 8, height: d + 8)
        }
    }

    // MARK: Hit testing

    /// The card under a point (inside the card itself, not its shadow).
    func itemID(at point: NSPoint) -> WorkspaceItemID? {
        frames.first { $0.value.contains(point) }?.key
    }

    // MARK: Mouse

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(itemID(at: point))
        updateFloatingInserter(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        floatingInserter.isHidden = true
    }

    private func setHovered(_ id: WorkspaceItemID?) {
        guard id != hovered else { return }
        if let hovered { cards[hovered]?.isHovered = false }
        hovered = id
        if let id { cards[id]?.isHovered = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let id = itemID(at: point)
        mouseDown = (id, point, false)
        guard let id, let item = items.first(where: { $0.id == id }) else {
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) { select([]) }
            return
        }
        guard item.isContent else { return }
        if let card = cards[id], card.isOnCheckbox(convert(point, to: card)) {
            toggle(id)
            mouseDown = nil
            return
        }
        if event.clickCount == 2 { delegate?.gridPreview(id); mouseDown = nil; return }
        if event.modifierFlags.contains(.command) {
            toggle(id)
        } else if event.modifierFlags.contains(.shift), let anchor, let from = contentIDs.firstIndex(of: anchor), let to = contentIDs.firstIndex(of: id) {
            select(selection.union(contentIDs[min(from, to)...max(from, to)]))
        } else if !selection.contains(id) {
            select([id])
            anchor = id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var down = mouseDown, !down.dragged, let id = down.id, items.first(where: { $0.id == id })?.isContent == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.point.x, point.y - down.point.y) > 4 else { return }
        down.dragged = true
        mouseDown = down
        beginDrag(from: id, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDown = nil }
        guard let down = mouseDown, !down.dragged else { return }
        guard let id = down.id else { return }
        if id == .add { delegate?.gridAddFiles(); return }
        // A click on one of several selected cards (no drag) keeps just that one.
        if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), selection.count > 1, selection.contains(id) {
            select([id])
            anchor = id
        }
    }

    override func magnify(with event: NSEvent) {
        let range = SPMetrics.Workspace.scaleRange
        scale = min(max(scale * (1 + event.magnification), range.lowerBound), range.upperBound)
    }

    // MARK: Selection

    func select(_ ids: Set<WorkspaceItemID>) {
        selection = ids
        delegate?.gridSelectionChanged()
    }

    private func toggle(_ id: WorkspaceItemID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        anchor = id
        delegate?.gridSelectionChanged()
    }

    override func selectAll(_ sender: Any?) { select(Set(contentIDs)) }

    func toggleSelection(of id: WorkspaceItemID) { toggle(id) }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return super.keyDown(with: event) }
        switch Int(key) {
        case NSDeleteCharacter, NSDeleteFunctionKey: delegate?.gridDeleteSelection()
        case 0x1B: delegate?.gridEscape()
        case 0x20, NSCarriageReturnCharacter, NSEnterCharacter:
            if let id = anchor.flatMap({ selection.contains($0) ? $0 : nil }) ?? contentIDs.first(where: selection.contains) ?? contentIDs.first {
                delegate?.gridPreview(id)
            }
        case NSLeftArrowFunctionKey: step(-1, extend: event.modifierFlags.contains(.shift))
        case NSRightArrowFunctionKey: step(1, extend: event.modifierFlags.contains(.shift))
        case NSUpArrowFunctionKey: step(-columns, extend: event.modifierFlags.contains(.shift))
        case NSDownArrowFunctionKey: step(columns, extend: event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { delegate?.gridEscape() }

    // Quick Look: the panel finds the grid through the responder chain.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { delegate != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { delegate?.quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { delegate?.quickLook.end(panel) }

    private func step(_ delta: Int, extend: Bool) {
        let ids = contentIDs
        guard !ids.isEmpty else { return }
        let current = anchor.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let next = min(max(current + delta, 0), ids.count - 1)
        anchor = ids[next]
        select(extend ? selection.union([ids[next]]) : [ids[next]])
        if let frame = frames[ids[next]] { scrollToVisible(frame.insetBy(dx: 0, dy: -16)) }
    }

    // MARK: Dragging out

    private func beginDrag(from id: WorkspaceItemID, event: NSEvent) {
        let ids = selection.contains(id) ? contentIDs.filter(selection.contains) : [id]
        guard let delegate else { return }
        let writers = delegate.gridPasteboardWriters(for: ids)
        guard !writers.isEmpty else { return }
        var draggingItems: [NSDraggingItem] = []
        // The card under the pointer leads; the others follow as a stack.
        let order = [id] + ids.filter { $0 != id }
        for (index, writer) in writers.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: writer)
            let cardID = order[min(index, order.count - 1)]
            if let card = cards[cardID] {
                item.setDraggingFrame(card.frame, contents: snapshot(card))
            } else if let first = cards[id] {
                item.setDraggingFrame(first.frame, contents: snapshot(first))
            }
            draggingItems.append(item)
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
        excluded = Set(ids)
        setHovered(nil)
        relayout(animated: true)
    }

    /// The card as it looks now, tilted a little the way it is picked up.
    private func snapshot(_ card: WorkspaceCardView) -> NSImage {
        let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) ?? NSBitmapImageRep()
        card.cacheDisplay(in: card.bounds, to: rep)
        let image = NSImage(size: card.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.move, .copy, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            guard awaitingMove else {
                excluded = []
                hole = nil
                relayout(animated: true)
                return
            }
            // The move is on its way: the cards land in the hole when the pages come back; if they never do, back home.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.awaitingMove else { return }
                    self.awaitingMove = false
                    self.excluded = []
                    self.hole = nil
                    self.relayout(animated: true)
                }
            }
        }
    }

    // MARK: Dropping in

    /// The gap a point means, among the cards with pages (the dragged ones left out), as if no hole were open.
    func cardGap(at point: NSPoint) -> Int {
        let content = items.filter { $0.isContent && !excluded.contains($0.id) }
        // Frames without the hole: where each card would be with nothing dragged over.
        var slot = 0, frames: [NSRect] = []
        for item in items where !excluded.contains(item.id) {
            if item.isContent { frames.append(slotFrame(slot)) }
            slot += 1
        }
        guard !frames.isEmpty, frames.count == content.count else { return 0 }
        if layoutKind == .list { return frames.firstIndex { point.y < $0.midY } ?? frames.count }
        let rowTop = frames.map(\.minY).filter { $0 <= point.y + gapSize.height }.max() ?? frames[0].minY
        let row = frames.indices.filter { abs(frames[$0].minY - rowTop) < 1 }
        return row.first { point.x < frames[$0].midX } ?? ((row.last ?? frames.count - 1) + 1)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOver(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOver(sender) }

    private func dragOver(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = convert(info.draggingLocation, from: nil)
        autoscroll(at: point)
        let gap = cardGap(at: point)
        let (operation, label) = delegate?.gridValidateDrop(info, atCardGap: gap, excluding: excluded) ?? ([], nil)
        holeView.label = label
        let newHole: Int? = operation.isEmpty ? nil : gap
        if newHole != hole {
            hole = newHole
            relayout(animated: true)
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard hole != nil else { return }
        hole = nil
        relayout(animated: true)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let gap = hole ?? cardGap(at: convert(sender.draggingLocation, from: nil))
        let accepted = delegate?.gridAcceptDrop(sender, atCardGap: gap, excluding: excluded) ?? false
        if accepted && !excluded.isEmpty && sender.draggingSource as? WorkspaceGridView === self {
            awaitingMove = true
        } else {
            hole = nil
            relayout(animated: true)
        }
        return accepted
    }

    private func autoscroll(at point: NSPoint) {
        guard let visible = enclosingScrollView?.documentVisibleRect else { return }
        let edge: CGFloat = 40
        if point.y < visible.minY + edge || point.y > visible.maxY - edge {
            scrollToVisible(NSRect(x: point.x, y: point.y - edge, width: 1, height: 2 * edge))
        }
    }
}

/// Where the dragged cards will land: a dashed card-sized hole in the accent, with the drop's words when it has some.
@MainActor
final class WorkspaceHoleView: NSView {
    var label: String? { didSet { if label != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = SPColor.accent.color
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        accent.withAlphaComponent(0.07).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        accent.withAlphaComponent(0.55).setStroke()
        path.stroke()
        guard let label else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: label, attributes: [.font: SPFont.bannerEmphasis.font(), .foregroundColor: accent, .paragraphStyle: paragraph])
        let size = text.boundingRect(with: NSSize(width: bounds.width - 20, height: 60), options: [.usesLineFragmentOrigin])
        text.draw(with: NSRect(x: 10, y: (bounds.height - size.height) / 2, width: bounds.width - 20, height: ceil(size.height)), options: [.usesLineFragmentOrigin])
    }

    func popIn() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        layer.add(fade, forKey: "fade")
    }
}

/// The round accent "+" between two cards: adds files (or a blank page…) in that gap.
@MainActor
final class WorkspaceInserter: NSControl {
    var gap = 0
    var onPress: ((WorkspaceInserter) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(ViewerStrings.Workspace.addHere)
        toolTip = ViewerStrings.Workspace.addHere
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 4, dy: 4)
        let accent = SPColor.accent.color
        NSGraphicsContext.saveGraphicsState()
        // A ring of canvas round the button, so it reads clearly over a card's shadow.
        SPColor.canvas.color.setFill()
        NSBezierPath(ovalIn: circle.insetBy(dx: -3, dy: -3)).fill()
        let shadow = NSShadow()
        shadow.shadowColor = accent.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        (isHovered ? accent.blended(withFraction: 0.12, of: .black) ?? accent : accent).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let plus = SPIcon.glyphImage("plus", size: 11, weight: .heavy) {
            plus.draw(in: NSRect(x: circle.midX - plus.size.width / 2, y: circle.midY - plus.size.height / 2, width: plus.size.width, height: plus.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(self)
    }
    override func accessibilityPerformPress() -> Bool { onPress?(self); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
