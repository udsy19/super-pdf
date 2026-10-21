import AppKit
import Combine
import ConvertKit
@testable import FormsKit
import LayoutKit
import PDFKit
import PDFModelKit
import SuperPDFCore
@testable import ToolsKit

// FormsKit's checks (WP10): the AF* emulation against expected strings (number, percent, date, time, special,
// range, simple calculate, simplified field notation), filling with formats and calculations and its undo, entries
// typed on the page, AutoFill from an injected card (Contacts is never touched), form data out and back in (FDF, XFDF
// and JSON through ConvertKit, CSV here), values and scripts surviving a save and re-opening in PDFKit and QPDF,
// field finding on a generated flat form (recall), and the Make a form and Fill a form panels driven headlessly.
func registerFormsKitTests() {
    SelfTest.cases.append(("FormsKit.install", { formsInstall() }))
    SelfTest.cases.append(("FormsKit.afNumber", { formsAFNumber() }))
    SelfTest.cases.append(("FormsKit.afDate", { formsAFDate() }))
    SelfTest.cases.append(("FormsKit.afSpecial", { formsAFSpecial() }))
    SelfTest.cases.append(("FormsKit.afCalculate", { formsAFCalculate() }))
    SelfTest.cases.append(("FormsKit.fill", { formsFill() }))
    SelfTest.cases.append(("FormsKit.typedOnPage", { formsTypedOnPage() }))
    SelfTest.cases.append(("FormsKit.saveReopen", { formsSaveReopen() }))
    SelfTest.cases.append(("FormsKit.autoFill", { formsAutoFill() }))
    SelfTest.cases.append(("FormsKit.data", { formsData() }))
    SelfTest.cases.append(("FormsKit.detect", { formsDetect() }))
    SelfTest.cases.append(("FormsKit.makeForm", { formsMakeForm() }))
    SelfTest.cases.append(("FormsKit.fillPanel", { formsFillPanel() }))
}

// MARK: - Fixtures

private func formsFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("FormsKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

private let money = "AFNumber_Format(2, 0, 0, 0, \"$\", true);"

/// A two-page form made with PDFModelKit: text, date, money, quantity, calculated subtotal/tax/total, a tick box, a
/// choice, a percentage, a ranged number, a field in a group and one with a script we don't run.
private func formFixture(xfa: Bool = false) -> Data {
    let model = try! PDFModel(data: makePDF(pages: 2))
    func text(_ name: String, y: CGFloat, tooltip: String = "", scripts: [AFAction: String] = [:], page: Int = 0) -> FormField {
        FormField(id: name, kind: .text, page: page, bounds: CGRect(x: 200, y: y, width: 160, height: 20), tooltip: tooltip, scripts: scripts)
    }
    try! FormFile.add([
        text("name", y: 700, tooltip: "Full name"),
        text("email", y: 670, tooltip: "E-mail address"),
        text("birthday", y: 640, tooltip: "Date of birth", scripts: [.format: "AFDate_FormatEx(\"mm/dd/yyyy\");", .keystroke: "AFDate_KeystrokeEx(\"mm/dd/yyyy\");"]),
        text("price", y: 610, scripts: [.format: money, .keystroke: "AFNumber_Keystroke(2, 0, 0, 0, \"$\", true);"]),
        text("qty", y: 580, scripts: [.format: "AFNumber_Format(0, 0, 0, 0, \"\", true);"]),
        text("subtotal", y: 550, scripts: [.calculate: "/** BVCALC price * qty EVCALC **/ event.value = AFMakeNumber(getField(\"price\").value) * AFMakeNumber(getField(\"qty\").value);", .format: money]),
        text("tax", y: 520, scripts: [.calculate: "event.value = this.getField(\"subtotal\").value * 0.1;", .format: money]),
        text("total", y: 490, scripts: [.calculate: "AFSimple_Calculate(\"SUM\", new Array (\"subtotal\", \"tax\"));", .format: money]),
        FormField(id: "agree", kind: .checkbox, page: 0, bounds: CGRect(x: 200, y: 460, width: 14, height: 14), options: ["Yes"]),
        FormField(id: "colour", kind: .dropdown, page: 0, bounds: CGRect(x: 200, y: 430, width: 120, height: 20), options: ["Red", "Green", "Blue"]),
        text("share", y: 400, scripts: [.format: "AFPercent_Format(1, 0);"]),
        text("score", y: 370, scripts: [.validate: "AFRange_Validate(true, 0, true, 100);"]),
        text("notes", y: 700, scripts: [.format: "event.value = util.printx(\"(999)\", event.value);"], page: 1),
    ], to: model)
    // A field in a group: "address.city".
    let parent = model.makeIndirect(.dictionary(["T": .text("address"), "FT": .name("Tx")]))
    model.ensureAcroForm().array("Fields").append(parent)
    let city = model.page(at: 1)!.addAnnotation(model.make(.dictionary([
        "Type": .name("Annot"), "Subtype": .name("Widget"), "T": .text("city"), "Rect": .rect(CGRect(x: 200, y: 640, width: 160, height: 20)),
        "DA": .ascii("/Helv 0 Tf 0 g"), "TU": .text("City"),
    ])))
    city.set("Parent", parent)
    parent.set("Kids", .array([city.reference!]))
    if xfa { model.ensureAcroForm().set("XFA", .array([.text("template"), .text("<template/>")])) }
    return try! model.data()
}

@MainActor
private func formDocument(_ folder: URL, data: Data = formFixture(), name: String = "Form.pdf") -> DocumentHandle {
    let url = folder.appendingPathComponent(name)
    try? data.write(to: url)
    return DocumentHandle(url: url, pdf: PDFDocument(url: url)!, state: DocumentState(hasFormFields: true), undoManager: makeUndoManager())
}

/// DocumentKit as far as these checks need it: `.contents` results swap the PDF (and back on undo), `.actions` are
/// registered, names come from `FakeDocuments`.
@MainActor
private final class FormsTestDocuments: DocumentManaging {
    let names = FakeDocuments()
    var openDocuments: [DocumentHandle] { names.openDocuments }
    var frontmost: DocumentHandle? { names.frontmost }
    var events: AnyPublisher<DocumentEvent, Never> { names.events }
    var recentDocuments: [RecentDocument] { [] }
    var applied: [ToolID] = []

    func open(_ url: URL) async throws -> DocumentHandle { try await names.open(url) }
    func openUntitled(_ data: Data, name: String) throws -> DocumentHandle { try names.openUntitled(data, name: name) }
    func destination(for policy: OutputPolicy, of document: DocumentHandle?, source: URL?) -> URL? {
        names.destination(for: policy, of: document, source: source)
    }
    func removeRecent(_ url: URL) {}
    func viewState(for url: URL) -> DocumentViewState? { nil }
    func saveViewState(_ state: DocumentViewState, for url: URL) {}

    func apply(_ result: ToolResult, of request: ToolRequest) async throws {
        applied.append(request.tool)
        guard case .inPlace(let group, _) = result, let document = request.document else { return }
        document.state.isEdited = true   // as NSDocument's change count does
        let manager = document.undoManager
        manager?.beginUndoGrouping()
        switch group.change {
        case .actions: manager?.register(group)
        case .contents(let before, let after):
            document.pdf = PDFDocument(data: after)!
            swap(document, back: before, forth: after)
        }
        manager?.endUndoGrouping()
    }

    private func swap(_ document: DocumentHandle, back: Data, forth: Data) {
        document.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                document.pdf = PDFDocument(data: back)!
                target.swap(document, back: forth, forth: back)
            }
        }
    }
}

