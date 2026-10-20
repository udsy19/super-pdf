import AppKit
import SuperPDFCore
import SwiftUI

/// A tool panel (ux §5.1): the 320 pt column on the right of the document. Header with back, category icon, title and
/// close; the hint (and a G panel's steps or a mode panel's switch); the controls in order with the scope row and More
/// options; a message above the footer; the footer with the output line, one primary button and Cancel.
struct ToolPanelView: View {
    @ObservedObject var session: ToolSession
    var onBack: () -> Void
    var onClose: () -> Void

    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                content
                    .padding(.top, Style.Panel.contentTop)
                    .padding(.horizontal, SPMetrics.ToolPanel.contentInset)
                    .padding(.bottom, Style.Panel.contentTop)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            if let message = session.message {
                MessageView(message: message, showsDetails: $showsDetails) { action in Task { await session.perform(action) } }
                    .padding(.horizontal, SPMetrics.ToolPanel.contentInset)
                    .padding(.bottom, 12)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { PanelBackground() }
        .onExitCommand(perform: onClose)
        .environment(\.openURL, OpenURLAction { url in
            if url == Self.changeURL { Task { await session.changeDestination() } ; return .handled }
            return .systemAction
        })
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HeaderButton(symbol: "chevron.left", label: Strings.Panel.back, action: onBack)
                CategoryIcon(tile: session.tile)
                Text(session.tile.name).font(.sp(SPFont.panelTitle)).foregroundStyle(Color(Style.label)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HeaderButton(symbol: "xmark", label: Strings.Panel.cancel, action: onClose)
            }
            Text(session.panel.hint ?? session.tile.hint)
                .font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary)).lineSpacing(1.8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Style.Panel.hintIndent).padding(.top, 6)
            if let notice = session.panel.notice {
                Text(notice).font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary)).lineSpacing(1.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Style.Panel.hintIndent).padding(.top, 6)
            }
            if case .segmented(let id, _, let options, _)? = session.layout.headerSwitch {
                SegmentedBar(options: options, selected: string(id), quietUnselected: true) { session.set(id, .string($0)) }
                    .padding(.top, 10)
            } else if !session.layout.steps.isEmpty {
                let steps = session.layout.steps.enumerated().map { ToolOption("\($0.offset)", $0.element) }
                SegmentedBar(options: steps, selected: "\(session.layout.currentStep)", quietUnselected: true).padding(.top, 10)
                    .accessibilityLabel(session.layout.steps.joined(separator: ", "))
            }
        }
        .padding(.top, Style.Panel.headerTop)
        .padding(.leading, Style.Panel.headerLeading)
        .padding(.trailing, Style.Panel.headerTrailing)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Style.Panel.gap) {
            ForEach(Array(session.summary.enumerated()), id: \.offset) { _, line in SummaryRow(line: SummaryLine(line)) }
            let focusID = firstTextID
            ForEach(Array(session.layout.body.enumerated()), id: \.offset) { index, item in
                switch item {
                case .control(let control): ControlView(control: control, session: session, focusOnAppear: control.id == focusID)
                    .id(control.id ?? "item-\(index)")
                case .scope: ScopeRow(session: session)
                case .moreOptions:
                    DisclosureRow(isOpen: session.isMoreOptionsOpen) { session.isMoreOptionsOpen.toggle() }
                    if session.isMoreOptionsOpen {
                        ForEach(Array(session.layout.moreOptions.enumerated()), id: \.offset) { _, control in
                            ControlView(control: control, session: session, focusOnAppear: false)
                        }
                    }
                }
            }
        }
    }

    /// The first text field gets the keyboard when the panel opens (Watermark's "DRAFT", Black out's search).
    private var firstTextID: String? {
        for item in session.layout.body {
            if case .control(.text(let id, _, _, _, _)) = item { return id }
        }
        return nil
    }

    private func string(_ id: String) -> String? {
        if case .string(let s)? = session.values[id] { return s }
        return nil
    }

    // MARK: Footer

    static let changeURL = URL(string: "toolskit-change:destination")!

    private var footer: some View {
        VStack(spacing: Style.Panel.footerGap) {
            if let line = session.outputLine { OutputLine(text: line.text, fileName: line.fileName, offersChange: line.offersChange) }
            HStack(alignment: .top, spacing: 8) {
                if session.canGoBack {
                    Button { session.back() } label: {
                        HStack(spacing: 6) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)); Text(Strings.Panel.back) }
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
                if session.isRunning {
                    ProgressBar(session: session)
                } else {
                    Button(session.panel.primary.title) { Task { await session.primary() } }
                        .buttonStyle(PrimaryButtonStyle(isDestructive: session.panel.primary.isDestructive))
                        .disabled(!session.canRun)
                        .keyboardShortcut(.defaultAction)
                }
            }
            if let secondary = session.panel.secondary {
                Button(secondary.title) {
                    if session.secondaryIsCancel { onClose() } else { Task { await session.perform(ToolPanel.secondaryAction) } }
                }
                .buttonStyle(.plain)
                .font(.sp(SPFont.secondaryButton))
                .foregroundStyle(Color(secondary.isDestructive ? Style.destructive : Style.secondary))
                .disabled(!secondary.isEnabled || session.isRunning)
            }
        }
        .padding(.top, Style.Panel.footerTop)
        .padding(.horizontal, SPMetrics.ToolPanel.contentInset)
        .padding(.bottom, Style.Panel.footerBottom)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Color(Style.separator)).frame(height: 1) }
    }
}

