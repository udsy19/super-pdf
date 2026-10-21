import CoreGraphics
import Foundation

// Forms (FormsKit: `Services.forms`; features #80, #81, #121). Calculation and format scripts of the common AcroForm
// kinds are emulated natively (`AF*` helpers), never run as JavaScript (features #74, §5).

public enum FormFieldKind: String, Codable, CaseIterable, Sendable {
    case text, multilineText, number, date, checkbox, radioGroup, dropdown, list, button, signature, image, barcode
}

/// A field as FormsKit reads it from, or writes it to, the AcroForm.
public struct FormField: Codable, Hashable, Identifiable, Sendable {
    /// The fully qualified field name.
    public var id: String
    public var kind: FormFieldKind
    public var page: Int
    public var bounds: CGRect
    public var value: String
    public var defaultValue: String
    /// Choice and radio options (export values).
    public var options: [String]
    public var tooltip: String
    public var isRequired: Bool
    public var isReadOnly: Bool
    /// Position in the tab order.
    public var tabIndex: Int
    /// The field's format/keystroke/calculate/validate scripts, when it has the `AF*` kinds we emulate.
    public var scripts: [AFAction: String]

    public init(id: String, kind: FormFieldKind, page: Int, bounds: CGRect, value: String = "", defaultValue: String = "",
                options: [String] = [], tooltip: String = "", isRequired: Bool = false, isReadOnly: Bool = false, tabIndex: Int = 0,
                scripts: [AFAction: String] = [:]) {
        self.id = id; self.kind = kind; self.page = page; self.bounds = bounds; self.value = value; self.defaultValue = defaultValue
        self.options = options; self.tooltip = tooltip; self.isRequired = isRequired; self.isReadOnly = isReadOnly
        self.tabIndex = tabIndex; self.scripts = scripts
    }
}

/// Which script of a field runs (AcroForm additional actions).
public enum AFAction: String, Codable, CaseIterable, Sendable {
    case format, keystroke, calculate, validate
}

/// What an emulated script produced.
public enum AFOutcome: Hashable, Sendable {
    /// The value to show or store.
    case value(String)
    /// Validation failed, with the message to show.
    case rejected(String)
    /// A script kind we don't emulate ("This form uses scripts we don't run.", ux §7.4).
    case unsupported
}

/// Form data exchange formats (features #59).
public enum FormDataFormat: String, Codable, CaseIterable, Sendable {
    case fdf, xfdf, csv, json
}

/// Field values for AutoFill (the Contacts "Me" card, previous fills).
public struct AutoFillProfile: Codable, Hashable, Sendable {
    /// Canonical keys ("name", "email", "phone", "street", "city", "postcode", "country", "birthday") to values.
    public var values: [String: String]

    public init(values: [String: String]) { self.values = values }
}

@MainActor
public protocol FormFilling: AnyObject {
    func fields(in document: DocumentHandle) -> [FormField]
    /// Sets a value and recalculates dependent fields.
    func setValue(_ value: String, forField id: String, in document: DocumentHandle) -> UndoGroup
    /// Fills what it can match from a profile; returns the filled field ids.
    func autoFill(_ profile: AutoFillProfile, in document: DocumentHandle) -> (filled: [String], undo: UndoGroup)
    func clear(_ document: DocumentHandle) -> UndoGroup
    func importData(from file: URL, into document: DocumentHandle) throws -> UndoGroup
    /// FDF, XFDF and JSON are ConvertKit's exports of the document's bytes (`Services.convert`); CSV is FormsKit's.
    func exportData(from document: DocumentHandle, as format: FormDataFormat, to destination: URL) async throws
    /// XFA forms are shown static with a notice (ux §7.4).
    func isXFA(_ document: DocumentHandle) -> Bool
    /// PDFKit drops form data whenever it reads or writes a file: every field's format, keystroke, validate and
    /// calculate scripts (/AA), the calculation order (/CO) and the form's default appearance. FormsKit keeps them while
    /// the document is open; DocumentKit asks for this function on the main actor when a save starts and runs it, off
    /// the main actor, on the bytes PDFKit wrote. Nil when there is nothing to put back.
    func formRestorer(for document: DocumentHandle) -> (@Sendable (Data) throws -> Data)?
}

@MainActor
public protocol FormBuilding: AnyObject {
    /// "Find fields for me": underlines, boxes and labels found by layout analysis (features #81).
    func detectFields(in document: DocumentHandle, pages: [Int]) async throws -> [FormField]
    func add(_ fields: [FormField], to document: DocumentHandle) throws -> UndoGroup
    func update(_ field: FormField, in document: DocumentHandle) throws -> UndoGroup
    func remove(_ fieldIDs: [String], from document: DocumentHandle) throws -> UndoGroup
    func setTabOrder(_ fieldIDs: [String], in document: DocumentHandle) -> UndoGroup
}

/// Native emulation of Adobe's `AF*` helpers (AFNumber_Format, AFSimple_Calculate, AFDate_Format, AFPercent_Format,
/// AFSpecial_Format, …).
public protocol AFScriptEmulator: Sendable {
    /// Runs one script for a field: `value` is the field's value, `fields` every field's value by name.
    func run(_ script: String, action: AFAction, value: String, fields: [String: String]) -> AFOutcome
}

/// Forms (FormsKit).
@MainActor
public protocol FormServicing: FormFilling, FormBuilding {
    var emulator: any AFScriptEmulator { get }
}