/// A card that never asks Contacts.
private struct FakeCard: ContactCardReading {
    var profile: AutoFillProfile?
    var denied = false
    func meCard() async throws -> AutoFillProfile? {
        if denied { throw ContactCardError.denied }
        return profile
    }
}

/// Fakes everywhere, the test DocumentKit, real LayoutKit, and a fresh FormsKit provider with an injected card.
@MainActor
private func installForms(card: FakeCard = FakeCard()) -> (tools: FormsTools, service: FormService, documents: FormsTestDocuments) {
    installFakes()
    let documents = FormsTestDocuments()
    Services.documents = documents
    LayoutKitModule.install()
    let service = FormService()
    Services.forms = service
    let tools = FormsTools(service: service, contactCard: card)
    for tool in tools.tools { Defaults.reset(ToolSession.valuesKey(tool)) }
    return (tools, service, documents)
}

private let emulator = AFEmulator()

private func af(_ script: String, _ action: AFAction, _ value: String, _ fields: [String: String] = [:]) -> AFOutcome {
    emulator.run(script, action: action, value: value, fields: fields)
}

/// The words of a PDF's form values as PDFKit reads them, by field name.
@MainActor
private func pdfKitValues(_ data: Data) -> [String: String] {
    guard let pdf = PDFDocument(data: data) else { return [:] }
    var values: [String: String] = [:]
    for index in 0..<pdf.pageCount {
        for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
            guard let name = annotation.fieldName else { continue }
            values[name] = annotation.widgetFieldType == .button ? (annotation.buttonWidgetState == .onState ? annotation.buttonWidgetStateString : "Off")
                : annotation.widgetStringValue ?? ""
        }
    }
    return values
}

// MARK: - Install

@MainActor
private func formsInstall() {
    installFakes()
    FormsKitModule.install()
    check(Services.forms is FormService, "Services.forms is FormsKit's service")
    let tools = Services.toolProviders.compactMap { $0 as? FormsTools }.first
    check(Set(tools?.tools ?? []) == [.fillForm, .makeForm], "the two Sign & fill form tiles")
    check(ToolCoverage.issues(Services.toolProviders, requireAll: false).isEmpty, "FormsKit covers its tiles exactly once")
    let folder = formsFolder("install")
    let document = formDocument(folder)
    for tool in tools?.tools ?? [] {
        let panel = tools!.panel(for: tool, context: ToolContext(tool: tool, document: document))
        check(panel.archetype == .mode, "\(tool.rawValue): mode panel")
        check(panel.primary.title == Strings.Panel.done, "\(tool.rawValue): Done")
    }
    installFakes()
}

// MARK: - AF emulation

