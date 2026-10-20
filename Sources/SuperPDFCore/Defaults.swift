import Foundation
import SwiftUI
import Combine

// Adapted from super-granola Sources/SuperGranolaCore/Defaults.swift (commit fd1f08b); unchanged apart from the example.

/// Typed UserDefaults access. Every settings key lives in Settings.swift; module-private state is declared in its
/// module with the module as prefix.
///
///     extension Defaults.Keys { static let recentRow = Key<Bool>("toolsKit.recentRow", default: true) }
///     Defaults[.recentRow] = false
///     @Default(.recentRow) var recentRow   // SwiftUI binding, live-updating
///
/// Property-list types (Bool, Int, Double, String, Date, Data, URL-as-string) are stored natively so
/// `defaults read` stays readable; everything else is JSON-encoded.
public enum Defaults {
    public static var store: UserDefaults = .standard

    public class Keys: @unchecked Sendable {
        public let name: String
        init(name: String) { self.name = name }
        public typealias Key<V: Codable> = Defaults.Key<V>
    }

    public final class Key<Value: Codable>: Keys, @unchecked Sendable {
        public let defaultValue: Value
        public init(_ name: String, default defaultValue: Value) {
            self.defaultValue = defaultValue
            super.init(name: name)
        }
    }

    public static subscript<Value: Codable>(key: Key<Value>) -> Value {
        get { read(key) }
        set { write(newValue, for: key) }
    }

    public static func reset<Value>(_ key: Key<Value>) {
        store.removeObject(forKey: key.name)
        changes.send(key.name)
    }

    /// Emits the name of every key written through `Defaults`.
    public static let changes = PassthroughSubject<String, Never>()

    public static func publisher<Value: Codable>(_ key: Key<Value>) -> AnyPublisher<Value, Never> {
        changes.filter { $0 == key.name }
            .map { _ in read(key) }
            .prepend(read(key))
            .eraseToAnyPublisher()
    }

    // MARK: - Storage

    private static func read<Value: Codable>(_ key: Key<Value>) -> Value {
        guard let raw = store.object(forKey: key.name) else { return key.defaultValue }
        if let native = raw as? Value { return native }
        if Value.self == URL.self, let s = raw as? String { return (URL(string: s) as? Value) ?? key.defaultValue }
        if Value.self == URL?.self, let s = raw as? String { return (URL(string: s) as? Value) ?? key.defaultValue }
        if let data = raw as? Data, let decoded = try? JSONDecoder().decode(Value.self, from: data) { return decoded }
        // RawRepresentable enums are stored as their raw value inside JSON fragments.
        if let s = raw as? String, let data = try? JSONEncoder().encode(s),
           let decoded = try? JSONDecoder().decode(Value.self, from: data) { return decoded }
        if let n = raw as? NSNumber, let data = n.stringValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Value.self, from: data) { return decoded }
        return key.defaultValue
    }

    private static func write<Value: Codable>(_ value: Value, for key: Key<Value>) {
        defer { changes.send(key.name) }
        if let optional = value as? OptionalProtocol, optional.isNil {
            // A cleared value whose default isn't nil (a removed shortcut) is stored as JSON null, so the default
            // doesn't come back on the next read; `reset` brings it back.
            if let fallback = key.defaultValue as? OptionalProtocol, !fallback.isNil {
                store.set(Data("null".utf8), forKey: key.name)
            } else {
                store.removeObject(forKey: key.name)
            }
            return
        }
        switch value {
        case let v as Bool: store.set(v, forKey: key.name)
        case let v as Int: store.set(v, forKey: key.name)
        case let v as Double: store.set(v, forKey: key.name)
        case let v as String: store.set(v, forKey: key.name)
        case let v as Date: store.set(v, forKey: key.name)
        case let v as Data: store.set(v, forKey: key.name)
        case let v as URL: store.set(v.absoluteString, forKey: key.name)
        default:
            // Enums with String/Int raw values encode as a single-value JSON fragment; store that natively.
            guard let data = try? JSONEncoder().encode(value) else { return }
            if let fragment = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
               fragment is String || fragment is NSNumber {
                store.set(fragment, forKey: key.name)
            } else {
                store.set(data, forKey: key.name)
            }
        }
    }
}

private protocol OptionalProtocol { var isNil: Bool { get } }
extension Optional: OptionalProtocol { var isNil: Bool { self == nil } }

/// SwiftUI property wrapper that reads/writes a `Defaults` key and re-renders on change.
@propertyWrapper
public struct Default<Value: Codable>: DynamicProperty {
    @StateObject private var box: Box
    private let key: Defaults.Key<Value>

    public init(_ key: Defaults.Key<Value>) {
        self.key = key
        _box = StateObject(wrappedValue: Box(key: key))
    }

    public var wrappedValue: Value {
        get { Defaults[key] }
        nonmutating set { Defaults[key] = newValue }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { Defaults[key] }, set: { Defaults[key] = $0 })
    }

    final class Box: ObservableObject {
        private var cancellable: AnyCancellable?
        init(key: Defaults.Key<Value>) {
            cancellable = Defaults.changes.filter { $0 == key.name }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
}
