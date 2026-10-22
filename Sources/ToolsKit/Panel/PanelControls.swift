import AppKit
import SuperPDFCore
import SwiftUI
import UniformTypeIdentifiers

// The panel's controls (ux §5.1) drawn as the mockups draw them (docs/mockups/src/shared.css): labelled rows with a
// 70 pt label column, full-width segmented bars, preset cards, popups with the accent arrows, sliders with a live value,
// checkboxes, chips, checklists and fact cards. Each keeps the native control's accessibility.

/// "Label   [control]" (`.ctl-row`).
struct ControlRow<Content: View>: View {
    var label: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let label {
            HStack(spacing: 10) {
                Text(label).font(.sp(SPFont.body)).foregroundStyle(Color(Style.label))
                    .frame(width: Style.Panel.labelWidth, alignment: .leading)
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Segmented

/// The full-width segmented bar (`.segc`, and `.steps` for G steps and a mode panel's switch in the header).
struct SegmentedBar: View {
    var options: [ToolOption]
    var selected: String?
    /// What a screen reader calls the bar ("Format"); empty for the header's switch.
    var label = ""
    /// The header style: unselected segments in the secondary colour.
    var quietUnselected = false
    var onSelect: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { option in
                let on = option.id == selected
                Text(option.title)
                    .font(.sp(size: 12, weight: on ? .medium : .regular))
                    .foregroundStyle(Color(on || !quietUnselected ? Style.label : Style.secondary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(Style.control))
                                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if let onSelect, !on { onSelect(option.id) } }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(Style.faintFill)))
        .accessibilityRepresentation {
            Picker(label, selection: Binding(get: { selected ?? "" }, set: { onSelect?($0) })) {
                ForEach(options, id: \.id) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Preset cards (archetype B)

struct PresetCards: View {
    var options: [ToolOption]
    var selected: String?
    var onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: Style.Panel.gap) {
            ForEach(options, id: \.id) { option in
                PresetCard(option: option, isOn: option.id == selected).onTapGesture { onSelect(option.id) }
            }
        }
    }
}

struct PresetCard: View {
    var option: ToolOption
    var isOn: Bool

    /// "Good (recommended)" → "Good", "(recommended)".
    private var parts: (String, String?) {
        let title = option.title
        guard title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) else { return (title, nil) }
        return (String(title[..<open.lowerBound]), String(title[title.index(after: open.lowerBound)...]))
    }

    var body: some View {
        // The mockup's lines are 1.3 × 13 pt tall, the 11 pt detail included.
        HStack(alignment: .top, spacing: 9) {
            RadioDot(isOn: isOn).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                (Text(parts.0).font(.sp(size: 13, weight: .semibold))
                    + Text(parts.1.map { " " + $0 } ?? "").font(.sp(size: 11, weight: .medium)).foregroundColor(Color(Style.secondary)))
                    .foregroundColor(Color(Style.label))
                if let detail = option.detail {
                    Text(detail).font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary)).lineSpacing(3.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value = option.value {
                Text(value).font(.sp(size: 13, weight: .semibold)).foregroundStyle(Color(Style.label))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(isOn ? Style.accentSoft : Style.control)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(isOn ? Style.accent : Style.separator), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }
}

struct RadioDot: View {
    var isOn: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color(isOn ? Style.accent : .white))
            Circle().strokeBorder(Color(isOn ? Style.accent : Style.strongSeparator), lineWidth: 1)
            if isOn { Circle().fill(.white).frame(width: 6, height: 6) }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Checkbox

struct CheckBox: View {
    var isOn: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(isOn ? Style.accent : .white))
            RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(isOn ? Style.accent : Style.strongSeparator), lineWidth: 1)
            if isOn {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct CheckRow: View {
    var label: String
    var isOn: Bool
    var onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CheckBox(isOn: isOn).padding(.top, 2)
            Text(label).font(.sp(SPFont.body)).foregroundStyle(Color(Style.label)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle(!isOn) }
        .accessibilityRepresentation { Toggle(label, isOn: Binding(get: { isOn }, set: onToggle)) }
    }
}

// MARK: - Slider

struct ValueSlider: View {
    var range: ClosedRange<Double>
    var step: Double
    var value: Double
    var format: ToolValueFormat
    var label = ""
    var onChange: (Double) -> Void

    private var fraction: Double { range.upperBound > range.lowerBound ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0 }

    private func snapped(_ v: Double) -> Double {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        return min(max((clamped / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width, p = min(max(fraction, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(Style.strongSeparator)).frame(height: 4)
                    Capsule().fill(Color(Style.accent)).frame(width: w * p, height: 4)
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: w * p - 9)
                }
                .frame(height: 18)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    guard w > 0 else { return }
                    onChange(snapped(range.lowerBound + Double(drag.location.x / w) * (range.upperBound - range.lowerBound)))
                })
            }
            .frame(height: 18)
            Text(Self.format(value, format)).font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary))
                .frame(minWidth: 32, alignment: .trailing)
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { onChange(snapped($0)) }), in: range, step: step > 0 ? step : 1)
                .accessibilityLabel(label)
                .accessibilityValue(Self.format(value, format))
        }
    }

    static func format(_ value: Double, _ format: ToolValueFormat) -> String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        switch format {
        case .plain: return number
        case .percent: return number + "%"
        case .points: return number + " pt"
        case .dpi: return number + " dpi"
        case .degrees: return number + "°"
        }
    }
}

