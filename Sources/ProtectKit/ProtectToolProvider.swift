import AppKit
import PDFKit
import SuperPDFCore

/// The Protect section's tiles (ux §4.1, §5.3): Add a password, Remove password, Black out, Lock in notes & fields and
/// Remove hidden info. Panels are described here; the work is `ProtectService`'s.
@MainActor
final class ProtectToolProvider: ToolProviding {
    /// The action the hand-marking view sends when its marks change.
    static let marksChangedAction = "marks-changed"

    private let service: ProtectService
    /// Hand marks of each document whose Black out panel is in hand mode.
    private var handMarks: [UUID: HandMarks] = [:]
    /// The last Find and mark results: document, search signature, marks.
    private var found: (document: UUID, signature: String, marks: [RedactionMark])?
    /// Remove hidden info's findings per document, with the fingerprint of the bytes they were found in.
    private var inventories: [UUID: (fingerprint: String, inventory: HiddenInfoInventory)] = [:]

    init(service: ProtectService) { self.service = service }

    var tools: [ToolID] { ToolCatalog.tiles(ownedBy: .protectKit).map(\.id) }

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .addPassword: addPasswordPanel(context)
        case .removePassword: removePasswordPanel(context)
        case .blackOut: blackOutPanel(context)
        case .lockIn: lockInPanel(context)
        default: hiddenInfoPanel(context)
        }
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        switch tool {
        case .blackOut:
            guard let document = context.document else { return .none }
            if context.values.string("mode", default: "hand") == "find" { await search(context, in: document) }
            let marks = currentMarks(context)
            guard !marks.isEmpty else { return .none }
            let byPage = Dictionary(grouping: marks, by: \.page)
            return .overlay { page, cg in
                guard let index = page.document?.index(for: page), let marks = byPage[index] else { return }
                Self.drawMarks(marks, in: cg)
            }
        case .removeHiddenInfo:
            guard let document = context.document else { return .none }
            let source = document.snapshot()
            let fingerprint = source.fingerprint()
            if inventories[document.id]?.fingerprint != fingerprint, let inventory = try? await service.inventory(of: source) {
                inventories[document.id] = (fingerprint, inventory)
            }
            return .none
        default:
            return .none
        }
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        var values = context.values
        switch action {
        case Self.marksChangedAction:
            if let document = context.document, let store = handMarks[document.id] { values[Self.marksKey] = .strings(store.marks.map(Self.encode)) }
        case ProtectStrings.removePasswordOption.id:
            if let document = context.document { Services.tools?.openPanel(.removePassword, for: document, inputs: []) }
        default:
            break
        }
        return values
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let source = request.source else { return .none }
        let output = request.workFolder.appendingPathComponent("output.pdf")
        let name = request.destination?.lastPathComponent ?? output.lastPathComponent
        let values = request.values
        switch request.tool {
        case .addPassword:
            let password = values.string("password")
            if values.bool("envelope") {
                let file = try envelopeContent(request, source: source)
                try await service.makeEnvelope([file], password: password, destination: output)
            } else {
                try await service.addPassword(to: source, options: passwordOptions(values), destination: output)
            }
            return .newFile(output, banner: Strings.Banner.protected(name))

        case .removePassword:
            let typed = values.string("password")
            let password = typed.isEmpty ? request.document?.password ?? source.password : typed
            let unlocked: PDFSource = switch source {
            case .file(let url, _): .file(url, password: password)
            case .data(let data, _): .data(data, password: password)
            }
            try await service.removePassword(from: unlocked, destination: output)
            return .newFile(output, banner: Strings.Banner.saved(name, openIn: nil))

        case .blackOut:
            let marks = try await marksToApply(request)
            guard !marks.isEmpty else { throw ToolError(ProtectStrings.nothingMarked) }
            let report = try await service.apply(marks, to: source, options: redactionOptions(values), destination: output, progress: progress)
            guard report.verified else {
                try? FileManager.default.removeItem(at: output)
                throw ToolError(ProtectStrings.notVerified)
            }
            if let document = request.document { handMarks[document.id] = nil }
            return .newFile(output, banner: Strings.Banner.blackedOut(items: report.items, pages: report.pages, fileName: name))

        case .lockIn:
            let options = FlattenOptions(annotations: values.bool("notes", default: true), formFields: values.bool("fields", default: true),
                                         rasterizeDPI: values.bool("pictures") ? Self.pictureDPI : nil)
            try await service.flatten(source, options: options, to: output)
            return .newFile(output, banner: Strings.Banner.saved(name, openIn: nil))

        default:
            let kinds: Set<HiddenInfoKind> = values["kinds"] == nil
                ? Sanitizer.defaultKinds : Set(values.strings("kinds").compactMap(HiddenInfoKind.init(rawValue:)))
            try await service.remove(kinds, from: source, to: output)
            return .newFile(output, banner: Strings.Banner.saved(name, openIn: nil))
        }
    }

    // MARK: - Add a password

    private func addPasswordPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let password = v.string("password"), verify = v.string("verify")
        var controls: [ToolControl] = [
            .text(id: "password", label: ProtectStrings.password, placeholder: ProtectStrings.passwordPlaceholder, value: "", isSecure: true),
            .text(id: "verify", label: ProtectStrings.verify, placeholder: ProtectStrings.verifyPlaceholder, value: "", isSecure: true),
        ]
        if !password.isEmpty {
            let level = PasswordStrength.level(password)
            controls.append(.custom(id: "strength.\(level)", make: { StrengthBar(level: level) }))
        }
        controls.append(.note(ProtectStrings.forgetWarning))

        let needChange = v.bool("needChange")
        let envelope = v.bool("envelope")
        var more: [ToolControl] = [.toggle(id: "needChange", label: ProtectStrings.needChangePassword, isOn: false)]
        if needChange && !envelope {
            more.append(.text(id: "changePassword", label: ProtectStrings.changePassword, placeholder: ProtectStrings.changePasswordPlaceholder,
                              value: "", isSecure: true))
            more.append(.toggle(id: "allowPrinting", label: ProtectStrings.allowPrinting, isOn: true))
            if v.bool("allowPrinting", default: true) {
                more.append(.popup(id: "printQuality", label: ProtectStrings.printQuality,
                                   options: [ToolOption("high", ProtectStrings.highResolution), ToolOption("low", ProtectStrings.lowResolution)],
                                   selected: "high"))
            }
            more += [.toggle(id: "allowCopying", label: ProtectStrings.allowCopying, isOn: true),
                     .toggle(id: "allowForms", label: ProtectStrings.allowFormsAndComments, isOn: true),
                     .toggle(id: "allowPages", label: ProtectStrings.allowPageChanges, isOn: true)]
        }
        more += [.popup(id: "encryption", label: ProtectStrings.encryption,
                        options: [ToolOption("aes256", ProtectStrings.aes256), ToolOption("aes128", ProtectStrings.aes128)], selected: "aes256"),
                 .toggle(id: "keepMetadata", label: ProtectStrings.keepMetadata, isOn: false),
                 .toggle(id: "envelope", label: ProtectStrings.onlyAttachments, isOn: false)]

        let change = v.string("changePassword")
        var message: ToolMessage?
        if !verify.isEmpty, verify != password {
            message = ToolMessage(.warning, ProtectStrings.mismatch)
        } else if Passwords.needsASCIIWarning(password) || (needChange && Passwords.needsASCIIWarning(change)) {
            message = ToolMessage(.warning, ProtectStrings.nonASCIIWarning)
        }
        let ready = !password.isEmpty && verify == password && (!needChange || envelope || !change.isEmpty)
        return ToolPanel(.oneChoice, controls: controls, moreOptions: more, primary: ToolButton(ProtectStrings.saveProtected, isEnabled: ready),
                         output: .sibling(.protected, ext: "pdf"), message: message)
    }

    private func passwordOptions(_ v: ToolValues) -> PasswordOptions {
        let needChange = v.bool("needChange") && !v.string("changePassword").isEmpty
        var permissions = DocumentPermissions.all
        if needChange {
            permissions.printing = !v.bool("allowPrinting", default: true) ? .none
                : v.string("printQuality", default: "high") == "low" ? .lowResolution : .highResolution
            permissions.copyingText = v.bool("allowCopying", default: true)
            permissions.fillingFormsAndSigning = v.bool("allowForms", default: true)
            permissions.commenting = v.bool("allowForms", default: true)
            permissions.pageChanges = v.bool("allowPages", default: true)
        }
        return PasswordOptions(openPassword: v.string("password"), permissionsPassword: needChange ? v.string("changePassword") : nil,
                               permissions: permissions, encryption: v.string("encryption", default: "aes256") == "aes128" ? .aes128 : .aes256,
                               keepMetadataReadable: v.bool("keepMetadata"))
    }

    /// The file an envelope carries: the document as saved, or its current bytes under its name.
    private func envelopeContent(_ request: ToolRequest, source: PDFSource) throws -> URL {
        if case .file(let url, _) = source { return url }
        let name = (request.document?.displayName ?? "Document") + ".pdf"
        let url = request.workFolder.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try source.bytes().write(to: file)
        return file
    }

    // MARK: - Remove password

    private func removePasswordPanel(_ context: ToolContext) -> ToolPanel {
        let control = ToolControl.text(id: "password", label: ProtectStrings.password, placeholder: ProtectStrings.passwordPlaceholder,
                                       value: "", isSecure: true)
        let typed = context.values.string("password")
        guard let document = context.document else {
            return ToolPanel(.oneChoice, controls: [control], primary: ToolButton(ProtectStrings.saveWithoutPassword, isEnabled: false))
        }
        let restrictions = Self.restrictions(service.permissions(of: document))
        let message: String
        let ready: Bool
        if document.state.isEncrypted || document.state.isLocked {
            message = ProtectStrings.needsPasswordToOpen
            ready = !typed.isEmpty || document.password != nil
        } else if !restrictions.isEmpty {
            message = ProtectStrings.limits(restrictions)
            ready = !typed.isEmpty
        } else {
            message = ProtectStrings.noPassword
            ready = false
        }
        return ToolPanel(.oneChoice, controls: [.note(message), control],
                         primary: ToolButton(ProtectStrings.saveWithoutPassword, isEnabled: ready), output: .sibling(.noPassword, ext: "pdf"))
    }

    private static func restrictions(_ p: DocumentPermissions) -> [Strings.Restriction] {
        var result: [Strings.Restriction] = []
        if p.printing != .highResolution { result.append(.printing) }
        if !p.copyingText { result.append(.copying) }
        if !p.pageChanges { result.append(.pageChanges) }
        if !p.commenting { result.append(.commenting) }
        if !p.fillingFormsAndSigning { result.append(.formFilling) }
        return result
    }

    // MARK: - Black out

    static let marksKey = "marks"

    private func blackOutPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let findMode = v.string("mode", default: "hand") == "find"
        var controls: [ToolControl] = [
            .segmented(id: "mode", options: [ToolOption("hand", ProtectStrings.markByHand), ToolOption("find", ProtectStrings.findAndMark)],
                       selected: "hand"),
        ]
        if findMode {
            controls.append(.text(id: "query", label: nil, placeholder: ProtectStrings.findPlaceholder, value: "", isSecure: false))
            let chips = ProtectStrings.patternTitles.map { ToolOption($0.0?.rawValue ?? "custom", $0.1) }
            controls.append(.chips(id: "patterns", options: chips, selected: [], allowsMultiple: true))
            if v.strings("patterns").contains("custom") {
                controls.append(.text(id: "customPattern", label: ProtectStrings.customPattern, placeholder: ProtectStrings.customPatternPlaceholder,
                                      value: "", isSecure: false))
            }
            if let results = results(for: context) {
                controls.append(.note(ProtectStrings.found(results.count, pages: Set(results.map(\.page)).count)))
                if !results.isEmpty {
                    let items = results.map { ToolOption($0.id.uuidString, $0.text ?? "", value: ProtectStrings.page($0.page + 1)) }
                    controls.append(.checklist(id: resultsKey(context), items: items, selected: items.map(\.id)))
                }
            }
        } else if let document = context.document {
            let marks = Self.decode(v.strings(Self.marksKey))
            controls.append(.custom(id: "palette", make: { [weak self] in
                let store = HandMarks(document: document, marks: marks)
                self?.handMarks[document.id] = store
                return MarkingPalette(store: store)
            }))
        }
        controls += [.toggle(id: "hidden", label: ProtectStrings.alsoRemoveHidden, isOn: true),
                     .toggle(id: "words", label: ProtectStrings.writeRedacted, isOn: false)]
        let codes = (ProtectStrings.foiaCodes + ProtectStrings.privacyActCodes).map { ToolOption($0, $0) }
        let more: [ToolControl] = [
            .text(id: "overlayText", label: ProtectStrings.overlayWords, placeholder: ProtectStrings.defaultOverlay,
                  value: ProtectStrings.defaultOverlay, isSecure: false),
            .chips(id: "code", options: codes, selected: [], allowsMultiple: false),
            .popup(id: "colour", label: ProtectStrings.boxColour, options: ProtectStrings.colours.map { ToolOption($0.id, $0.title) },
                   selected: ProtectStrings.colours[0].id),
        ]
        let count = currentMarks(context).count
        return ToolPanel(.mode, controls: controls, moreOptions: more,
                         primary: ToolButton(ProtectStrings.blackOut(count), isEnabled: count > 0, isDestructive: true),
                         output: .sibling(.blackedOut, ext: "pdf"),
                         confirmation: ToolConfirmation(message: Strings.Errors.redactConfirm(items: count),
                                                        confirm: ToolButton(Strings.Errors.blackOutAction, isDestructive: true)))
    }

    /// What Find and mark looks for, as queries; empty when nothing is asked.
    private static func queries(_ v: ToolValues) -> [RedactionQuery] {
        var queries: [RedactionQuery] = []
        let text = v.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { queries.append(.text(text, wholeWords: false, matchCase: false)) }
        for id in v.strings("patterns") {
            if id == "custom" {
                let pattern = v.string("customPattern")
                if !pattern.isEmpty { queries.append(.regularExpression(pattern)) }
            } else if let pattern = RedactionPattern(rawValue: id) {
                queries.append(.pattern(pattern))
            }
        }
        return queries
    }

    private static func signature(_ v: ToolValues) -> String {
        let text = v.string("query").trimmingCharacters(in: .whitespacesAndNewlines)
        return [text, v.strings("patterns").sorted().joined(separator: ","), v.string("customPattern")].joined(separator: "|")
    }

    /// The checklist's value key: new results start ticked.
    private func resultsKey(_ context: ToolContext) -> String {
        // FNV-1a, so the key is the same in every launch (routines keep values).
        let hash = Self.signature(context.values).utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return "results." + String(hash, radix: 36)
    }

    /// The cached results of the current search, when it has run.
    private func results(for context: ToolContext) -> [RedactionMark]? {
        guard let document = context.document, let found, found.document == document.id, found.signature == Self.signature(context.values) else { return nil }
        return found.marks
    }

    private func search(_ context: ToolContext, in document: DocumentHandle) async {
        let signature = Self.signature(context.values)
        if let found, found.document == document.id, found.signature == signature { return }
        let queries = Self.queries(context.values)
        var marks: [RedactionMark] = []
        let pages = Array(0..<document.pageCount)
        for query in queries {
            guard let more = try? await service.find(query, in: document, pages: pages) else { continue }
            marks += more
        }
        guard !Task.isCancelled else { return }
        found = (document.id, signature, marks.sorted { ($0.page, -$0.rect.maxY, $0.rect.minX) < ($1.page, -$1.rect.maxY, $1.rect.minX) })
    }

    /// Hand marks plus the ticked results of the search.
    private func currentMarks(_ context: ToolContext) -> [RedactionMark] {
        var marks = Self.decode(context.values.strings(Self.marksKey))
        if context.values.string("mode", default: "hand") == "find", let results = results(for: context) {
            let key = resultsKey(context)
            let ticked = context.values[key] == nil ? nil : Set(context.values.strings(key))
            marks += results.filter { ticked?.contains($0.id.uuidString) ?? true }
        }
        return marks
    }

    /// The marks a run blacks out: the panel's, or (a routine without a panel) the search run again.
    private func marksToApply(_ request: ToolRequest) async throws -> [RedactionMark] {
        let context = ToolContext(tool: .blackOut, document: request.document, values: request.values)
        if let document = request.document, request.values.string("mode", default: "hand") == "find", results(for: context) == nil {
            await search(context, in: document)
        }
        return currentMarks(context)
    }

    private func redactionOptions(_ v: ToolValues) -> RedactionOptions {
        var words: String?
        if v.bool("words") {
            let code = v.strings("code").first
            let typed = v.string("overlayText", default: ProtectStrings.defaultOverlay).trimmingCharacters(in: .whitespaces)
            words = code ?? (typed.isEmpty ? ProtectStrings.defaultOverlay : typed)
        }
        return RedactionOptions(overlayText: words, fillColor: v.string("colour", default: ProtectStrings.colours[0].id),
                                removeHiddenInformation: v.bool("hidden", default: true))
    }

    static func encode(_ mark: RedactionMark) -> String {
        let r = mark.rect.standardized
        return String(format: "%d|%.2f|%.2f|%.2f|%.2f|", mark.page, r.minX, r.minY, r.width, r.height) + (mark.text ?? "")
    }

    static func decode(_ strings: [String]) -> [RedactionMark] {
        strings.compactMap { string in
            let parts = string.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5, let page = Int(parts[0]), let x = Double(parts[1]), let y = Double(parts[2]),
                  let w = Double(parts[3]), let h = Double(parts[4]) else { return nil }
            let text = parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil
            return RedactionMark(page: page, rect: CGRect(x: x, y: y, width: w, height: h), text: text)
        }
    }

    /// Marks before applying (ux §2.3): 1.5 pt red outline over a 10% red fill, with the Black out symbol so colour
    /// is not the only signal (ux §9).
    static func drawMarks(_ marks: [RedactionMark], in cg: CGContext) {
        let red = NSColor.systemRed.usingColorSpace(.sRGB) ?? .red
        for mark in marks {
            let rect = mark.rect.standardized
            cg.setFillColor(red.withAlphaComponent(0.1).cgColor)
            cg.fill(rect)
            cg.setStrokeColor(red.cgColor)
            cg.setLineWidth(1.5)
            cg.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
            guard rect.height >= 10, rect.width >= 24,
                  let symbol = NSImage(systemSymbolName: "text.redaction", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold)) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            let size = symbol.size
            let tinted = NSImage(size: size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                red.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: rect.maxX - size.width - 2, y: rect.maxY - size.height - 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Lock in notes & fields

    static let pictureDPI = 200.0

    private func lockInPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let any = v.bool("notes", default: true) || v.bool("fields", default: true) || v.bool("pictures")
        return ToolPanel(.oneChoice, controls: [
            .toggle(id: "notes", label: ProtectStrings.notesAndMarkup, isOn: true),
            .toggle(id: "fields", label: ProtectStrings.formEntries, isOn: true),
            .toggle(id: "pictures", label: ProtectStrings.makePictures, isOn: false),
        ], primary: ToolButton(ProtectStrings.saveLockedIn, isEnabled: any), output: .sibling(.lockedIn, ext: "pdf"))
    }

    // MARK: - Remove hidden info

    private func hiddenInfoPanel(_ context: ToolContext) -> ToolPanel {
        let primary = ProtectStrings.saveClean
        // The findings come from the preview (it runs when the panel opens); the panel itself stays cheap.
        guard let document = context.document, let inventory = inventories[document.id]?.inventory else {
            return ToolPanel(.oneChoice, controls: [.note(ProtectStrings.lookingForHidden)], primary: ToolButton(primary, isEnabled: false),
                             output: .sibling(.clean, ext: "pdf"))
        }
        let kinds = HiddenInfoKind.allCases.filter { (inventory.counts[$0] ?? 0) > 0 }
        guard !kinds.isEmpty else {
            return ToolPanel(.oneChoice, primary: ToolButton(primary, isEnabled: false), output: .sibling(.clean, ext: "pdf"),
                             message: ToolMessage(.info, ProtectStrings.nothingHidden))
        }
        let counted: Set<HiddenInfoKind> = [.comments, .formData, .attachments, .bookmarks, .links, .scripts]
        let items = kinds.map { kind in
            ToolOption(kind.rawValue, ProtectStrings.title(kind), value: counted.contains(kind) ? "\(inventory.counts[kind] ?? 0)" : nil)
        }
        let selected = kinds.filter(Sanitizer.defaultKinds.contains).map(\.rawValue)
        let ticked = context.values["kinds"] == nil ? selected.count : context.values.strings("kinds").count
        return ToolPanel(.oneChoice, controls: [.checklist(id: "kinds", items: items, selected: selected)],
                         primary: ToolButton(primary, isEnabled: ticked > 0), output: .sibling(.clean, ext: "pdf"))
    }
}