@MainActor
private func formsAFNumber() {
    let cases: [(String, String, String)] = [
        (money, "1234.5", "$1,234.50"),
        (money, "$1,234.50", "$1,234.50"),
        (money, "-12", "-$12.00"),
        ("AFNumber_Format(2, 0, 2, 0, \"$\", true);", "-12", "($12.00)"),
        ("AFNumber_Format(2, 2, 0, 0, \" €\", false);", "1234.5", "1.234,50 €"),
        ("AFNumber_Format(2, 2, 0, 0, \" €\", false);", "1.234,50 €", "1.234,50 €"),
        ("AFNumber_Format(0, 1, 0, 0, \"\", true);", "1234.5", "1235"),
        ("AFNumber_Format(3, 4, 0, 0, \"\", true);", "1234567.8915", "1'234'567.892"),
        (money, "-0.001", "$0.00"),
        (money, "", ""),
        (money, "abc", "abc"),
        ("AFPercent_Format(2, 0);", "0.5", "50.00%"),
        ("AFPercent_Format(2, 0);", "50.00%", "50.00%"),
        ("AFPercent_Format(1, 0, true);", "0.125", "%12.5"),
    ]
    for (script, value, expected) in cases {
        check(af(script, .format, value) == .value(expected), "\(script) \(value) → \(expected), got \(af(script, .format, value))")
    }
    check(af("AFNumber_Keystroke(2, 0, 0, 0, \"\", true);", .keystroke, "12a") == .rejected(FormsStrings.Invalid.number), "letters are not a number")
    check(af("AFNumber_Keystroke(2, 0, 0, 0, \"\", true);", .keystroke, "1,234.5") == .value("1,234.5"), "a typed number passes")
    check(AFEmulator.rawValue(of: "$1,234.50", format: money) == "1234.5", "money reads back as a number")
    check(AFEmulator.rawValue(of: "12.5%", format: "AFPercent_Format(1, 0);") == "0.125", "a percentage reads back as a fraction")
    check(AFEmulator.rawValue(of: "1.234,50 €", format: "AFNumber_Format(2, 2, 0, 0, \" €\", false);") == "1234.5", "comma decimals read back")
    check(af("AFRange_Validate(true, 0, true, 100);", .validate, "150") == .rejected(FormsStrings.Invalid.range(low: "0", high: "100")), "over the range")
    check(af("AFRange_Validate(true, 0, true, 100);", .validate, "50") == .value("50"), "inside the range")
    check(af("AFRange_Validate(true, 10, false, 0);", .validate, "5") == .rejected(FormsStrings.Invalid.range(low: "10", high: nil)), "below a lower bound")
}

@MainActor
private func formsAFDate() {
    let cases: [(String, String, String)] = [
        ("AFDate_FormatEx(\"mm/dd/yyyy\");", "3/5/2026", "03/05/2026"),
        ("AFDate_FormatEx(\"mm/dd/yyyy\");", "2026-03-05", "03/05/2026"),
        ("AFDate_FormatEx(\"mm/dd/yyyy\");", "March 5, 2026", "03/05/2026"),
        ("AFDate_FormatEx(\"dd/mm/yyyy\");", "5/3/26", "05/03/2026"),
        ("AFDate_FormatEx(\"mmmm d, yyyy\");", "03/05/2026", "March 5, 2026"),
        ("AFDate_FormatEx(\"dddd, mmm d, yyyy\");", "2026-10-21", "Wednesday, Oct 21, 2026"),
        ("AFDate_FormatEx(\"yyyy-mm-dd\");", "12/31/99", "1999-12-31"),
        ("AFDate_Format(2);", "1/2/2026", "01/02/26"),
        ("AFDate_FormatEx(\"mm/dd/yyyy\");", "not a date", "not a date"),
        ("AFTime_Format(1);", "14:05", "2:05 pm"),
        ("AFTime_Format(0);", "2:05 pm", "14:05"),
        ("AFTime_FormatEx(\"HH:MM:ss\");", "9:7:3", "09:07:03"),
    ]
    for (script, value, expected) in cases {
        check(af(script, .format, value) == .value(expected), "\(script) \(value) → \(expected), got \(af(script, .format, value))")
    }
    check(af("AFDate_FormatEx(\"mm/dd/yyyy\");", .format, af("AFDate_FormatEx(\"mm/dd/yyyy\");", .format, "2026-02-01").shown) == .value("02/01/2026"),
          "formatting twice changes nothing")
    if case .rejected(let message) = af("AFDate_KeystrokeEx(\"mm/dd/yyyy\");", .keystroke, "2/30/2026") {
        check(message.hasPrefix("Enter it like “") && message.contains("/"), "an impossible date is refused with an example: \(message)")
    } else { check(false, "February 30 is refused") }
    check(af("AFDate_KeystrokeEx(\"mm/dd/yyyy\");", .keystroke, "") == .value(""), "an empty date passes")
    check(af("AFTime_Keystroke(0);", .keystroke, "25:00") != .value("25:00"), "hour 25 is refused")
}

