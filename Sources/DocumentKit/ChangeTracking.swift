import Foundation
import ObjectiveC
import PDFKit
import SuperPDFCore

// Saves write only what changed (`DocumentBaseline`), and finding that out must not cost a stall on a long file: reading
// every annotation of a 2000-page document and comparing all of them takes hundreds of milliseconds. So the PDFKit
// documents DocumentKit opens report changes before they happen. `TrackedDocument` tells of pages inserted, removed and
// exchanged; through its delegate PDFKit makes every page it reads a `TrackedPage` and every annotation a
// `TrackedAnnotation` (PDFKit's documented `classForPage` and `classForAnnotationType:`), whose setters tell first. The
// baseline then records a page as it was the first time something could change it, and a save compares only those
// pages. Changing an annotation goes through its setters (or `setValue(_:forAnnotationKey:)`); the getters of the
// objects PDFKit writes back into an annotation in place (border, action, destination, paths) count as a possible
// change, as does a click on the page (`annotation(at:)`, PDFView's own form filling).
//
// PDFKit itself calls the same setters while it builds pages and annotations, holding locks a report must not wait on.
// So only pages handed out by `page(at:)` report, and annotations only once their page has handed them out
// (`annotations`, `annotation(at:)`): nobody can change what they were never given. A page's report records it on the
// spot; an annotation's records only that annotation's print and leaves its page for the save to record.

/// Receives the reports of one tracked document (its PDFKit delegate, kept alive by the document).
final class ChangeTracker: NSObject, PDFDocumentDelegate {
    /// The baseline the reports go to; nil until bytes are attached (changes before then are what the file shows).
    @MainActor weak var baseline: DocumentBaseline?
    /// Pages were inserted, removed or exchanged before a baseline was attached: their order is no longer the file's.
    @MainActor var reorderedBeforeAttach = false
    /// Reports are ignored while the baseline reads pages and a save copies them.
    @MainActor private(set) var muted = 0
    /// Pages `page(at:)` handed out, and pages whose annotations were handed out.
    @MainActor private let pages = NSHashTable<PDFKit.PDFPage>.weakObjects()
    @MainActor private let annotationPages = NSHashTable<PDFKit.PDFPage>.weakObjects()

    func classForPage() -> AnyClass { TrackedPage.self }

    func `class`(forAnnotationType annotationType: String) -> AnyClass { TrackedAnnotation.self }

    /// `page` was handed out (`annotations` true: its annotations were).
    nonisolated func handedOut(_ page: PDFKit.PDFPage, annotations: Bool) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { (annotations ? annotationPages : pages).add(page) }
    }

    /// Something may change `page` (its rotation, boxes or annotation list, or an annotation PDFView hit).
    nonisolated func pageWillChange(_ page: PDFKit.PDFPage) {
        report { tracker, baseline in
            guard tracker.pages.contains(page) || tracker.annotationPages.contains(page) else { return }
            baseline.willChange(page)
        }
    }

    /// Something may change `annotation`.
    nonisolated func annotationWillChange(_ annotation: PDFAnnotation) {
        report { tracker, baseline in
            guard let page = annotation.page, tracker.annotationPages.contains(page) else { return }
            baseline.willChange(annotation, on: page)
        }
    }

    private nonisolated func report(_ body: @escaping @MainActor (ChangeTracker, DocumentBaseline) -> Void) {
        // PDFKit draws on other threads but changes documents only on the main one.
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard muted == 0, let baseline else { return }
            muting { body(self, baseline) }
        }
    }

    /// Runs `body` without reports (the baseline reading pages, a save copying them).
    @MainActor
    func muting<T>(_ body: () throws -> T) rethrows -> T {
        muted += 1
        defer { muted -= 1 }
        return try body()
    }

    fileprivate static var key: UInt8 = 0
}

/// PDFKit's document for a file DocumentKit opened: reports page insertions, removals and exchanges first.
final class TrackedDocument: PDFDocument {
    var tracker: ChangeTracker? { delegate as? ChangeTracker }

