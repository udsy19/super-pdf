import AppKit
import Combine
import SuperPDFCore

/// The pages gathered while a Scan panel is open (ux §5.3 step 3: "pages come in"), kept by the provider so they
/// survive the panel being drawn again; the panel's view watches it.
@MainActor
final class ScanSession: ObservableObject {
    @Published var pages: [ScannedPage] = []
    @Published var isWorking = false
    /// A line under the thumbnails ("Scanning…", "No iPhone or iPad nearby…").
    @Published var status: String?
    private var task: Task<Void, Never>?

    /// Adds the stream's pages as they arrive; a failure shows as the status line and is handed back.
    @discardableResult
    func collect(_ stream: AsyncThrowingStream<ScannedPage, Error>, working: String) async -> Error? {
        isWorking = true
        status = working
        defer { isWorking = false }
        do {
            for try await page in stream { pages.append(page) }
            status = nil
            return nil
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return error
        }
    }

    /// Starts collecting without waiting (the iPhone import, whose pages arrive whenever the person sends them).
    func start(_ stream: AsyncThrowingStream<ScannedPage, Error>, working: String) {
        task?.cancel()
        task = Task { await collect(stream, working: working) }
    }

    func reset() {
        task?.cancel()
        task = nil
        pages = []
        isWorking = false
        status = nil
    }
}

/// Thumbnails of the gathered pages with the status line, four to a row.
@MainActor
final class ScanPagesView: NSView {
    private let session: ScanSession
    private let stack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var observation: AnyCancellable?

    static let columns = 4
    static let thumbnailHeight: CGFloat = 76

    init(session: ScanSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observation = session.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statusLabel.stringValue = session.status ?? ScanStrings.scanned(session.pages.count)
        stack.addArrangedSubview(statusLabel)
        var row: NSStackView?
        for (index, page) in session.pages.enumerated() {
            if index % Self.columns == 0 {
                let next = NSStackView()
                next.orientation = .horizontal
                next.spacing = 8
                stack.addArrangedSubview(next)
                row = next
            }
            row?.addArrangedSubview(thumbnail(page, number: index + 1))
        }
        invalidateIntrinsicContentSize()
    }

    private func thumbnail(_ page: ScannedPage, number: Int) -> NSView {
        let view = NSImageView()
        view.image = NSImage(data: page.image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.setAccessibilityLabel(Strings.Panel.progress(page: number, of: session.pages.count))
        let aspect = page.pixelSize.height > 0 ? page.pixelSize.width / page.pixelSize.height : 0.77
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            view.widthAnchor.constraint(equalToConstant: min(Self.thumbnailHeight * aspect, Self.thumbnailHeight)),
        ])
        return view
    }
}