@MainActor
private func formsAFSpecial() {
    let cases: [(String, String, String)] = [
        ("AFSpecial_Format(0);", "12345", "12345"),
        ("AFSpecial_Format(1);", "123456789", "12345-6789"),
        ("AFSpecial_Format(2);", "5551234567", "(555) 123-4567"),
        ("AFSpecial_Format(2);", "555 1234", "555-1234"),
        ("AFSpecial_Format(2);", "(555) 123-4567", "(555) 123-4567"),
        ("AFSpecial_Format(3);", "123 45 6789", "123-45-6789"),
        ("AFSpecial_KeystrokeEx(\"AA-9999\");", "ab1234", "ab-1234"),
    ]
    for (script, value, expected) in cases {
        check(af(script, .format, value) == .value(expected), "\(script) \(value) → \(expected), got \(af(script, .format, value))")
    }
    check(af("AFSpecial_Keystroke(0);", .keystroke, "1234") == .rejected(FormsStrings.Invalid.mask("99999")), "a short ZIP code is refused")
    check(FormsStrings.Invalid.mask("(999) 999-9999") == "Enter it like “(123) 456-7890”.", "the phone example")
    check(af("AFSpecial_Keystroke(3);", .keystroke, "123-45-6789") == .value("123-45-6789"), "a social security number passes")
}

@MainActor
private func formsAFCalculate() {
    let fields = ["a": "2", "b": "3.5", "c": "", "price.0": "10", "price.1": "5", "unit price": "4"]
    let cases: [(String, String)] = [
        ("AFSimple_Calculate(\"SUM\", new Array (\"a\", \"b\", \"c\"));", "5.5"),
        ("AFSimple_Calculate(\"PRD\", new Array (\"a\", \"b\"));", "7"),
        ("AFSimple_Calculate(\"AVG\", new Array (\"a\", \"b\"));", "2.75"),
        ("AFSimple_Calculate(\"MIN\", \"a, b\");", "2"),
        ("AFSimple_Calculate(\"MAX\", [\"a\", \"b\"]);", "3.5"),
        ("AFSimple_Calculate(\"SUM\", new Array (\"price\"));", "15"),
        ("/** BVCALC (a + b) * 2 - c EVCALC **/", "11"),
        ("/** BVCALC unit\\ price * a / -b EVCALC **/", String(AFEmulator.plain(4 * 2 / -3.5))),
        ("event.value = AFMakeNumber(getField(\"a\").value) + this.getField(\"b\").value * 2;", "9"),
    ]
    for (script, expected) in cases {
        check(af(script, .calculate, "", fields) == .value(expected), "\(script) → \(expected), got \(af(script, .calculate, "", fields))")
    }
    check(af("AFSimple_Calculate(\"SUM\", new Array (\"a\"));", .calculate, "", ["a": "0.1", "b": "0.2"]) == .value("0.1"), "one field")
    check(af("AFSimple_Calculate(\"SUM\", \"a, b\");", .calculate, "", ["a": "0.1", "b": "0.2"]) == .value("0.3"), "no float noise")
    check(af("event.value = util.printd(\"mm\", new Date());", .calculate, "") == .unsupported, "other JavaScript is not run")
    check(af("app.alert(\"hi\");", .format, "x") == .unsupported, "an alert is not run")
    check(af(money, .calculate, "") == .unsupported, "a format script is not a calculation")
}

private extension AFOutcome {
    var shown: String { if case .value(let v) = self { v } else { "" } }
}

// MARK: - Filling