    /// `document`, reporting to a tracker of its own; called before any of its pages is read, so all are tracked.
    static func tracking(_ document: TrackedDocument?) -> TrackedDocument? {
        guard let document else { return nil }
        let tracker = ChangeTracker()
        objc_setAssociatedObject(document, &ChangeTracker.key, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        document.delegate = tracker
        return document
    }

    override func page(at index: Int) -> PDFKit.PDFPage? {
        let page = super.page(at: index)
        if let page { tracker?.handedOut(page, annotations: false) }
        return page
    }

    override func insert(_ page: PDFKit.PDFPage, at index: Int) {
        structureChange(.insert(page, index)) { super.insert(page, at: index) }
    }

    override func removePage(at index: Int) {
        structureChange(.remove(index)) { super.removePage(at: index) }
    }

    override func exchangePage(at indexA: Int, withPageAt indexB: Int) {
        structureChange(.exchange(indexA, indexB)) { super.exchangePage(at: indexA, withPageAt: indexB) }
    }

    private func structureChange(_ change: PageOrderChange, _ body: () -> Void) {
        guard Thread.isMainThread, let tracker else { return body() }
        MainActor.assumeIsolated {
            guard tracker.muted == 0 else { return body() }
            guard let baseline = tracker.baseline else {
                tracker.reorderedBeforeAttach = true
                return tracker.muting(body)
            }
            tracker.muting {
                baseline.willReorder(change, in: self)
                body()
                baseline.didReorder(in: self)
            }
        }
    }
}

/// How the page order changes (live indices before the change).
enum PageOrderChange {
    case insert(PDFKit.PDFPage, Int)
    case remove(Int)
    case exchange(Int, Int)
}

/// A page PDFKit read from the file: reports changes to its rotation, boxes and annotation list, and clicks on it.
final class TrackedPage: PDFKit.PDFPage {
    private var tracker: ChangeTracker? { document?.delegate as? ChangeTracker }

    private func willChange() { tracker?.pageWillChange(self) }

    override var annotations: [PDFAnnotation] {
        let annotations = super.annotations
        tracker?.handedOut(self, annotations: true)
        return annotations
    }

    override var rotation: Int {
        get { super.rotation }
        set { willChange(); super.rotation = newValue }
    }

    override func setBounds(_ bounds: NSRect, for box: PDFDisplayBox) {
        willChange()
        super.setBounds(bounds, for: box)
    }

    override func addAnnotation(_ annotation: PDFAnnotation) {
        willChange()
        super.addAnnotation(annotation)
    }

    override func removeAnnotation(_ annotation: PDFAnnotation) {
        willChange()
        super.removeAnnotation(annotation)
    }

    override func annotation(at point: NSPoint) -> PDFAnnotation? {
        willChange()
        return super.annotation(at: point)
    }
}

/// An annotation PDFKit read from the file (or made for one): reports every change before it happens.
final class TrackedAnnotation: PDFAnnotation {
    private func willChange() { (page?.document?.delegate as? ChangeTracker)?.annotationWillChange(self) }

    override func setValue(_ value: Any, forAnnotationKey key: PDFAnnotationKey) -> Bool {
        willChange()
        return super.setValue(value, forAnnotationKey: key)
    }

    override func setBoolean(_ value: Bool, forAnnotationKey key: PDFAnnotationKey) -> Bool {
        willChange()
        return super.setBoolean(value, forAnnotationKey: key)
    }

    override func setRect(_ value: NSRect, forAnnotationKey key: PDFAnnotationKey) -> Bool {
        willChange()
        return super.setRect(value, forAnnotationKey: key)
    }

    override func removeValue(forAnnotationKey key: PDFAnnotationKey) {
        willChange()
        super.removeValue(forAnnotationKey: key)
    }

    override func add(_ path: NSBezierPath) {
        willChange()
        super.add(path)
    }

    override func remove(_ path: NSBezierPath) {
        willChange()
        super.remove(path)
    }

    // Objects PDFKit writes back into the annotation when they are changed in place.
    override var paths: [NSBezierPath]? { willChange(); return super.paths }
    override var border: PDFBorder? { get { willChange(); return super.border } set { willChange(); super.border = newValue } }
    override var action: PDFAction? { get { willChange(); return super.action } set { willChange(); super.action = newValue } }
    override var destination: PDFKit.PDFDestination? {
        get { willChange(); return super.destination }
        set { willChange(); super.destination = newValue }
    }