/// A rough guess at how hard a password is to guess, 0 (weak) to 3 (strong).
enum PasswordStrength {
    static func level(_ password: String) -> Int {
        var classes = 0
        if password.contains(where: \.isLowercase) { classes += 1 }
        if password.contains(where: \.isUppercase) { classes += 1 }
        if password.contains(where: \.isNumber) { classes += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        let length = password.count
        let score = (length >= 8 ? 1 : 0) + (length >= 12 ? 1 : 0) + (length >= 16 ? 1 : 0) + max(classes - 1, 0)
        return min(max(score - 1, 0), 3)
    }
}

/// The strength bar under the password fields (ux §5.3): four segments and the word.
@MainActor
final class StrengthBar: NSView {
    init(level: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 18))
        let indicator = NSLevelIndicator()
        indicator.levelIndicatorStyle = .discreteCapacity
        indicator.minValue = 0
        indicator.maxValue = 4
        indicator.doubleValue = Double(level + 1)
        indicator.warningValue = 2.5
        indicator.criticalValue = 1.5
        indicator.isEditable = false
        let word = NSTextField(labelWithString: ProtectStrings.strength[level])
        word.font = .systemFont(ofSize: 11)
        word.textColor = .secondaryLabelColor
        for view in [indicator, word] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor), indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 120),
            word.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8), word.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(ProtectStrings.strength[level])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