@MainActor
private func formsFill() {
    let (_, service, _) = installForms()
    let document = formDocument(formsFolder("fill"))
    let fields = service.fields(in: document)
    check(fields.count == 14, "fourteen fields: \(fields.map(\.id))")
    let byName = Dictionary(fields.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    check(byName["address.city"]?.tooltip == "City" && byName["address.city"]?.page == 1, "a grouped field by its full name")
    check(byName["price"]?.kind == .number && byName["birthday"]?.kind == .date && byName["agree"]?.kind == .checkbox
          && byName["colour"]?.kind == .dropdown && byName["colour"]?.options == ["Red", "Green", "Blue"], "kinds and choices")
    check(byName["total"]?.scripts[.calculate]?.contains("AFSimple_Calculate") == true, "scripts read from the file")
    check(service.hasUnsupportedScripts(document), "the printx script is one we don't run")
    check(!service.isXFA(document), "not XFA")

    _ = service.setValue("2", forField: "qty", in: document)
    let fill = service.setValue("1234.5", forField: "price", in: document)
    var values = service.values(of: document)
    check(values["price"] == "$1,234.50", "money formatted: \(values["price"] ?? "")")
    check(values["subtotal"] == "$2,469.00" && values["tax"] == "$246.90" && values["total"] == "$2,715.90",
          "calculations in order: \(values["subtotal"] ?? "") \(values["tax"] ?? "") \(values["total"] ?? "")")
    _ = service.setValue("Yes", forField: "agree", in: document)
    _ = service.setValue("Green", forField: "colour", in: document)
    _ = service.setValue("0.25", forField: "share", in: document)
    values = service.values(of: document)
    check(values["agree"] == "Yes" && values["colour"] == "Green" && values["share"] == "25.0%", "tick, choice, percentage")

    fill.undo()
    values = service.values(of: document)
    check(values["price"] == "" && values["qty"] == "2" && values["total"] == "$0.00", "undo puts the price and its totals back: \(values["total"] ?? "")")
    check(values["subtotal"] == "$0.00", "the subtotal as it was")
    fill.redo()
    check(service.values(of: document)["total"] == "$2,715.90", "redo")

    let cleared = service.clear(document)
    values = service.values(of: document)
    check(values["price"] == "" && values["agree"] == "Off" && values["colour"] == "", "Clear form empties every field")
    cleared.undo()
    check(service.values(of: document)["agree"] == "Yes", "Clear form undone")
}

@MainActor
private func formsTypedOnPage() {
    let (_, service, _) = installForms()
    let document = formDocument(formsFolder("typed"))
    service.remember(document)
    func widget(_ name: String) -> PDFAnnotation? {
        (0..<document.pdf.pageCount).flatMap { document.pdf.page(at: $0)?.annotations ?? [] }.first { $0.fieldName == name }
    }
    // As PDFKit leaves them when the person types and tabs on.
    widget("price")?.widgetStringValue = "19.99"
    widget("qty")?.widgetStringValue = "3"
    let (undo, refused) = service.reconcile(document)
    var values = service.values(of: document)
    check(refused == nil && undo != nil, "typing is one undo step")
    check(values["price"] == "$19.99" && values["qty"] == "3" && values["total"] == "$65.97", "formatted and calculated: \(values["total"] ?? "")")
    undo?.undo()
    values = service.values(of: document)
    check(values["price"] == "" && values["qty"] == "" && values["total"] == "", "undo takes back the typing and the totals: \(values["total"] ?? "")")
    undo?.redo()

    widget("birthday")?.widgetStringValue = "2/30/2026"
    let (_, dateRefused) = service.reconcile(document)
    check(dateRefused?.hasPrefix("Enter it like") == true && service.values(of: document)["birthday"] == "", "an impossible date goes back")
    check(service.rejections[document.id] != nil, "the panel can say why")
    widget("birthday")?.widgetStringValue = "1990-05-17"
    _ = service.reconcile(document)
    check(service.values(of: document)["birthday"] == "05/17/1990" && service.rejections[document.id] == nil, "a good date is formatted")
    widget("score")?.widgetStringValue = "150"
    check(service.reconcile(document).rejected == FormsStrings.Invalid.range(low: "0", high: "100"), "out of range is refused")
    check(service.reconcile(document).undo == nil, "nothing new, nothing to undo")
}

@MainActor
private func formsSaveReopen() {
    let (_, service, _) = installForms()
    let folder = formsFolder("save")
    let document = formDocument(folder)
    _ = service.setValue("Ada Lovelace", forField: "name", in: document)
    _ = service.setValue("Zürich", forField: "address.city", in: document)
    _ = service.setValue("12", forField: "price", in: document)
    _ = service.setValue("2", forField: "qty", in: document)
    _ = service.setValue("Yes", forField: "agree", in: document)
    _ = service.setValue("Blue", forField: "colour", in: document)
    // DocumentKit's save: PDFKit writes, then FormsKit puts back what PDFKit dropped.
    guard let written = document.pdf.dataRepresentation() else { check(false, "PDFKit writes"); return }
    let pdfKitAlone = (try? FormFile.facts(of: written, password: nil)) ?? FormFacts()
    check(pdfKitAlone.scripts.isEmpty, "PDFKit alone drops the scripts (why the restorer exists)")
    guard let restore = service.formRestorer(for: document), let saved = try? restore(written) else { check(false, "restorer runs"); return }
    let url = folder.appendingPathComponent("Saved.pdf")
    try? saved.write(to: url)

    let kit = pdfKitValues(saved)
    check(kit["name"] == "Ada Lovelace" && kit["address.city"] == "Zürich" && kit["total"] == "$26.40" && kit["agree"] == "Yes" && kit["colour"] == "Blue",
          "PDFKit reads the values back: \(kit)")
    guard let model = try? PDFModel(url: url) else { check(false, "QPDF opens the save"); return }
    let fields = Dictionary(model.formFields().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    check(fields["name"]?.value?.textValue == "Ada Lovelace" && fields["address.city"]?.value?.textValue == "Zürich", "QPDF reads the text")
    check(fields["agree"]?.value?.nameValue == "Yes" && fields["colour"]?.value?.textValue == "Blue", "QPDF reads the tick and the choice")
    let facts = (try? FormFile.facts(of: saved, password: nil)) ?? FormFacts()
    check(facts.scripts["price"]?[.format] == money && facts.scripts["total"]?[.calculate]?.contains("SUM") == true, "scripts are back")
    check(facts.calculationOrder == ["subtotal", "tax", "total"], "the calculation order is back: \(facts.calculationOrder)")
    check(model.acroForm?["DR"]?["Font"]?["Helv"] != nil && model.acroForm?["DA"] != nil, "the form's appearance defaults are back")

    // Re-opened, the form calculates as before.
    let reopened = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    _ = service.setValue("3", forField: "qty", in: reopened)
    check(service.values(of: reopened)["total"] == "$39.60", "the re-opened form still calculates")
    check(service.formRestorer(for: DocumentHandle(url: nil, displayName: "Plain", pdf: PDFDocument(data: makePDF(pages: 1))!)) == nil,
          "nothing to restore on a plain PDF")
}

@MainActor
private func formsAutoFill() {
    let card = FakeCard(profile: AutoFillProfile(values: ["name": "Ada Lovelace", "email": "ada@example.com", "city": "London",
                                                          "birthday": "1815-12-10", "phone": "555 0100"]))
    let (tools, service, _) = installForms(card: card)
    let document = formDocument(formsFolder("autofill"))
    check(AutoFillKey.key(for: FormField(id: "txtFirstName", kind: .text, page: 0, bounds: .zero)) == AutoFillKey.firstName, "camel case")
    check(AutoFillKey.key(for: FormField(id: "f12", kind: .text, page: 0, bounds: .zero, tooltip: "ZIP / Postal code")) == AutoFillKey.postcode, "tooltip")
    check(AutoFillKey.key(for: FormField(id: "Email address", kind: .text, page: 0, bounds: .zero)) == AutoFillKey.email, "an e-mail address isn't a street")
    check(AutoFillKey.key(for: FormField(id: "colour", kind: .text, page: 0, bounds: .zero)) == nil, "unrelated fields stay alone")
    _ = service.setValue("Someone else", forField: "name", in: document)
    let session = ToolSession(tool: .fillForm, provider: tools, document: document)
    _ = complete { await session.perform(FormsTools.Action.autoFill) }
    let values = service.values(of: document)
    check(values["name"] == "Someone else", "AutoFill leaves filled fields alone")
    check(values["email"] == "ada@example.com" && values["address.city"] == "London" && values["birthday"] == "12/10/1815",
          "card values land, dates in the field's format: \(values)")
    check(session.message?.text == FormsStrings.autoFilled(3), "the panel says how many: \(session.message?.text ?? "")")

    let (deniedTools, _, _) = installForms(card: FakeCard(denied: true))
    let denied = ToolSession(tool: .fillForm, provider: deniedTools, document: formDocument(formsFolder("denied")))
    _ = complete { await denied.perform(FormsTools.Action.autoFill) }
    check(denied.message?.text == FormsStrings.contactsDenied, "no access says where to allow it")
    let (noCardTools, _, _) = installForms(card: FakeCard())
    let noCard = ToolSession(tool: .fillForm, provider: noCardTools, document: formDocument(formsFolder("nocard")))
    _ = complete { await noCard.perform(FormsTools.Action.autoFill) }
    check(noCard.message?.text == FormsStrings.noMeCard, "no Me card")
    installFakes()
}

@MainActor
private func formsData() {
    let (_, service, _) = installForms()
    ConvertKitModule.install()   // FDF, XFDF and JSON are ConvertKit's exports
    let folder = formsFolder("data")
    let document = formDocument(folder)
    _ = service.setValue("Ada, \"the first\"", forField: "name", in: document)
    _ = service.setValue("Zürich", forField: "address.city", in: document)
    _ = service.setValue("Yes", forField: "agree", in: document)
    _ = service.setValue("7", forField: "price", in: document)
    let before = service.values(of: document)
    for format in FormDataFormat.allCases {
        let file = folder.appendingPathComponent("answers.\(format.rawValue)")
        guard case .success? = (complete { try await service.exportData(from: document, as: format, to: file) }) else {
            check(false, "\(format.rawValue): export"); continue
        }
        let other = formDocument(folder, name: "Blank \(format.rawValue).pdf")
        guard let group = try? service.importData(from: file, into: other) else { check(false, "\(format.rawValue): import"); continue }
        let back = service.values(of: other)
        for name in ["name", "address.city", "agree", "price", "total"] {
            check(back[name] == before[name], "\(format.rawValue): \(name) round-trips (\(back[name] ?? "nil") vs \(before[name] ?? "nil"))")
        }
        group.undo()
        check(service.values(of: other)["name"] == "", "\(format.rawValue): import undone")
    }
    let junk = folder.appendingPathComponent("junk.json")
    try? Data("{\"nothing\": \"here\"}".utf8).write(to: junk)
    check((try? service.importData(from: junk, into: document)) == nil, "a file with no matching fields is refused")
    installFakes()
}

// MARK: - Making a form

/// A printed form with no fields: underscores, lines, drawn boxes, squares, a ☐ glyph, a box of four lines, and an
/// underlined phrase that is not a blank.
private func flatForm() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let c = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    c.beginPDFPage(nil)
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont(name: "Helvetica", size: size)!]))
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, c)
    }
    func stroke(_ path: (CGContext) -> Void) { c.setLineWidth(1); c.setStrokeColor(.black); path(c); c.strokePath() }
    text("Application form", 72, 740, size: 18)
    text("Name: ______________________", 72, 700)
    text("Address", 72, 670); stroke { $0.move(to: CGPoint(x: 140, y: 668)); $0.addLine(to: CGPoint(x: 450, y: 668)) }
    text("Date of birth", 72, 640); stroke { $0.move(to: CGPoint(x: 160, y: 638)); $0.addLine(to: CGPoint(x: 300, y: 638)) }
    stroke { $0.addRect(CGRect(x: 72, y: 608, width: 10, height: 10)) }; text("Yes", 88, 609)
    stroke { $0.addRect(CGRect(x: 140, y: 608, width: 10, height: 10)) }; text("No", 156, 609)
    text("☐ I agree to the terms", 72, 580)
    text("Comments", 72, 556)
    stroke { $0.addRect(CGRect(x: 72, y: 460, width: 360, height: 88)) }
    text("Email", 72, 426)
    for (a, b) in [((120, 440), (400, 440)), ((120, 420), (400, 420)), ((120, 420), (120, 440)), ((400, 420), (400, 440))] {
        stroke { $0.move(to: CGPoint(x: a.0, y: a.1)); $0.addLine(to: CGPoint(x: b.0, y: b.1)) }
    }
    text("Terms apply", 72, 390); stroke { $0.move(to: CGPoint(x: 72, y: 388)); $0.addLine(to: CGPoint(x: 140, y: 388)) }
    text("Signature", 72, 340); stroke { $0.move(to: CGPoint(x: 140, y: 338)); $0.addLine(to: CGPoint(x: 360, y: 338)) }
    c.endPDFPage()
    c.closePDF()
    return data as Data
}

