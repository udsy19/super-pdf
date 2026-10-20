// PDFModelKit (engine, docs/ARCHITECTURE.md "Engines"). The Swift wrapper over QPDF (features §3.1): open with
// recovery, passwords, incremental and full saves, objects, page tree, content streams, overlays, images, embedded
// files, outlines, page labels, name trees, structure tree, AcroForm, encryption R6, linearization, signature
// placeholders and ByteRange patching. Written for this repository over the `QPDF` binary target (QPDF's C API); no
// C++ and no QPDF type crosses the module boundary. No app policy: no `Services`, no `Defaults`, no UI strings.
//
// Threading: a `PDFModel` and its objects belong to one task at a time (QPDF's `qpdf_data` is not thread-safe). Engines
// open a private model of the bytes they work on (`PDFSource`), off the main actor, and hand back values.
import Foundation
internal import QPDF
import SuperPDFCore

public enum PDFModelError: Error, Equatable, CustomStringConvertible {
    /// Encrypted and no password was given.
    case passwordRequired
    /// Encrypted and the password given opens neither as user nor as owner.
    case wrongPassword
    /// Not a PDF, or damaged past what recovery can rebuild.
    case damaged(String)
    /// A PDF feature QPDF does not support.
    case unsupported(String)
    /// An appended update cannot be written (no original bytes, encrypted, or the file was rebuilt by recovery).
    case incrementalUnavailable(String)
    /// The CMS is larger than the space reserved for it.
    case signatureTooLarge(needed: Int, capacity: Int)
    /// A call that does not apply (wrong object type, page out of range…).
    case invalidOperation(String)
    /// Any other QPDF failure (I/O, internal).
    case failed(String)

    public var description: String {
        switch self {
        case .passwordRequired: "password required"
        case .wrongPassword: "wrong password"
        case .damaged(let m): "damaged: \(m)"
        case .unsupported(let m): "unsupported: \(m)"
        case .incrementalUnavailable(let m): "incremental update unavailable: \(m)"
        case .signatureTooLarge(let needed, let capacity): "signature of \(needed) bytes exceeds the \(capacity) reserved"
        case .invalidOperation(let m): "invalid operation: \(m)"
        case .failed(let m): m
        }
    }
}

/// How a full save writes the file (QPDFWriter's options).
public struct PDFWriteOptions: Sendable {
    public enum ObjectStreams: Sendable { case preserve, disable, generate }
    public enum StreamDecodeLevel: Sendable { case none, generalized, specialized, all }
    public enum Encryption: Sendable {
        /// Keep the file's own encryption (none stays none).
        case preserve
        /// Write without encryption (the file must have been opened with a password that allows it).
        case remove
        case encrypt(PDFEncryption)
    }

    public var objectStreams: ObjectStreams
    /// Compress streams that are stored uncompressed.
    public var compressStreams: Bool
    /// Decode streams up to this level before writing (and recompress them when `compressStreams`); nil keeps QPDF's
    /// default (generalized filters).
    public var decodeLevel: StreamDecodeLevel?
    /// Fast web view (features #99).
    public var linearize: Bool
    public var encryption: Encryption
    /// The same input writes the same bytes (an /ID from the content, not the clock).
    public var deterministicID: Bool
    /// Keep objects nothing refers to (off: they are dropped).
    public var preserveUnreferencedObjects: Bool
    /// At least this header version ("1.7").
    public var minimumVersion: String?

    public init(objectStreams: ObjectStreams = .preserve, compressStreams: Bool = true, decodeLevel: StreamDecodeLevel? = nil,
                linearize: Bool = false, encryption: Encryption = .preserve, deterministicID: Bool = false,
                preserveUnreferencedObjects: Bool = false, minimumVersion: String? = nil) {
        self.objectStreams = objectStreams; self.compressStreams = compressStreams; self.decodeLevel = decodeLevel
        self.linearize = linearize; self.encryption = encryption; self.deterministicID = deterministicID
        self.preserveUnreferencedObjects = preserveUnreferencedObjects; self.minimumVersion = minimumVersion
    }
}

/// Password encryption for a save (features #86).
public struct PDFEncryption: Hashable, Sendable {
    /// Needed to open; empty opens without a password.
    public var userPassword: String
    /// Needed to change permissions.
    public var ownerPassword: String
    public var permissions: DocumentPermissions
    /// AES-256 (R6) or AES-128 (R4).
    public var method: PasswordOptions.Encryption
    /// Off leaves the XMP metadata readable without the password.
    public var encryptMetadata: Bool