// MARK: - Parts

/// The vibrant sidebar material, or its solid look in offscreen renders.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if Style.opaqueBackgrounds {
            let solid = SolidView()
            solid.color = { Style.surface }
            return solid
        }
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct HeaderButton: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(Style.secondary))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct CategoryIcon: View {
    var tile: ToolTile
    var body: some View {
        Image(systemName: tile.symbol).font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(Style.category(tile.section)))
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color(Style.category(tile.section)).opacity(SPMetrics.Tile.iconCircleOpacity)))
            .accessibilityHidden(true)
    }
}

/// "Now   6.1 MB · 12 pages · 9 pictures" (ToolPreview.summary).
private struct SummaryRow: View {
    var line: SummaryLine
    var body: some View {
        if let label = line.label {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(Color(Style.label))
                Spacer(minLength: 8)
                (Text(line.emphasis).font(.sp(size: 13, weight: .semibold)).foregroundColor(Color(Style.label))
                    + Text(line.rest).foregroundColor(Color(Style.secondary)))
            }
            .font(.sp(SPFont.body))
            .accessibilityElement(children: .combine)
        } else {
            Note(text: line.rest)
        }
    }
}

struct Note: View {
    var text: String
    var body: some View {
        Text(text).font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary)).lineSpacing(2.4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DisclosureRow: View {
    var isOpen: Bool
    var toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(Style.secondary))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(Strings.Panel.moreOptions).font(.sp(SPFont.body)).foregroundStyle(Color(Style.label))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? "open" : "closed")
    }
}