@MainActor
private func formsDetect() {
    let (_, service, _) = installForms()
    let document = formDocument(formsFolder("detect"), data: flatForm(), name: "Flat.pdf")
    guard case .success(let found)? = (complete { try await service.detectFields(in: document, pages: []) }) else {
        check(false, "detection runs"); return
    }
    let expected: [(String, FormFieldKind)] = [("Name", .text), ("Address", .text), ("Date of birth", .date), ("Yes", .checkbox), ("No", .checkbox),
                                               ("I agree to the terms", .checkbox), ("Comments", .multilineText), ("Email", .text), ("Signature", .signature)]
    var recalled = 0
    for (label, kind) in expected {
        if found.contains(where: { $0.id == label && $0.kind == kind }) { recalled += 1 } else {
            check(false, "missed \(label) (\(kind.rawValue)); found \(found.map { "\($0.id):\($0.kind.rawValue)" })")
        }
    }
    check(recalled == expected.count, "recall \(recalled)/\(expected.count)")
    check(!found.contains { $0.id.contains("Terms apply") || ($0.bounds.minY < 395 && $0.bounds.minY > 380) }, "underlined text is not a blank")
    check(found.count <= expected.count + 1, "few false finds: \(found.map(\.id))")
    if let name = found.first(where: { $0.id == "Name" }) {
        check(name.bounds.minX > 100 && name.bounds.width > 100, "the underscores, not the label, become the field: \(name.bounds)")
    }
    check(found.first { $0.id == "Date of birth" }?.scripts[.format]?.contains("AFDate_FormatEx") == true, "a date field gets a date format")
    // The labels are what the detector reads; a filled field is not found again.
    guard let group = try? service.add(found, to: document) else { check(false, "add the found fields"); return }
    guard case .contents(_, let after) = group.change else { check(false, "a bytes change"); return }
    document.pdf = PDFDocument(data: after)!
    guard case .success(let again)? = (complete { try await service.detectFields(in: document, pages: []) }) else { return }
    check(again.isEmpty, "fields already there are not found again: \(again.map(\.id))")
}