    public init(userPassword: String, ownerPassword: String, permissions: DocumentPermissions = .all,
                method: PasswordOptions.Encryption = .aes256, encryptMetadata: Bool = true) {
        self.userPassword = userPassword; self.ownerPassword = ownerPassword; self.permissions = permissions
        self.method = method; self.encryptMetadata = encryptMetadata
    }
}

/// An open PDF: QPDF's document plus the bytes it was read from (kept for appended saves).
public final class PDFModel {
    let q: qpdf_data
    /// The bytes QPDF reads from (QPDF keeps a pointer to them; freed after `qpdf_cleanup`).
    private let buffer: UnsafeMutableRawBufferPointer?
    /// The password that opened the file.
    public let password: String?
    /// The password bytes QPDF accepted (UTF-8, or Latin-1 for an R2–R4 file).
    let passwordBytes: [UInt8]
    /// Recovery rebuilt the file while opening (features #1, #98).
    public let wasRepaired: Bool
    /// QPDF's warnings so far (opening, lazy object reads, writes).
    public private(set) var warnings: [String] = []

    /// Opens a `PDFSource` (the bytes engines receive).
    public convenience init(_ source: PDFSource, attemptRecovery: Bool = true) throws {
        try self.init(data: try source.bytes(), password: source.password, attemptRecovery: attemptRecovery)
    }

