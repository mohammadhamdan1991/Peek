#if !PEEK_DISABLED
import Foundation
import os

/// A feature flag value: the JSON types every flag provider (LaunchDarkly, Firebase, a backend) serves.
public enum FlagValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FlagValue])
    case object([String: FlagValue])

    /// Parses JSON text, bare values included: `true`, `12`, `"text"`, `{"a": 1}`.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return nil }
        self.init(any: object)
    }

    /// From a value `JSONSerialization` produced, or a provider's `[String: Any]`.
    public init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.compactMap(FlagValue.init(any:)))
        case let object as [String: Any]: self = .object(object.compactMapValues(FlagValue.init(any:)))
        default: return nil
        }
    }

    public var any: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(values): values.map(\.any)
        case let .object(values): values.mapValues(\.any)
        }
    }

    public func json(pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Short form for a list row: `true`, `15`, `"ALG"`, `{ 5 }`, `[ 3 ]`.
    public var summary: String {
        switch self {
        case let .array(values): "[ \(values.count) ]"
        case let .object(values): "{ \(values.count) }"
        default: json()
        }
    }
}

/// Feature flags as the app read them, and the values a developer overrides them with on this device.
///
/// The host's flag layer asks `override(for:)` on every read and serves that value when there is one, reports
/// reads with `didRead`, and lists every flag its provider knows through `setCatalog`. Overrides are saved, so
/// flags read once at launch take them on the next launch. They apply only while `isEnabled`, which the
/// inspector sets once its runtime gate passes.
public final class FlagStore: Sendable {
    public struct Flag: Identifiable, Hashable, Sendable {
        public var key: String
        /// What the provider serves, before any override. Nil when it doesn't know the flag.
        public var remote: FlagValue?
        /// The default in the app's code, known once the flag has been read.
        public var defaultValue: FlagValue?
        public var override: FlagValue?
        public var reads = 0
        public var lastRead: Date?

        public var id: String { key }
        public var value: FlagValue? { override ?? remote ?? defaultValue }
        public var isOverridden: Bool { override != nil }
    }

    private struct Read: Sendable {
        var remote: FlagValue?
        var defaultValue: FlagValue?
        var count = 0
        var last = Date()
    }

    private struct State: Sendable {
        var isEnabled = false
        var source = "Remote"
        var overrides: [String: FlagValue]
        var reads: [String: Read] = [:]
        var catalog: (@Sendable () -> [String: FlagValue])?
        var listeners: [@Sendable (String) -> Void] = []
        var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private static let defaultsKey = "overrides"
    private let state: OSAllocatedUnfairLock<State>
    nonisolated(unsafe) private let defaults: UserDefaults?

    /// `defaults` keeps overrides across launches; nil keeps them in memory only.
    public init(defaults: UserDefaults? = UserDefaults(suiteName: "dev.peek.flags")) {
        self.defaults = defaults
        let saved = (defaults?.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:])
            .compactMapValues(FlagValue.init(json:))
        state = OSAllocatedUnfairLock(initialState: State(overrides: saved))
    }

    /// Off until the inspector's gate passes: an App Store build never serves an override, even a saved one.
    public var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set { state.withLock { $0.isEnabled = newValue } }
    }

    /// The provider's name, shown as the source of remote values: "LaunchDarkly".
    public var source: String {
        get { state.withLock { $0.source } }
        set { state.withLock { $0.source = newValue } }
    }

    /// Every flag the provider holds, so flags not read yet are listed too. Called when the Flags screen loads.
    public func setCatalog(source: String, _ catalog: @escaping @Sendable () -> [String: FlagValue]) {
        state.withLock {
            $0.source = source
            $0.catalog = catalog
        }
        notify()
    }

    /// The value to serve instead of the provider's, or nil to serve the provider's. Hot path: one lock, no work.
    public func override(for key: String) -> FlagValue? {
        state.withLock { $0.isEnabled ? $0.overrides[key] : nil }
    }

    /// Records a read, with what the provider served before any override.
    public func didRead(_ key: String, remote: FlagValue?, defaultValue: FlagValue?) {
        state.withLock { s in
            guard s.isEnabled else { return }
            var read = s.reads[key] ?? Read()
            read.remote = remote
            read.defaultValue = defaultValue
            read.count += 1
            read.last = Date()
            s.reads[key] = read
        }
    }

    /// Nil removes the override. Listeners hear about it, so the host can re-serve the flag to its observers.
    public func setOverride(_ value: FlagValue?, for key: String) {
        let listeners = state.withLock { s in
            s.overrides[key] = value
            return s.listeners
        }
        save()
        listeners.forEach { $0(key) }
        notify()
    }

    public func removeAllOverrides() {
        let (keys, listeners) = state.withLock { s in
            defer { s.overrides = [:] }
            return (Array(s.overrides.keys), s.listeners)
        }
        save()
        for key in keys { listeners.forEach { $0(key) } }
        notify()
    }

    /// Called with a flag's key after its override changes.
    public func onOverrideChange(_ listener: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.listeners.append(listener) }
    }

    public var overrideCount: Int { state.withLock { $0.overrides.count } }

    /// Every known flag: the provider's catalog, plus flags read or overridden that it doesn't list.
    /// Overridden first, then by key.
    public var flags: [Flag] {
        let (catalog, overrides, reads) = state.withLock { ($0.catalog, $0.overrides, $0.reads) }
        // The catalog runs outside the lock: it calls into the provider, which may read flags itself.
        let remote = catalog?() ?? [:]
        let keys = Set(remote.keys).union(overrides.keys).union(reads.keys)
        return keys.map { key in
            let read = reads[key]
            return Flag(key: key, remote: remote[key] ?? read?.remote, defaultValue: read?.defaultValue,
                        override: overrides[key], reads: read?.count ?? 0, lastRead: read?.last)
        }
        .sorted { ($0.isOverridden ? 0 : 1, $0.key) < ($1.isOverridden ? 0 : 1, $1.key) }
    }

    /// Yields when overrides or the catalog change. Reads don't: they can happen thousands of times a second.
    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        state.withLock { $0.observers[id] = continuation }
        return stream
    }

    private func notify() {
        state.withLock { Array($0.observers.values) }.forEach { $0.yield() }
    }

    private func save() {
        let overrides = state.withLock { $0.overrides }
        defaults?.set(overrides.mapValues { $0.json() }, forKey: Self.defaultsKey)
    }
}
#endif