@MainActor
private func formsMakeForm() {
    let (tools, service, documents) = installForms()
    let folder = formsFolder("make")
    let document = formDocument(folder, data: flatForm(), name: "Flat.pdf")
    let session = ToolSession(tool: .makeForm, provider: tools, document: document)
    _ = complete { await session.updatePreview() }
    if case .action(_, let title, _, _) = session.panel.controls.first {
        check(title == FormsStrings.findFields(found: 9), "the button counts what it would add: \(title)")
    }
    _ = complete { await session.perform(FormsTools.Action.detect) }
    check(session.message?.text == FormsStrings.addedFields(9), "Find fields for me adds them: \(session.message?.text ?? "")")
    guard let model = try? PDFModel(data: document.pdf.dataRepresentation()!) else { check(false, "QPDF opens the made form"); return }
    check(model.formFields().count == 9, "real AcroForm fields: \(model.formFields().map(\.name)) \(service.fields(in: document).map(\.id))")
    check(model.formFields().first { $0.name == "Yes" }?.widgets.first?.onStates == ["Yes"], "tick boxes have an on appearance")

    // Place a number field with the palette and a click, then name it, make it required and total two fields.
    session.set(FormsTools.Key.kind, .strings([FormFieldKind.number.rawValue]))
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: 480, y: 200))) }
    let placed = session.values.string(FormsTools.Key.selected)
    check(placed == "Number 1" && service.fields(in: document).contains { $0.id == placed && $0.kind == .number }, "placed and selected: \(placed)")
    session.set(FormsTools.Key.name + placed, .string("Total"))
    session.set(FormsTools.Key.required + placed, .bool(true))
    session.set(FormsTools.Key.calculate + placed, .string(FieldCalculation.sum.rawValue))
    session.set(FormsTools.Key.calculateFrom + placed, .strings(["Name", "Email"]))
    check(session.panel.controls.contains { if case .chips(let id, _, _, _) = $0 { id == FormsTools.Key.calculateFrom + placed } else { false } } ||
          session.panel.moreOptions.contains { if case .chips(let id, _, _, _) = $0 { id == FormsTools.Key.calculateFrom + placed } else { false } },
          "Calculate shows the fields to choose")
    // A click on another field picks it, applying the edits first.
    guard let yes = service.fields(in: document).first(where: { $0.id == "Yes" }) else {
        check(false, "no Yes: \(service.fields(in: document).map(\.id))"); return
    }
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: yes.bounds.midX, y: yes.bounds.midY))) }
    check(session.values.string(FormsTools.Key.selected) == "Yes", "a click picks a field: \(session.values.string(FormsTools.Key.selected)) \(session.message?.details ?? session.message?.text ?? "")")
    let total = service.fields(in: document).first { $0.id == "Total" }
    check(total?.isRequired == true && total?.scripts[.calculate] == "AFSimple_Calculate(\"SUM\", new Array (\"Name\", \"Email\"));",
          "renamed, required, calculated: \(String(describing: total)) \(service.fields(in: document).map { "\($0.id) \($0.isRequired)" }) \(session.values.storage.keys.sorted())")
    check(service.facts(for: document).calculationOrder == ["Total"], "the calculation order knows it")

    // Tab order: clicks number the fields.
    session.set(FormsTools.Key.tabOrder, .bool(true))
    let signature = service.fields(in: document).first { $0.id == "Signature" }!
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: signature.bounds.midX, y: signature.bounds.midY))) }
    check(service.fields(in: document).first?.id == "Signature", "the first field clicked is first in the tab order")

    // Remove the selected field; undo brings it back.
    session.set(FormsTools.Key.tabOrder, .bool(false))
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: yes.bounds.midX, y: yes.bounds.midY))) }
    _ = complete { await session.perform(FormsTools.Action.remove) }
    check(!service.fields(in: document).contains { $0.id == "Yes" }, "Remove this field")
    document.undoManager?.undo()
    check(service.fields(in: document).contains { $0.id == "Yes" }, "undo brings it back")

    // Done applies pending edits.
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: yes.bounds.midX, y: yes.bounds.midY))) }
    session.set(FormsTools.Key.name + "Yes", .string("Agrees"))
    _ = complete { await session.run() }
    check(service.fields(in: document).contains { $0.id == "Agrees" }, "Done applies the last edits")
    check(documents.applied.allSatisfy { $0 == .makeForm }, "every change goes through DocumentKit")

    // The protocol path other modules use (SignKit's request fields).
    let before = service.fields(in: document).count
    if let group = try? service.add([FormField(id: "Signer 1", kind: .signature, page: 0, bounds: CGRect(x: 300, y: 100, width: 180, height: 36))], to: document),
       case .contents(_, let after) = group.change {
        check((try? PDFModel(data: after))?.formFields().contains { $0.name == "Signer 1" && $0.type == "Sig" } == true, "a signature field")
        document.pdf = PDFDocument(data: after)!
        check(service.fields(in: document).count == before + 1, "PDFKit sees it")
    } else { check(false, "add through FormBuilding") }
    installFakes()
}

