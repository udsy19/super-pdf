import AppKit
import AVFoundation
import PDFKit
import SuperPDFCore

// The provider's own views inside ToolsKit's panels (`ToolControl.custom`): the tool palettes of Highlight & notes and
// Draw & shapes (the bar's tools with their shortcuts, so people learn them), the Comments list's rows with Reply and
// Resolve, and the voice-note recorder. Each sizes itself with Auto Layout; ToolsKit makes them once.

/// One row of a palette: a tool, its symbol and its shortcut.
struct PaletteEntry {
    var title: String
    var symbol: String
    var shortcut: KeyCombo?
    var tool: MarkupTool
    var style: ((inout MarkupStyle) -> Void)?
}

@MainActor
final class ToolPaletteView: NSView {
    private unowned let session: MarkupSession
    private let entries: [PaletteEntry]
    private var rows: [(NSButton, PaletteEntry)] = []
    private let key = UUID()

    init(session: MarkupSession, entries: [PaletteEntry], swatches: [(String, MarkupColor, (inout MarkupStyle) -> Void)]) {
        self.session = session
        self.entries = entries
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for entry in entries {
            let handler = MenuHandler { [unowned self] in
                if let style = entry.style { self.session.restyle("Highlight Style", style) }
                self.session.setBarVisible(true)
                self.session.choose(entry.tool)
            }
            let button = NSButton(title: entry.title, image: NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) ?? NSImage(),
                                  target: handler, action: #selector(MenuHandler.run))
            button.imagePosition = .imageLeading
            button.bezelStyle = .toolbar
            button.setButtonType(.pushOnPushOff)
            button.showsBorderOnlyWhileMouseInside = true
            button.alignment = .left
            button.contentTintColor = nil
            objc_setAssociatedObject(button, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
            let shortcut = NSTextField(labelWithString: entry.shortcut?.description ?? "")
            shortcut.font = SPFont.secondary.font()
            shortcut.textColor = .secondaryLabelColor
            let row = NSStackView(views: [button, NSView(), shortcut])
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append((button, entry))
        }
        if !swatches.isEmpty {
            let chips = NSStackView()
            chips.orientation = .horizontal
            chips.spacing = 6
            for (name, color, change) in swatches {
                let handler = MenuHandler { [unowned self] in self.session.restyle(name == "Color" ? "Color" : "Highlight Style", change) }
                let chip = NSButton(image: MarkupBarView.swatch(color, filled: true, size: 22), target: handler, action: #selector(MenuHandler.run))
                chip.isBordered = false
                chip.setAccessibilityLabel(MarkupPalette.colors.first { $0.color == color }?.name ?? name)
                objc_setAssociatedObject(chip, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
                chips.addArrangedSubview(chip)
            }
            stack.addArrangedSubview(chips)
        }
        let footer = NSTextField(wrappingLabelWithString: MarkupKitStrings.Panel.paletteFooter)
        footer.font = SPFont.secondary.font()
        footer.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footer)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        session.observe(key) { [weak self] in self?.update() }
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func update() {
        for (button, entry) in rows { button.state = session.tool == entry.tool ? .on : .off }
    }

    override func viewDidMoveToWindow() {
        if window == nil { session.stopObserving(key) } else { session.observe(key) { [weak self] in self?.update() }; update() }
    }
}

nonisolated(unsafe) private var handlerKey: UInt8 = 0

/// The Comments list rows (ux §5.3, §6.3): page, author and words, with Reply and Resolve, filtered and sorted as
/// the panel says.
@MainActor
final class CommentRowsView: NSView {
    private unowned let session: MarkupSession
    private let stack = NSStackView()
    private let key = UUID()
    private let filter: String
    private let sort: String

    init(session: MarkupSession, filter: String, sort: String) {
        self.session = session
        self.filter = filter
        self.sort = sort
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        if window == nil { session.stopObserving(key) } else { session.observe(key) { [weak self] in self?.reload() } }
    }

    static func filtered(_ items: [CommentItem], filter: String, sort: String, me: String) -> [CommentItem] {
        let kept = items.filter { item in
            switch filter {
            case "mine": item.author == me
            case "unresolved": ![.resolved, .completed, .accepted, .rejected].contains(item.status)
            default: true
            }
        }
        return kept.sorted { a, b in
            switch sort {
            case "date": (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case "author": a.author.localizedStandardCompare(b.author) == .orderedAscending
            default: a.page < b.page || (a.page == b.page && a.bounds.maxY > b.bounds.maxY)
            }
        }
    }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = Self.filtered(session.service.comments(in: session.document), filter: filter, sort: sort, me: session.author)
        if items.isEmpty {
            let empty = NSTextField(labelWithString: filter == "unresolved" ? Strings.Empty.commentsUnresolved : Strings.Empty.highlightsAndNotes)
            empty.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        for item in items.prefix(200) { stack.addArrangedSubview(row(item)) }
    }

    private func row(_ item: CommentItem) -> NSView {
        let head = NSTextField(labelWithString: "\(item.page + 1)  " + [item.author, CommentList.title(of: item.kind)].filter { !$0.isEmpty }.joined(separator: " · "))
        head.font = SPFont.notesPageNumber.font()
        var words = item.text
        if let quoted = item.quotedText, words.isEmpty { words = "“\(quoted)”" }
        var views: [NSView] = [head]
        if !words.isEmpty {
            let body = NSTextField(wrappingLabelWithString: words)
            body.font = SPFont.body.font()
            body.maximumNumberOfLines = 4
            views.append(body)
        }
        for reply in item.replies {
            let line = NSTextField(wrappingLabelWithString: "↳ \(reply.author): \(reply.text)")
            line.font = SPFont.secondary.font()
            line.textColor = .secondaryLabelColor
            views.append(line)
        }
        if item.status != .none {
            let status = NSTextField(labelWithString: CommentList.state(for: item.status))
            status.font = SPFont.secondary.font()
            status.textColor = .secondaryLabelColor
            views.append(status)
        }
        let reply = action(MarkupKitStrings.Panel.reply) { [unowned self] in askReply(to: item) }
        let resolve = action(MarkupKitStrings.Panel.resolve) { [unowned self] in
            apply(session.service.setStatus(.resolved, of: item, in: session.document))
        }
        resolve.isEnabled = item.status != .resolved
        let buttons = NSStackView(views: [reply, resolve])
        buttons.orientation = .horizontal
        views.append(buttons)
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        let click = NSClickGestureRecognizer(target: self, action: #selector(reveal(_:)))
        column.addGestureRecognizer(click)
        column.identifier = NSUserInterfaceItemIdentifier(item.id)
        return column
    }

    private func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSButton {
        let handler = MenuHandler(run)
        let button = NSButton(title: title, target: handler, action: #selector(MenuHandler.run))
        button.bezelStyle = .push
        button.controlSize = .small
        objc_setAssociatedObject(button, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    /// Clicking a comment shows it on its page and selects it.
    @objc private func reveal(_ recognizer: NSClickGestureRecognizer) {
        guard let id = recognizer.view?.identifier?.rawValue, let (annotation, page) = CommentList.annotation(id, in: session.document) else { return }
        session.pdfView?.go(to: annotation.bounds, on: page)
        session.select(annotation, on: page)
    }

    private func askReply(to item: CommentItem) {
        let alert = NSAlert()
        alert.messageText = MarkupKitStrings.Panel.replyPrompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = MarkupKitStrings.Panel.replyPlaceholder
        alert.accessoryView = field
        alert.addButton(withTitle: MarkupKitStrings.Panel.reply)
        alert.addButton(withTitle: Strings.Panel.cancel)
        alert.window.initialFirstResponder = field
        let finish = { [unowned self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            apply(session.service.reply(to: item, text: field.stringValue, in: session.document))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    private func apply(_ group: UndoGroup) {
        session.register(group)
        session.refresh()
    }
}

/// Records a voice note into a scratch file (16-bit PCM, so it becomes a standard PDF sound object unchanged).
@MainActor
final class VoiceRecorderView: NSView {
    private(set) var recording: URL?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private let button = NSButton()
    private let playButton = NSButton()
    private let status = NSTextField(wrappingLabelWithString: MarkupKitStrings.Panel.recordHint)
    private let onRecorded: @MainActor (URL) -> Void

    init(onRecorded: @escaping @MainActor (URL) -> Void) {
        self.onRecorded = onRecorded
        super.init(frame: .zero)
        button.title = MarkupKitStrings.Panel.record
        button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(toggle)
        playButton.title = MarkupKitStrings.Panel.play
        playButton.bezelStyle = .push
        playButton.target = self
        playButton.action = #selector(play)
        playButton.isEnabled = false
        status.font = SPFont.secondary.font()
        status.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [button, playButton])
        let stack = NSStackView(views: [buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        if let recorder, recorder.isRecording {
            recorder.stop()
            self.recorder = nil
            button.title = MarkupKitStrings.Panel.record
            playButton.isEnabled = true
            if let recording {
                let seconds = (try? AVAudioFile(forReading: recording)).map { Int(Double($0.length) / $0.fileFormat.sampleRate) } ?? 0
                status.stringValue = MarkupKitStrings.Panel.recorded(seconds)
                onRecorded(recording)
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in self?.start(granted: granted) }
        }
    }

    private func start(granted: Bool) {
        guard granted else { status.stringValue = MarkupKitStrings.Panel.noMicrophone; return }
        let folder = SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(MarkupKitStrings.Panel.voiceNote).caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
            status.stringValue = MarkupKitStrings.Panel.noMicrophone
            return
        }
        self.recorder = recorder
        recording = url
        button.title = MarkupKitStrings.Panel.stop
        playButton.isEnabled = false
    }

    @objc private func play() {
        guard let recording else { return }
        player = try? AVAudioPlayer(contentsOf: recording)
        player?.play()
    }
}