// MARK: - Popup

/// The mockup's popup: a white field with the choice and the accent arrows; clicking shows the native menu.
struct PopupField: NSViewRepresentable {
    var options: [ToolOption]
    var selected: String?
    /// Shown instead of the selected option's title (the scope's "3–5").
    var titleOverride: String?
    /// What a screen reader calls the popup ("Picture sharpness").
    var label = ""
    var onSelect: (String) -> Void

    func makeNSView(context: Context) -> PopupFieldView { PopupFieldView() }

    func updateNSView(_ view: PopupFieldView, context: Context) {
        view.options = options
        view.selected = selected
        view.title = titleOverride ?? options.first { $0.id == selected }?.title ?? ""
        view.label = label
        view.onSelect = onSelect
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopupFieldView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: 24)
    }
}

final class PopupFieldView: NSView {
    var options: [ToolOption] = []
    var selected: String?
    var title = ""
    var label = ""
    var onSelect: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.05)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        Style.control.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        Style.strongSeparator.setStroke()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).stroke()

        let arrows = NSRect(x: bounds.maxX - 6 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        Style.accent.setFill()
        NSBezierPath(roundedRect: arrows, xRadius: 5, yRadius: 5).fill()
        let glyph = symbol("chevron.up.chevron.down", size: 8, weight: .bold)
        let tinted = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: arrows.midX - glyph.size.width / 2, y: arrows.midY - glyph.size.height / 2,
                               width: glyph.size.width, height: glyph.size.height), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil)

        let font = Style.font(SPFont.body)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Style.label]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(in: NSRect(x: 8, y: (bounds.height - size.height) / 2, width: arrows.minX - 14, height: size.height),
                                 withAttributes: attributes)
    }

    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { title }
    override func mouseDown(with event: NSEvent) { showMenu() }
    override func accessibilityPerformPress() -> Bool { showMenu(); return true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 125 { showMenu() } else { super.keyDown(with: event) }
    }

    private func showMenu() {
        let menu = NSMenu()
        var current: NSMenuItem?
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            if let detail = option.detail {
                let text = NSMutableAttributedString(string: option.title, attributes: [.font: Style.font(SPFont.body)])
                text.append(NSAttributedString(string: "  " + detail, attributes: [.font: Style.font(SPFont.secondary),
                                                                                    .foregroundColor: Style.secondary]))
                item.attributedTitle = text
            }
            if option.id == selected { item.state = .on; current = item }
            menu.addItem(item)
        }
        menu.minimumWidth = bounds.width
        menu.popUp(positioning: current, at: NSPoint(x: 0, y: bounds.height - 4), in: self)
    }

    @objc private func choose(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onSelect?(id) }
    }
}

// MARK: - Text field