/// "Saves “Report (smaller).pdf” next to the original · Change…", or Black out's and Sign's
/// "Saves “Lease agreement (signed).pdf” · the original is untouched".
private struct OutputLine: View {
    var text: String
    var fileName: String
    var offersChange: Bool
    var body: some View {
        var line = AttributedString(text)
        line.font = .sp(SPFont.secondary)
        line.foregroundColor = Color(Style.secondary)
        if let range = line.range(of: Strings.quoted(fileName)) {
            line[range].foregroundColor = Color(Style.label)
            line[range].font = .sp(size: 11, weight: .medium)
        }
        var change = AttributedString(Strings.Panel.change)
        change.font = .sp(SPFont.secondary)
        change.foregroundColor = Color(Style.accent)
        change.link = ToolPanelView.changeURL
        var dot = AttributedString(" · ")
        dot.font = .sp(SPFont.secondary)
        dot.foregroundColor = Color(Style.secondary)
        return Text(offersChange ? line + dot + change : line).multilineTextAlignment(.center).lineSpacing(2.2).tint(Color(Style.accent))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The primary button while running: a bar with "Page 14 of 120 · Stop" (ux §5.1).
private struct ProgressBar: View {
    @ObservedObject var session: ToolSession
    var body: some View {
        let fraction: Double = if case .running(let update?) = session.phase { update.fraction } else { 0 }
        ZStack {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: SPMetrics.PrimaryButton.radius, style: .continuous).fill(Color(Style.accent).opacity(0.15))
                RoundedRectangle(cornerRadius: SPMetrics.PrimaryButton.radius, style: .continuous).fill(Color(Style.accent).opacity(0.35))
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.2), value: fraction)
            }
            HStack(spacing: 0) {
                Text((session.progressLabel ?? "") + ToolsKitStrings.progressSeparator).foregroundStyle(Color(Style.label))
                Button(Strings.Panel.stop) { session.stop() }.buttonStyle(.plain).foregroundStyle(Color(Style.accent))
            }
            .font(.sp(SPFont.primaryButton))
        }
        .frame(maxWidth: .infinity, minHeight: SPMetrics.PrimaryButton.height, maxHeight: SPMetrics.PrimaryButton.height)
        .accessibilityElement(children: .contain)
        .accessibilityValue(session.progressLabel ?? "")
    }
}

/// An error or note above the footer: icon, the sentence, one action, details behind "Show details" (ux §7.4).
private struct MessageView: View {
    var message: ToolMessage
    @Binding var showsDetails: Bool
    var perform: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(message.kind == .error ? Style.destructive : message.kind == .warning ? NSColor.systemOrange : Style.secondary))
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text).font(.sp(SPFont.body)).foregroundStyle(Color(Style.label)).fixedSize(horizontal: false, vertical: true)
                if message.action != nil || message.details != nil {
                    HStack(spacing: 10) {
                        if let action = message.action {
                            Button(action.title) { perform(action.id) }.buttonStyle(BorderedButtonStyle())
                        }
                        if message.details != nil {
                            Button(Strings.Panel.showDetails) { showsDetails.toggle() }.buttonStyle(.plain)
                                .font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.accent))
                        }
                    }
                }
                if showsDetails, let details = message.details {
                    Text(details).font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary)).textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The "Pages" scope row (ux §5.1): All 12 pages · This page · Selected pages · some pages typed as "3–5".
private struct ScopeRow: View {
    @ObservedObject var session: ToolSession
    @State private var rangeText = ""

    private var options: [ToolOption] {
        let count = session.document?.pageCount ?? 0
        var options = [ToolOption("all", Strings.Panel.scope(.all, pageCount: count)),
                       ToolOption("current", Strings.Panel.scope(.current, pageCount: count))]
        if session.selection.count > 1 {
            options.append(ToolOption("selected", Strings.Panel.scope(.selected(session.selection), pageCount: count)))
        }
        options.append(ToolOption("ranges", ToolsKitStrings.rangeItem))
        return options
    }

    private var selected: String {
        switch session.scope {
        case .all: "all"
        case .current: "current"
        case .selected: "selected"
        case .ranges: "ranges"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ControlRow(label: Strings.Panel.scopeLabel) {
                PopupField(options: options, selected: selected, titleOverride: titleOverride) { id in
                    switch id {
                    case "all": session.setScope(.all)
                    case "current": session.setScope(.current)
                    case "selected": session.setScope(.selected(session.selection))
                    default:
                        let ranges = PageRanges([session.currentPage...session.currentPage])
                        rangeText = ranges.display
                        session.setScope(.ranges(ranges))
                    }
                }
                .frame(height: 24)
            }
            if case .ranges = session.scope {
                ControlRow(label: "") {
                    PanelTextField(placeholder: ToolsKitStrings.rangePlaceholder, value: rangeText, isSecure: false, focusOnAppear: true) { text in
                        rangeText = text
                        if let count = session.document?.pageCount, let ranges = PageRanges.parse(text, pageCount: count) {
                            session.setScope(.ranges(ranges))
                        }
                    }
                }
            }
        }
        .onAppear { if case .ranges(let ranges) = session.scope { rangeText = ranges.display } }
    }

