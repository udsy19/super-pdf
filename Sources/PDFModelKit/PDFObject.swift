import CoreGraphics
import Foundation
internal import QPDF

/// The kind of a PDF object.
public enum PDFObjectType: Sendable {
    case null, bool, integer, real, string, name, array, dictionary, stream
    /// Content-stream-only or internal QPDF types.
    case other
}

/// How far stream data is decoded when read (QPDF's decode levels).
public enum PDFStreamDecode: Sendable {
    /// The stored bytes, filters untouched.
    case none
    /// Flate, LZW, ASCII85, ASCIIHex (images stay encoded: DCT data is a JPEG file).
    case generalized
    /// Also RunLength.
    case specialized
    /// Also lossy filters (DCT): image samples.
    case all

    var level: qpdf_stream_decode_level_e {
        switch self {
        case .none: qpdf_dl_none
        case .generalized: qpdf_dl_generalized
        case .specialized: qpdf_dl_specialized
        case .all: qpdf_dl_all
        }
    }
}

/// A live object of a `PDFModel`: a handle into QPDF's document. Changes go straight into the model. Dictionary methods
/// on a stream work on the stream's dictionary. Keys are names without the leading slash.
public final class PDFObject {
    public let model: PDFModel
    let oh: qpdf_oh
    private var q: qpdf_data { model.q }

    init(_ model: PDFModel, _ oh: qpdf_oh) {
        self.model = model
        self.oh = oh
    }

    deinit { qpdf_oh_release(model.q, oh) }

    // MARK: Identity and type

    public var type: PDFObjectType {
        switch qpdf_oh_get_type_code(q, oh) {
        case ot_null, ot_uninitialized: .null
        case ot_boolean: .bool
        case ot_integer: .integer
        case ot_real: .real
        case ot_string: .string
        case ot_name: .name
        case ot_array: .array
        case ot_dictionary: .dictionary
        case ot_stream: .stream
        default: .other
        }
    }

    public var isNull: Bool { type == .null }
    public var isIndirect: Bool { qpdf_oh_is_indirect(q, oh) != QPDF_FALSE }
    /// The object number of an indirect object.
    public var objectID: Int? { isIndirect ? Int(qpdf_oh_get_object_id(q, oh)) : nil }
    public var generation: Int { Int(qpdf_oh_get_generation(q, oh)) }
    /// `id gen R` for an indirect object.
    public var reference: PDFValue? { objectID.map { .reference($0, generation) } }

    /// Same indirect object of the same model.
    public func isSameObject(as other: PDFObject) -> Bool {
        model === other.model && objectID != nil && objectID == other.objectID && generation == other.generation
    }

    /// A dictionary (or stream) whose /Type is `type` (and /Subtype `subtype` when given).
    public func isDictionary(ofType type: String, subtype: String? = nil) -> Bool {
        guard let dict = dictionaryHandleObject, dict.type == .dictionary else { return false }
        return dict["Type"]?.name == type && (subtype == nil || dict["Subtype"]?.name == subtype)
    }

    // MARK: Scalars

    public var bool: Bool? { type == .bool ? qpdf_oh_get_bool_value(q, oh) != QPDF_FALSE : nil }

    public var int: Int? {
        switch type {
        case .integer: Int(qpdf_oh_get_int_value(q, oh))
        case .real: number.flatMap { $0.rounded() == $0 && abs($0) < 1e15 ? Int($0) : nil }
        default: nil
        }
    }

    public var number: Double? {
        switch type {
        case .integer, .real: qpdf_oh_get_numeric_value(q, oh)
        default: nil
        }
    }

    /// A name without its slash.
    public var name: String? {
        guard type == .name else { return nil }
        let text = String(cString: qpdf_oh_get_name(q, oh))
        return text.hasPrefix("/") ? String(text.dropFirst()) : text
    }