struct PanelTextField: View {
    var placeholder: String
    /// What a screen reader calls the field; its placeholder when there is no label.
    var label: String?
    var value: String
    var isSecure: Bool
    var focusOnAppear: Bool
    var onChange: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let binding = Binding(get: { value }, set: onChange)
        Group {
            if isSecure {
                SecureField("", text: binding, prompt: Text(placeholder))
            } else {
                TextField("", text: binding, prompt: Text(placeholder))
            }
        }
        .textFieldStyle(.plain)
        .font(.sp(SPFont.body))
        .focused($focused)
        .accessibilityLabel(label ?? placeholder)
        .padding(.horizontal, 8)
        .frame(height: SPMetrics.ToolPanel.textFieldHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(Style.control)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color(focused ? Style.accent : Style.strongSeparator), lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Style.accentSoft)).padding(-3).opacity(focused ? 1 : 0))
        .onAppear { if focusOnAppear { DispatchQueue.main.async { focused = true } } }
    }
}

// MARK: - Chips, checklist, facts

/// Wraps its children into lines, left to right (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct Chips: View {
    var options: [ToolOption]
    var selected: [String]
    var allowsMultiple: Bool
    var onChange: ([String]) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.id) { option in
                let on = selected.contains(option.id)
                HStack(spacing: 5) {
                    if let name = option.symbol { Image(systemName: name).font(.system(size: 11)) }
                    Text(option.title).font(.sp(size: 12))
                    if let count = option.value {
                        Text(count).font(.sp(size: 11)).foregroundStyle(Color(on ? Style.accent : Style.secondary))
                    }
                }
                .foregroundStyle(Color(on ? Style.accent : Style.label))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color(on ? Style.accentSoft : Style.control)))
                .overlay(Capsule().strokeBorder(Color(on ? Style.accent : Style.strongSeparator), lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture {
                    if allowsMultiple { onChange(on ? selected.filter { $0 != option.id } : selected + [option.id]) }
                    else if !on { onChange([option.id]) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
            }
        }
    }
}

/// A card of rows (`.list`): checkboxes (`checklist`) or a green check (`facts`), the value on the right.
struct RowCard: View {
    enum Mark { case checkbox([String], ([String]) -> Void), fact }
    var rows: [ToolOption]
    var mark: Mark

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    switch mark {
                    case .checkbox(let selected, _): CheckBox(isOn: selected.contains(row.id))
                    case .fact:
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(SPColor.categoryGreen.color))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color(SPColor.categoryGreen.color).opacity(0.15)))
                    }
                    Text(row.title).font(.sp(size: 12)).foregroundStyle(Color(Style.label)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let value = row.value { Text(value).font(.sp(SPFont.secondary)).foregroundStyle(Color(Style.secondary)) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    if case .checkbox(let selected, let change) = mark {
                        change(selected.contains(row.id) ? selected.filter { $0 != row.id } : selected + [row.id])
                    }
                }
                .accessibilityElement(children: .combine)
                if index < rows.count - 1 { Rectangle().fill(Color(Style.separator)).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(Style.control)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(Style.separator), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Position grid, stepper, action, files

struct PositionGrid: View {
    var columns: Int
    var rows: Int
    var selected: Int
    var onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        Circle()
                            .fill(Color(index == selected ? Style.accent : Style.strongSeparator))
                            .frame(width: 8, height: 8)
                            .frame(width: 22, height: 18)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(index) }
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(Style.control)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(Style.separator), lineWidth: 1))
        .accessibilityRepresentation {
            Picker(ToolsKitStrings.position, selection: Binding(get: { selected }, set: onSelect)) {
                ForEach(0..<(rows * columns), id: \.self) { Text("\($0 / columns + 1), \($0 % columns + 1)").tag($0) }
            }
        }
    }
}