    private var titleOverride: String? {
        if case .ranges(let ranges) = session.scope { return ranges.display }
        return nil
    }
}

/// One `ToolControl`, bound to the session's values.
struct ControlView: View {
    var control: ToolControl
    @ObservedObject var session: ToolSession
    var focusOnAppear: Bool

    var body: some View {
        switch control {
        case .segmented(let id, let label, let options, _):
            ControlRow(label: label) { SegmentedBar(options: options, selected: string(id)) { session.set(id, .string($0)) } }
        case .radio(let id, let options, _):
            PresetCards(options: options, selected: string(id)) { session.set(id, .string($0)) }
        case .popup(let id, let label, let options, _):
            ControlRow(label: label) {
                PopupField(options: Array(options.prefix(SPMetrics.ToolPanel.maximumPopupItems)), selected: string(id), titleOverride: nil) {
                    session.set(id, .string($0))
                }
                .frame(height: 24)
            }
        case .slider(let id, let label, let range, let step, _, let format):
            ControlRow(label: label) {
                ValueSlider(range: range, step: step, value: number(id), format: format) { session.set(id, .double($0)) }
            }
        case .stepper(let id, let label, let range, _):
            ControlRow(label: label) {
                HStack(spacing: 6) {
                    Text("\(int(id))").font(.sp(SPFont.body)).frame(minWidth: 28, alignment: .trailing)
                    Stepper("", value: Binding(get: { int(id) }, set: { session.set(id, .int($0)) }), in: range).labelsHidden()
                    Spacer(minLength: 0)
                }
            }
        case .toggle(let id, let label, _, let rowLabel):
            if let rowLabel {
                ControlRow(label: rowLabel) { CheckRow(label: label, isOn: session.values.bool(id)) { session.set(id, .bool($0)) } }
            } else {
                CheckRow(label: label, isOn: session.values.bool(id)) { session.set(id, .bool($0)) }
            }
        case .text(let id, let label, let placeholder, _, let isSecure):
            ControlRow(label: label) {
                PanelTextField(placeholder: placeholder, value: session.values.string(id), isSecure: isSecure, focusOnAppear: focusOnAppear) {
                    session.set(id, .string($0))
                }
            }
        case .files(let id, let label, let types, let allowsMultiple):
            FilesZone(label: label, types: types, allowsMultiple: allowsMultiple, files: session.values.files(id)) { session.set(id, .files($0)) }
        case .positionGrid(let id, let columns, let rows, _):
            PositionGrid(columns: columns, rows: rows, selected: session.values.int(id)) { session.set(id, .int($0)) }
        case .action(let id, let title, let isDestructive, let symbol):
            Button { Task { await session.perform(id) } } label: {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
                    Text(title)
                }
            }
            .buttonStyle(BorderedButtonStyle(isDestructive: isDestructive))
        case .checklist(let id, let items, _):
            RowCard(rows: items, mark: .checkbox(session.values.strings(id), { session.set(id, .strings($0)) }))
        case .chips(let id, let options, _, let allowsMultiple):
            Chips(options: options, selected: session.values.strings(id), allowsMultiple: allowsMultiple) { session.set(id, .strings($0)) }
        case .list(let rows):
            RowCard(rows: rows, mark: .fact)
        case .note(let text):
            Note(text: text)
        case .custom(_, let make):
            CustomControl(make: make)
        case .scope, .moreOptions:
            EmptyView()
        }
    }

    private func string(_ id: String) -> String? {
        if case .string(let s)? = session.values[id] { return s }
        return nil
    }
    private func number(_ id: String) -> Double { session.values.double(id) }
    private func int(_ id: String) -> Int { session.values.int(id) }
}