    public convenience init(url: URL, password: String? = nil, attemptRecovery: Bool = true) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw PDFModelError.failed(error.localizedDescription) }
        try self.init(data: data, password: password, attemptRecovery: attemptRecovery)
    }

    /// Opens PDF bytes. A non-ASCII password is tried as UTF-8 (R5/R6) and then as Latin-1 (R2–R4).
    public init(data: Data, password: String? = nil, attemptRecovery: Bool = true) throws {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
        _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
        // The password's UTF-8 bytes (R5/R6), then for non-ASCII text its Latin-1 bytes (R2–R4 use PDFDocEncoding).
        var candidates: [[CChar]?] = [password.map { Array($0.utf8CString) }]
        if let password, !password.allSatisfy(\.isASCII), let latin1 = password.data(using: .isoLatin1) {
            candidates.append(latin1.map { CChar(bitPattern: $0) } + [0])
        }
        var lastError: PDFModelError = .damaged("unreadable")
        for candidate in candidates {
            var handle: qpdf_data? = qpdf_init()
            qpdf_silence_errors(handle)
            qpdf_set_suppress_warnings(handle, QPDF_TRUE)
            qpdf_set_attempt_recovery(handle, attemptRecovery ? QPDF_TRUE : QPDF_FALSE)
            let bytes = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            let rc: QPDF_ERROR_CODE = if let candidate {
                candidate.withUnsafeBufferPointer { qpdf_read_memory(handle, "document.pdf", bytes, UInt64(data.count), $0.baseAddress) }
            } else {
                qpdf_read_memory(handle, "document.pdf", bytes, UInt64(data.count), nil)
            }
            if rc & QPDF_ERRORS == 0 {
                self.q = handle!
                self.buffer = buffer
                self.password = password
                self.passwordBytes = candidate.map { $0.dropLast().map { UInt8(bitPattern: $0) } } ?? []
                var opened: [String] = []
                while qpdf_more_warnings(handle) != QPDF_FALSE {
                    opened.append(String(cString: qpdf_get_error_full_text(handle, qpdf_next_warning(handle))))
                }
                self.warnings = opened
                self.wasRepaired = !opened.isEmpty
                return
            }
            lastError = Self.error(of: handle!, fallback: "unreadable")
            if lastError == .wrongPassword && (password ?? "").isEmpty { lastError = .passwordRequired }
            qpdf_cleanup(&handle)
            if lastError != .wrongPassword { break }
        }
        buffer.deallocate()
        throw lastError
    }

    /// A new, empty PDF (no pages).
    public init() {
        let handle = qpdf_init()
        qpdf_silence_errors(handle)
        qpdf_set_suppress_warnings(handle, QPDF_TRUE)
        _ = qpdf_empty_pdf(handle)
        self.q = handle!
        self.buffer = nil
        self.password = nil
        self.passwordBytes = []
        self.wasRepaired = false
    }

    deinit {
        var handle: qpdf_data? = q
        _ = takeError()
        qpdf_cleanup(&handle)
        buffer?.deallocate()
    }

    /// The bytes the model was opened from (nil for a new document).
    public var originalData: Data? { buffer.map { Data($0) } }

    /// The same bytes without a copy (valid while the model lives).
    var originalBytes: UnsafeRawBufferPointer? { buffer.map { UnsafeRawBufferPointer($0) } }

    // MARK: Errors

    static func error(of q: qpdf_data, fallback: String) -> PDFModelError {
        guard qpdf_has_error(q) != QPDF_FALSE, let e = qpdf_get_error(q) else { return .failed(fallback) }
        let text = String(cString: qpdf_get_error_full_text(q, e))
        switch qpdf_get_error_code(q, e) {
        case qpdf_e_password: return .wrongPassword
        case qpdf_e_damaged_pdf, qpdf_e_pages: return .damaged(text)
        case qpdf_e_unsupported: return .unsupported(text)
        case qpdf_e_object: return .invalidOperation(text)
        default: return .failed(text)
        }
    }

    /// Clears and returns QPDF's pending error; warnings are collected into `warnings`.
    @discardableResult
    func takeError() -> PDFModelError? {
        collectWarnings()
        guard qpdf_has_error(q) != QPDF_FALSE else { return nil }
        return Self.error(of: q, fallback: "QPDF error")
    }

    func collectWarnings() {
        while qpdf_more_warnings(q) != QPDF_FALSE {
            warnings.append(String(cString: qpdf_get_error_full_text(q, qpdf_next_warning(q))))
        }
    }

    /// Throws QPDF's pending error, if any.
    func check(_ code: QPDF_ERROR_CODE = QPDF_SUCCESS) throws {
        if let error = takeError() { throw error }
        if code & QPDF_ERRORS != 0 { throw PDFModelError.failed("QPDF error") }
    }

    // MARK: Document facts

    /// The header version ("1.7").
    public var version: String { String(cString: qpdf_get_pdf_version(q)) }
    public var isEncrypted: Bool { qpdf_is_encrypted(q) != QPDF_FALSE }
    public var isLinearized: Bool { qpdf_is_linearized(q) != QPDF_FALSE }

    /// What the file's permission bits allow (features #90); everything for unencrypted files. QPDF does not enforce
    /// them: callers honour them unless `hasOwnerAccess`.
    public var permissions: DocumentPermissions {
        let printing: DocumentPermissions.PrintingPermission =
            qpdf_allow_print_high_res(q) != QPDF_FALSE ? .highResolution : qpdf_allow_print_low_res(q) != QPDF_FALSE ? .lowResolution : .none
        return DocumentPermissions(printing: printing,
                                   copyingText: qpdf_allow_extract_all(q) != QPDF_FALSE,
                                   fillingFormsAndSigning: qpdf_allow_modify_form(q) != QPDF_FALSE,
                                   commenting: qpdf_allow_modify_annotation(q) != QPDF_FALSE,
                                   pageChanges: qpdf_allow_modify_assembly(q) != QPDF_FALSE,
                                   screenReaders: qpdf_allow_accessibility(q) != QPDF_FALSE)
    }

    public var trailer: PDFObject { PDFObject(self, qpdf_get_trailer(q)) }
    /// The document catalog.
    public var root: PDFObject { PDFObject(self, qpdf_get_root(q)) }

    /// A document information entry ("Title", "Author", "Producer"…) as text.
    public func info(_ key: String) -> String? {
        guard let value = trailer["Info"]?[key], value.type == .string else { return nil }
        return value.text
    }

    /// Sets (or with nil removes) a document information entry.
    public func setInfo(_ key: String, _ value: String?) {
        if let value {
            if trailer["Info"]?.type != .dictionary { trailer.set("Info", makeIndirect(.dictionary([:]))) }
            trailer["Info"]?.set(key, .text(value))
        } else {
            trailer["Info"]?.remove(key)
        }
    }

    /// Reads every object, page and stream and returns what QPDF warned about (empty for a sound file).
    public func check() -> [String] {
        let before = warnings.count
        let rc = qpdf_check_pdf(q)
        if let error = takeError() { warnings.append(error.description) } else if rc & QPDF_ERRORS != 0 { warnings.append("check failed") }
        return Array(warnings[before...])
    }

    // MARK: Objects

    /// The indirect object `id gen R` (a null object when there is none).
    public func object(id: Int, generation: Int = 0) -> PDFObject {
        PDFObject(self, qpdf_get_object_by_id(q, Int32(id), Int32(generation)))
    }

    /// The object for a reference value; nil for other values.
    public func object(_ reference: PDFValue) -> PDFObject? {
        guard let (id, gen) = reference.referenceValue else { return nil }
        return object(id: id, generation: gen)
    }

    /// A new direct object.
    public func make(_ value: PDFValue) -> PDFObject { PDFObject(self, handle(for: value)) }

    /// A new indirect object.
    public func makeIndirect(_ value: PDFValue) -> PDFObject {
        let direct = handle(for: value)
        defer { qpdf_oh_release(q, direct) }
        return PDFObject(self, qpdf_make_indirect_object(q, direct))
    }

    /// Makes a direct object indirect (an indirect object is returned as it is; one of another model is imported).
    public func makeIndirect(_ object: PDFObject) -> PDFObject {
        if object.model !== self { return importObject(object) }
        return object.isIndirect ? object : PDFObject(self, qpdf_make_indirect_object(q, object.oh))
    }

    /// A new indirect stream. `data` is stored as given: pass `filter` (and `decodeParms`) when it is already encoded;
    /// unencoded data is compressed by full saves (`compressStreams`) and by appended saves.
    public func makeStream(_ dictionary: [String: PDFValue] = [:], data: Data, filter: PDFValue? = nil,
                           decodeParms: PDFValue? = nil) -> PDFObject {
        let raw = qpdf_oh_new_stream(q)
        defer { qpdf_oh_release(q, raw) }
        let stream = PDFObject(self, qpdf_make_indirect_object(q, raw))
        for (key, value) in dictionary { stream.set(key, value) }
        stream.setStreamData(data, filter: filter, decodeParms: decodeParms)
        return stream
    }

    /// Copies `object` (and everything it refers to) from another model into this one and returns the copy; an object
    /// of this model is returned as it is. A direct object is first made indirect in its own model.
    public func importObject(_ object: PDFObject) -> PDFObject {
        guard object.model !== self else { return object }
        let source = object.model.makeIndirect(object)
        return PDFObject(self, qpdf_oh_copy_foreign_object(q, source.model.q, source.oh))
    }

    /// Runs `body` with a handle of `object` in this model (importing it when it belongs to another).
    func withHandle<T>(_ object: PDFObject, _ body: (qpdf_oh) -> T) -> T {
        let local = importObject(object)
        return withExtendedLifetime(local) { body(local.oh) }
    }

    /// Builds a QPDF object handle for a value; the caller releases it.
    func handle(for value: PDFValue) -> qpdf_oh {
        switch value {
        case .null: return qpdf_oh_new_null(q)
        case .bool(let v): return qpdf_oh_new_bool(q, v ? QPDF_TRUE : QPDF_FALSE)
        case .integer(let v): return qpdf_oh_new_integer(q, Int64(v))
        case .real(let v): return qpdf_oh_new_real_from_string(q, PDFSyntax.format(v))
        case .name(let v): return qpdf_oh_new_name(q, "/" + v)
        case .string(let v):
            let bytes = [CChar](v.map { CChar(bitPattern: $0) }) + [0]
            return bytes.withUnsafeBufferPointer { qpdf_oh_new_binary_string(q, $0.baseAddress, v.count) }
        case .array(let items):
            let array = qpdf_oh_new_array(q)
            for item in items {
                let h = handle(for: item)
                qpdf_oh_append_item(q, array, h)
                qpdf_oh_release(q, h)
            }
            return array
        case .dictionary(let dict):
            let d = qpdf_oh_new_dictionary(q)
            for (key, item) in dict {
                let h = handle(for: item)
                qpdf_oh_replace_key(q, d, "/" + key, h)
                qpdf_oh_release(q, h)
            }
            return d
        case .reference(let id, let gen):
            return qpdf_get_object_by_id(q, Int32(id), Int32(gen))
        }
    }

    // MARK: Saving

    /// The whole file rewritten by QPDF.
    public func data(options: PDFWriteOptions = PDFWriteOptions()) throws -> Data {
        if options.linearize { return try linearizedData(options) }
        try check(qpdf_init_write_memory(q))
        configure(options)
        try check(qpdf_write(q))
        let count = qpdf_get_buffer_length(q)
        guard let bytes = qpdf_get_buffer(q) else { throw PDFModelError.failed("QPDF wrote no bytes") }
        return Data(bytes: bytes, count: count)
    }

    /// Writes the whole file to `url` (QPDF writes straight to disk unless linearizing).
    public func write(to url: URL, options: PDFWriteOptions = PDFWriteOptions()) throws {
        if options.linearize {
            do { try linearizedData(options).write(to: url, options: .atomic) } catch let error as PDFModelError { throw error } catch {
                throw PDFModelError.failed(error.localizedDescription)
            }
            return
        }
        try check(qpdf_init_write(q, url.path))
        configure(options)
        try check(qpdf_write(q))
    }

    /// Linearization rewrites QPDF's in-memory document (it pushes inherited page attributes and fails on a second
    /// linearized write with other options), so it runs on a fresh copy: write everything else first, reopen that,
    /// and linearize it with its encryption kept.
    private func linearizedData(_ options: PDFWriteOptions) throws -> Data {
        var first = options
        first.linearize = false
        let plain = try data(options: first)
        let password: String? = switch options.encryption {
        case .preserve: self.password
        case .remove: nil
        case .encrypt(let e): e.ownerPassword.isEmpty ? e.userPassword : e.ownerPassword
        }
        let copy = try PDFModel(data: plain, password: password, attemptRecovery: false)
        var second = options
        second.encryption = .preserve
        try copy.check(qpdf_init_write_memory(copy.q))
        copy.configure(second)
        try copy.check(qpdf_write(copy.q))
        let count = qpdf_get_buffer_length(copy.q)
        guard let bytes = qpdf_get_buffer(copy.q) else { throw PDFModelError.failed("QPDF wrote no bytes") }
        return Data(bytes: bytes, count: count)
    }

    private func configure(_ options: PDFWriteOptions) {
        switch options.objectStreams {
        case .preserve: qpdf_set_object_stream_mode(q, qpdf_o_preserve)
        case .disable: qpdf_set_object_stream_mode(q, qpdf_o_disable)
        case .generate: qpdf_set_object_stream_mode(q, qpdf_o_generate)
        }
        qpdf_set_compress_streams(q, options.compressStreams ? QPDF_TRUE : QPDF_FALSE)
        if let level = options.decodeLevel {
            switch level {
            case .none: qpdf_set_decode_level(q, qpdf_dl_none)
            case .generalized: qpdf_set_decode_level(q, qpdf_dl_generalized)
            case .specialized: qpdf_set_decode_level(q, qpdf_dl_specialized)
            case .all: qpdf_set_decode_level(q, qpdf_dl_all)
            }
        }
        qpdf_set_linearization(q, options.linearize ? QPDF_TRUE : QPDF_FALSE)
        qpdf_set_deterministic_ID(q, options.deterministicID ? QPDF_TRUE : QPDF_FALSE)
        qpdf_set_preserve_unreferenced_objects(q, options.preserveUnreferencedObjects ? QPDF_TRUE : QPDF_FALSE)
        if let version = options.minimumVersion { qpdf_set_minimum_pdf_version(q, version) }
        switch options.encryption {
        case .preserve: qpdf_set_preserve_encryption(q, QPDF_TRUE)
        case .remove: qpdf_set_preserve_encryption(q, QPDF_FALSE)
        case .encrypt(let e):
            let p = e.permissions
            let print: qpdf_r3_print_e = switch p.printing {
            case .highResolution: qpdf_r3p_full
            case .lowResolution: qpdf_r3p_low
            case .none: qpdf_r3p_none
            }
            // "Modify other" (general editing) is allowed when every kind of change is.
            let modifyOther = p.pageChanges && p.commenting && p.fillingFormsAndSigning
            func b(_ v: Bool) -> QPDF_BOOL { v ? QPDF_TRUE : QPDF_FALSE }
            switch e.method {
            case .aes256:
                qpdf_set_r6_encryption_parameters2(q, e.userPassword, e.ownerPassword, b(p.screenReaders), b(p.copyingText),
                                                   b(p.pageChanges), b(p.commenting), b(p.fillingFormsAndSigning),
                                                   b(modifyOther), print, b(e.encryptMetadata))
            case .aes128:
                // R4 passwords are PDFDocEncoding bytes: Latin-1 covers what people type there.
                let user = Self.latin1Bytes(e.userPassword), owner = Self.latin1Bytes(e.ownerPassword)
                user.withUnsafeBufferPointer { u in
                    owner.withUnsafeBufferPointer { o in
                        qpdf_set_r4_encryption_parameters_insecure(q, u.baseAddress, o.baseAddress, b(p.screenReaders),
                                                                   b(p.copyingText), b(p.pageChanges), b(p.commenting),
                                                                   b(p.fillingFormsAndSigning), b(modifyOther), print,
                                                                   b(e.encryptMetadata), QPDF_TRUE)
                    }
                }
            }
        }
    }

    /// NUL-terminated Latin-1 bytes when the text is Latin-1, else its UTF-8 bytes.
    private static func latin1Bytes(_ text: String) -> [CChar] {
        let bytes = text.data(using: .isoLatin1).map { [UInt8]($0) } ?? [UInt8](text.utf8)
        return bytes.map { CChar(bitPattern: $0) } + [0]
    }
}