/// The bordered button (`.btn`): in-panel actions and the flow's Back.
struct BorderedButtonStyle: ButtonStyle {
    var isDestructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sp(SPFont.body))
            .foregroundStyle(Color(isDestructive ? Style.destructive : Style.label))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(Style.control)).shadow(color: .black.opacity(0.05), radius: 0.5, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(Style.strongSeparator), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The primary button (ux §2.1): full width, 36 pt, 10 pt corners, accent (red when destructive), 13 pt semibold white.
struct PrimaryButtonStyle: ButtonStyle {
    var isDestructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sp(SPFont.primaryButton))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: SPMetrics.PrimaryButton.height, maxHeight: SPMetrics.PrimaryButton.height)
            .background(RoundedRectangle(cornerRadius: SPMetrics.PrimaryButton.radius, style: .continuous)
                .fill(Color(isDestructive ? Style.destructive : Style.accent))
                .overlay(RoundedRectangle(cornerRadius: SPMetrics.PrimaryButton.radius, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1))
            .opacity(isEnabled ? 1 : SPMetrics.PrimaryButton.disabledOpacity)
            .contentShape(Rectangle())
    }
}

struct FilesZone: View {
    /// Each row's "Pages: all ▾" (`ToolControl.files` with `pagesPerFile`, ux §5.3 Combine).
    struct Pages {
        var choice: (URL) -> String?
        var choose: (URL, String?) -> Void
    }

    var label: String
    var types: [String]
    var allowsMultiple: Bool
    var files: [URL]
    var pages: Pages?
    var onChange: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(Color(Style.secondary))
                Text(label).font(.sp(SPFont.body)).foregroundStyle(Color(Style.secondary)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(targeted ? Style.accent.withAlphaComponent(SPMetrics.DropTarget.tintOpacity) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(targeted ? Style.accent : Style.strongSeparator),
                              style: StrokeStyle(lineWidth: targeted ? SPMetrics.DropTarget.ring : 1.5, dash: targeted ? [] : [5, 4])))
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, choose)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                           let file = URL(dataRepresentation: url, relativeTo: nil) { urls.append(file) }
                    }
                    if !urls.isEmpty { onChange(allowsMultiple ? files + urls : [urls[0]]) }
                }
                return true
            }
            ForEach(files, id: \.self) { file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 16, height: 16)
                        Text(file.lastPathComponent).font(.sp(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button { onChange(files.filter { $0 != file }) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(Color(Style.secondary)).accessibilityLabel(Strings.Panel.cancel)
                    }
                    if let pages { FilePagesRow(file: file, choice: pages.choice(file)) { pages.choose(file, $0) } }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType($0) }
        // Not modal: a screen reader's press returns at once, and the panel is another window to drive.
        panel.begin { response in
            guard response == .OK else { return }
            onChange(allowsMultiple ? files + panel.urls : Array(panel.urls.prefix(1)))
        }
    }
}

/// "Pages: All ▾" under a file in a queue: all its pages, or some typed as "1–3, 7" (the scope row's way, ux §5.1).
private struct FilePagesRow: View {
    var file: URL
    var choice: String?
    var onChange: (String?) -> Void
    @State private var text = ""
    @State private var typing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Strings.Panel.scopeLabel).font(.sp(size: 11)).foregroundStyle(Color(Style.secondary))
                PopupField(options: [ToolOption("all", ToolsKitStrings.allPages), ToolOption("some", ToolsKitStrings.rangeItem)],
                           selected: some ? "some" : "all", titleOverride: choice, label: ToolsKitStrings.pagesOf(file.lastPathComponent)) { id in
                    if id == "all" {
                        typing = false
                        text = ""
                        onChange(nil)
                    } else {
                        typing = true
                    }
                }
                .frame(width: 140, height: 24)
            }
            .padding(.leading, 22)
            if some {
                PanelTextField(placeholder: ToolsKitStrings.rangePlaceholder, value: text, isSecure: false, focusOnAppear: choice == nil) { typed in
                    text = typed
                    if PageRanges.parse(typed, pageCount: ToolValues.anyPageCount) != nil { onChange(typed) }
                }
                .padding(.leading, 22)
            }
        }
        .onAppear { text = choice ?? "" }
    }

    private var some: Bool { typing || choice != nil }
}

/// A provider's own view (`.custom`), made once per id and sized to its fitting height.
struct CustomControl: NSViewRepresentable {
    var make: @MainActor () -> NSView

    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.fittingSize.width
        let fitting = nsView.fittingSize
        return CGSize(width: width, height: fitting.height > 0 ? fitting.height : nsView.frame.height)
    }
}