    override var bounds: NSRect { get { super.bounds } set { willChange(); super.bounds = newValue } }
    override var shouldDisplay: Bool { get { super.shouldDisplay } set { willChange(); super.shouldDisplay = newValue } }
    override var shouldPrint: Bool { get { super.shouldPrint } set { willChange(); super.shouldPrint = newValue } }
    override var modificationDate: Date? { get { super.modificationDate } set { willChange(); super.modificationDate = newValue } }
    override var userName: String? { get { super.userName } set { willChange(); super.userName = newValue } }
    override var popup: PDFAnnotation? { get { super.popup } set { willChange(); super.popup = newValue } }
    override var color: NSColor { get { super.color } set { willChange(); super.color = newValue } }
    override var contents: String? { get { super.contents } set { willChange(); super.contents = newValue } }
    override var font: NSFont? { get { super.font } set { willChange(); super.font = newValue } }
    override var fontColor: NSColor? { get { super.fontColor } set { willChange(); super.fontColor = newValue } }
    override var interiorColor: NSColor? { get { super.interiorColor } set { willChange(); super.interiorColor = newValue } }
    override var alignment: NSTextAlignment { get { super.alignment } set { willChange(); super.alignment = newValue } }
    override var startPoint: NSPoint { get { super.startPoint } set { willChange(); super.startPoint = newValue } }
    override var endPoint: NSPoint { get { super.endPoint } set { willChange(); super.endPoint = newValue } }
    override var startLineStyle: PDFLineStyle { get { super.startLineStyle } set { willChange(); super.startLineStyle = newValue } }
    override var endLineStyle: PDFLineStyle { get { super.endLineStyle } set { willChange(); super.endLineStyle = newValue } }
    override var iconType: PDFTextAnnotationIconType { get { super.iconType } set { willChange(); super.iconType = newValue } }
    override var quadrilateralPoints: [NSValue]? { get { super.quadrilateralPoints } set { willChange(); super.quadrilateralPoints = newValue } }
    override var markupType: PDFMarkupType { get { super.markupType } set { willChange(); super.markupType = newValue } }
    override var widgetFieldType: PDFAnnotationWidgetSubtype { get { super.widgetFieldType } set { willChange(); super.widgetFieldType = newValue } }
    override var widgetControlType: PDFWidgetControlType { get { super.widgetControlType } set { willChange(); super.widgetControlType = newValue } }
    override var isMultiline: Bool { get { super.isMultiline } set { willChange(); super.isMultiline = newValue } }
    override var hasComb: Bool { get { super.hasComb } set { willChange(); super.hasComb = newValue } }
    override var maximumLength: Int { get { super.maximumLength } set { willChange(); super.maximumLength = newValue } }
    override var widgetStringValue: String? { get { super.widgetStringValue } set { willChange(); super.widgetStringValue = newValue } }
    override var widgetDefaultStringValue: String? {
        get { super.widgetDefaultStringValue }
        set { willChange(); super.widgetDefaultStringValue = newValue }
    }
    override var allowsToggleToOff: Bool { get { super.allowsToggleToOff } set { willChange(); super.allowsToggleToOff = newValue } }
    override var radiosInUnison: Bool { get { super.radiosInUnison } set { willChange(); super.radiosInUnison = newValue } }
    override var isReadOnly: Bool { get { super.isReadOnly } set { willChange(); super.isReadOnly = newValue } }
    override var isListChoice: Bool { get { super.isListChoice } set { willChange(); super.isListChoice = newValue } }
    override var choices: [String]? { get { super.choices } set { willChange(); super.choices = newValue } }
    override var values: [String]? { get { super.values } set { willChange(); super.values = newValue } }
    override var buttonWidgetState: PDFWidgetCellState { get { super.buttonWidgetState } set { willChange(); super.buttonWidgetState = newValue } }
    override var buttonWidgetStateString: String {
        get { super.buttonWidgetStateString }
        set { willChange(); super.buttonWidgetStateString = newValue }
    }
    override var isOpen: Bool { get { super.isOpen } set { willChange(); super.isOpen = newValue } }
    override var url: URL? { get { super.url } set { willChange(); super.url = newValue } }
    override var fieldName: String? { get { super.fieldName } set { willChange(); super.fieldName = newValue } }
    override var caption: String? { get { super.caption } set { willChange(); super.caption = newValue } }
    override var backgroundColor: NSColor? { get { super.backgroundColor } set { willChange(); super.backgroundColor = newValue } }
    override var stampName: String? { get { super.stampName } set { willChange(); super.stampName = newValue } }
}