@MainActor
private func formsFillPanel() {
    let (tools, service, _) = installForms()
    let flat = formDocument(formsFolder("fillpanel"), data: flatForm(), name: "Flat.pdf")
    let session = ToolSession(tool: .fillForm, provider: tools, document: flat)
    check(session.message?.text == FormsStrings.noFieldsOnPage && session.message?.action?.id == FormsTools.Action.fillAnywhere,
          "a page without fields offers Fill anywhere")
    _ = complete { await session.perform(FormsTools.Action.fillAnywhere) }
    check(service.fields(in: flat).count == 9, "Fill anywhere turns the blanks into fields: \(service.fields(in: flat).count)")
    check(session.panel.controls.contains { if case .chips(let id, _, _, _) = $0 { id == FormsTools.Key.place } else { false } }, "text or tick to place")
    // A click off the fields places a text box there.
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: 480, y: 120))) }
    check(service.fields(in: flat).contains { $0.kind == .text && $0.bounds.contains(CGPoint(x: 490, y: 120)) }, "a text box where clicked")
    session.set(FormsTools.Key.place, .strings(["tick"]))
    _ = complete { await session.perform(FormsTools.Action.click(page: 0, at: CGPoint(x: 480, y: 80))) }
    check(service.fields(in: flat).contains { $0.kind == .checkbox && $0.bounds.contains(CGPoint(x: 480, y: 80)) }, "a tick where clicked")

    let form = formDocument(formsFolder("fillpanel2"))
    let filling = ToolSession(tool: .fillForm, provider: tools, document: form)
    guard case .checklist(_, let rows, let ticked)? = filling.panel.controls.first(where: { if case .checklist = $0 { true } else { false } }) else {
        check(false, "the field list"); return
    }
    check(rows.count == 14 && rows.first?.title == "Full name" && ticked.isEmpty, "the field list by label, none filled")
    check(filling.message?.text == Strings.Errors.formHasScripts, "the unsupported script is mentioned")
    _ = service.setValue("Ada", forField: "name", in: form)
    filling.refresh()
    if case .checklist(_, _, let now)? = filling.panel.controls.first(where: { if case .checklist = $0 { true } else { false } }) {
        check(now.contains("name") && now.contains("total") && !now.contains("email"), "filled (and calculated) fields are ticked: \(now)")
    }
    check(filling.panel.controls.filter(\.isChoice).count <= 3, "at most three choices")

    let xfa = formDocument(formsFolder("xfa"), data: formFixture(xfa: true), name: "XFA.pdf")
    let xfaSession = ToolSession(tool: .fillForm, provider: tools, document: xfa)
    check(xfaSession.message?.text == Strings.Errors.xfaForm && xfaSession.panel.controls.isEmpty, "an XFA form is view-only with the notice")
    installFakes()
}