    /// A string's bytes.
    public var stringData: Data? {
        guard type == .string else { return nil }
        var length = 0
        guard let bytes = qpdf_oh_get_binary_string_value(q, oh, &length) else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    /// A string decoded as a PDF text string.
    public var text: String? { stringData.map(PDFText.decode) }

    public var rect: CGRect? { value.rectValue }

    // MARK: Arrays

    /// Array items (0 for other types).
    public var count: Int { type == .array ? Int(qpdf_oh_get_array_n_items(q, oh)) : 0 }

    public subscript(index: Int) -> PDFObject? {
        guard index >= 0, index < count else { return nil }
        return PDFObject(model, qpdf_oh_get_array_item(q, oh, Int32(index)))
    }

    /// The items of an array (empty for other types).
    public var items: [PDFObject] { (0..<count).map { PDFObject(model, qpdf_oh_get_array_item(q, oh, Int32($0))) } }

    public func append(_ value: PDFValue) {
        let h = model.handle(for: value)
        qpdf_oh_append_item(q, oh, h)
        qpdf_oh_release(q, h)
    }

    public func append(_ object: PDFObject) { model.withHandle(object) { qpdf_oh_append_item(q, oh, $0) } }

    public func insert(_ value: PDFValue, at index: Int) {
        let h = model.handle(for: value)
        qpdf_oh_insert_item(q, oh, Int32(index), h)
        qpdf_oh_release(q, h)
    }

    public func insert(_ object: PDFObject, at index: Int) {
        model.withHandle(object) { qpdf_oh_insert_item(q, oh, Int32(index), $0) }
    }

    public func replaceItem(at index: Int, with value: PDFValue) {
        let h = model.handle(for: value)
        qpdf_oh_set_array_item(q, oh, Int32(index), h)
        qpdf_oh_release(q, h)
    }

    public func replaceItem(at index: Int, with object: PDFObject) {
        model.withHandle(object) { qpdf_oh_set_array_item(q, oh, Int32(index), $0) }
    }

    public func removeItem(at index: Int) { qpdf_oh_erase_item(q, oh, Int32(index)) }

    // MARK: Dictionaries (a stream's dictionary for streams)

    /// The stream's dictionary for a stream, else the object itself.
    private var dictionaryHandleObject: PDFObject? {
        switch type {
        case .stream: PDFObject(model, qpdf_oh_get_dict(q, oh))
        case .dictionary: self
        default: nil
        }
    }

    /// A stream's dictionary.
    public var streamDictionary: PDFObject? { type == .stream ? PDFObject(model, qpdf_oh_get_dict(q, oh)) : nil }

    public var keys: [String] {
        guard let dict = dictionaryHandleObject else { return [] }
        qpdf_oh_begin_dict_key_iter(q, dict.oh)
        var keys: [String] = []
        while qpdf_oh_dict_more_keys(q) != QPDF_FALSE {
            let key = String(cString: qpdf_oh_dict_next_key(q))
            keys.append(key.hasPrefix("/") ? String(key.dropFirst()) : key)
        }
        return keys
    }

    public func has(_ key: String) -> Bool {
        guard let dict = dictionaryHandleObject else { return false }
        return qpdf_oh_has_key(q, dict.oh, "/" + key) != QPDF_FALSE
    }

    /// The entry for `key`; nil when missing or null.
    public subscript(key: String) -> PDFObject? {
        guard let dict = dictionaryHandleObject else { return nil }
        let value = PDFObject(model, qpdf_oh_get_key(q, dict.oh, "/" + key))
        return value.isNull ? nil : value
    }

    /// The entry for `key`, looked up through /Parent links as page attributes and field attributes inherit.
    public func inherited(_ key: String) -> PDFObject? {
        var node: PDFObject? = self
        var seen: Set<Int> = []
        while let current = node {
            if let value = current[key] { return value }
            if let id = current.objectID { guard seen.insert(id).inserted else { return nil } }
            node = current["Parent"]
            if seen.count > 1000 { return nil }
        }
        return nil
    }

    public func set(_ key: String, _ value: PDFValue) {
        guard let dict = dictionaryHandleObject else { return }
        let h = model.handle(for: value)
        qpdf_oh_replace_or_remove_key(q, dict.oh, "/" + key, h)
        qpdf_oh_release(q, h)
    }

    public func set(_ key: String, _ object: PDFObject) {
        guard let dict = dictionaryHandleObject else { return }
        model.withHandle(object) { qpdf_oh_replace_or_remove_key(q, dict.oh, "/" + key, $0) }
    }

    public func remove(_ key: String) {
        guard let dict = dictionaryHandleObject else { return }
        qpdf_oh_remove_key(q, dict.oh, "/" + key)
    }

    /// The array at `key`, created empty when missing (a non-array value is replaced).
    public func array(_ key: String) -> PDFObject {
        if let existing = self[key], existing.type == .array { return existing }
        set(key, .array([]))
        return self[key]!
    }

    /// The dictionary at `key`, created empty when missing (a non-dictionary value is replaced).
    public func dictionary(_ key: String) -> PDFObject {
        if let existing = self[key], existing.type == .dictionary { return existing }
        set(key, .dictionary([:]))
        return self[key]!
    }

    // MARK: Streams

    /// The stream's data decoded to `decode`. Throws when the object is not a stream or the data is unreadable.
    public func streamData(decode: PDFStreamDecode = .generalized) throws -> Data {
        guard type == .stream else { throw PDFModelError.invalidOperation("not a stream") }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let rc = qpdf_oh_get_stream_data(q, oh, decode.level, nil, &buffer, &length)
        defer { if buffer != nil { qpdf_oh_free_buffer(&buffer) } }
        try model.check(rc)
        guard let buffer else { return Data() }
        return Data(bytes: buffer, count: length)
    }

    /// Whether `streamData(decode:)` at this level returns decoded data (false: the filters are not decodable there).
    public func canDecode(to decode: PDFStreamDecode) -> Bool {
        guard type == .stream else { return false }
        var filtered: QPDF_BOOL = QPDF_FALSE
        _ = qpdf_oh_get_stream_data(q, oh, decode.level, &filtered, nil, nil)
        model.takeError()
        return filtered != QPDF_FALSE
    }

    /// Replaces the stream's data. `filter`/`decodeParms` describe how `data` is encoded (nil: unencoded) and replace
    /// /Filter and /DecodeParms.
    public func setStreamData(_ data: Data, filter: PDFValue? = nil, decodeParms: PDFValue? = nil) {
        guard type == .stream else { return }
        let f = model.handle(for: filter ?? .null), p = model.handle(for: decodeParms ?? .null)
        data.withUnsafeBytes { bytes in
            qpdf_oh_replace_stream_data(q, oh, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count, f, p)
        }
        qpdf_oh_release(q, f); qpdf_oh_release(q, p)
        // QPDF keeps a /Length from before; writers recompute it, so drop the stale one.
        streamDictionary?.remove("Length")
    }

    /// The names in /Filter (one name or an array of them).
    public var filters: [String] {
        guard let filter = self["Filter"] else { return [] }
        if let name = filter.name { return [name] }
        return filter.items.compactMap(\.name)
    }

    // MARK: Values

    /// The object as a value: direct parts converted recursively, indirect parts as references. A stream gives its
    /// dictionary; an indirect object gives its content (use `reference` for the reference).
    public var value: PDFValue { model.value(of: oh, depth: 0) }
}

extension PDFModel {
    /// Converts a handle to a value; nested indirect objects become references.
    func value(of oh: qpdf_oh, depth: Int) -> PDFValue {
        if depth > 0, qpdf_oh_is_indirect(q, oh) != QPDF_FALSE {
            return .reference(Int(qpdf_oh_get_object_id(q, oh)), Int(qpdf_oh_get_generation(q, oh)))
        }
        guard depth < 500 else { return .null }
        switch qpdf_oh_get_type_code(q, oh) {
        case ot_boolean: return .bool(qpdf_oh_get_bool_value(q, oh) != QPDF_FALSE)
        case ot_integer: return .integer(Int(qpdf_oh_get_int_value(q, oh)))
        case ot_real: return .real(qpdf_oh_get_numeric_value(q, oh))
        case ot_name:
            let text = String(cString: qpdf_oh_get_name(q, oh))
            return .name(text.hasPrefix("/") ? String(text.dropFirst()) : text)
        case ot_string:
            var length = 0
            guard let bytes = qpdf_oh_get_binary_string_value(q, oh, &length) else { return .string(Data()) }
            return .string(Data(bytes: bytes, count: length))
        case ot_array:
            let n = qpdf_oh_get_array_n_items(q, oh)
            var items: [PDFValue] = []
            items.reserveCapacity(Int(max(n, 0)))
            for i in 0..<max(n, 0) {
                let item = qpdf_oh_get_array_item(q, oh, i)
                items.append(value(of: item, depth: depth + 1))
                qpdf_oh_release(q, item)
            }
            return .array(items)
        case ot_dictionary:
            return .dictionary(dictionaryValue(of: oh, depth: depth))
        case ot_stream:
            let dict = qpdf_oh_get_dict(q, oh)
            defer { qpdf_oh_release(q, dict) }
            return .dictionary(dictionaryValue(of: dict, depth: depth))
        default:
            return .null
        }
    }

    private func dictionaryValue(of oh: qpdf_oh, depth: Int) -> [String: PDFValue] {
        qpdf_oh_begin_dict_key_iter(q, oh)
        var keys: [String] = []
        while qpdf_oh_dict_more_keys(q) != QPDF_FALSE { keys.append(String(cString: qpdf_oh_dict_next_key(q))) }
        var dict: [String: PDFValue] = [:]
        for key in keys {
            let item = qpdf_oh_get_key(q, oh, key)
            let v = value(of: item, depth: depth + 1)
            qpdf_oh_release(q, item)
            // A null entry is the same as no entry.
            if !v.isNull { dict[key.hasPrefix("/") ? String(key.dropFirst()) : key] = v }
        }
        return dict
    }
}
