#if !PEEK_DISABLED
import Foundation

/// One analytics event as the app handed it to its SDKs: what each destination got, what was dropped, what's wrong.
public struct EventRecord: InspectorRecord {
    /// `event` and `screenView` come from an analytics sink; the rest are direct SDK calls the apps make
    /// outside it (user id and properties, logs, recorded errors).
    public enum Kind: String, Sendable, CaseIterable {
        case event, screenView, identity, log, error

        /// Sent through an analytics sink, so SDK rules apply and a missing destination is a bug.
        public var isTracked: Bool { self == .event || self == .screenView }

        public var label: String {
            switch self {
            case .event: "Event"
            case .screenView: "Screen view"
            case .identity: "Identity"
            case .log: "Log"
            case .error: "Error"
            }
        }
    }

    /// A property value, typed the way the SDKs see it. `other` is anything they may reject (arrays, dates, custom types).
    public enum Value: Sendable, Hashable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case other(type: String, text: String)

        public init(_ any: Any) {
            switch any {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
            case let string as String: self = .string(string)
            case let bool as Bool: self = .bool(bool)
            case let int as Int: self = .int(int)
            case let double as Double: self = .double(double)
            case let float as Float: self = .double(Double(float))
            case let number as NSNumber: self = CFNumberIsFloatType(number) ? .double(number.doubleValue) : .int(number.intValue)
            default:
                let mirror = Mirror(reflecting: any)
                if mirror.displayStyle == .optional {
                    self = mirror.children.first.map { Value($0.value) } ?? .other(type: "nil", text: "nil")
                } else {
                    self = .other(type: Self.typeName(of: any), text: String(describing: any))
                }
            }
        }

        public var typeName: String {
            switch self {
            case .string: "string"
            case .int: "int"
            case .double: "double"
            case .bool: "bool"
            case let .other(type, _): type
            }
        }

        /// JSON-ish: strings quoted, the rest bare.
        public var displayText: String {
            switch self {
            case let .string(string): "\"\(string)\""
            case let .int(int): "\(int)"
            case let .double(double): "\(double)"
            case let .bool(bool): "\(bool)"
            case let .other(_, text): text
            }
        }

        var jsonValue: Any {
            switch self {
            case let .string(string): string
            case let .int(int): int
            case let .double(double): double.isFinite ? double : String(double)
            case let .bool(bool): bool
            case let .other(_, text): text
            }
        }

        private static func typeName(of any: Any) -> String {
            switch any {
            case is Date: "Date"
            case is URL: "URL"
            case is Error: "Error"
            case is [Any], is NSArray: "array"
            case is [AnyHashable: Any], is NSDictionary: "dictionary"
            default: "\(type(of: any))"
            }
        }
    }

    public struct Property: Sendable, Hashable {
        public let key: String
        public var value: Value
        /// Added by the app to every event (super properties), not by this event.
        public let isSuper: Bool

        public init(key: String, value: Value, isSuper: Bool = false) {
            self.key = key
            self.value = value
            self.isSuper = isSuper
        }
    }

    /// What one destination (Firebase, CleverTap…) received.
    public struct Delivery: Sendable, Hashable {
        public let destination: String
        public let name: String
        public var properties: [Property]

        public init(destination: String, name: String, properties: [Property]) {
            self.destination = destination
            self.name = name
            self.properties = properties
        }
    }

    public struct Warning: Sendable, Hashable {
        /// Short label: a destination ("FIR"), "PII", "TYPE", "DROP", "KEYS".
        public let tag: String
        public let message: String
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    /// The name shown in lists: Firebase's if it got one, else the first destination's.
    public let name: String
    /// The Swift type of the event, e.g. `TripAcceptedEvent`.
    public let source: String?
    public var deliveries: [Delivery]
    /// Destinations the event asked for that the app doesn't send to.
    public let dropped: [String]
    public var warnings: [Warning]
    /// True for the stored, redacted copy; false for `revealed()`.
    public var isRedacted: Bool
    /// The deliveries with their real values, in memory only; nil on a revealed copy.
    public var originalDeliveries: [Delivery]?

    public init(
        id: UUID = UUID(), date: Date = Date(), kind: Kind = .event, name: String, source: String? = nil,
        deliveries: [Delivery], dropped: [String] = [], warnings: [Warning] = [], isRedacted: Bool = true,
        originalDeliveries: [Delivery]? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.name = name
        self.source = source
        self.deliveries = deliveries
        self.dropped = dropped
        self.warnings = warnings
        self.isRedacted = isRedacted
        self.originalDeliveries = originalDeliveries
    }

    public func revealed() -> EventRecord {
        guard let originalDeliveries else { return self }
        var record = self
        record.deliveries = originalDeliveries
        record.isRedacted = false
        record.originalDeliveries = nil
        return record
    }

    public func displayed(redacted: Bool) -> EventRecord { redacted ? self : revealed() }

    public var byteCost: Int {
        (deliveries + (originalDeliveries ?? [])).reduce(name.utf8.count) { total, delivery in
            delivery.properties.reduce(total + delivery.name.utf8.count) { $0 + $1.key.utf8.count + $1.value.displayText.utf8.count }
        }
    }

    public var hasWarnings: Bool { !warnings.isEmpty }
}

/// Short destination labels for chips: FIR, CT, ADJ, FB, LD, LP.
public enum Destination {
    public static func shortName(_ destination: String) -> String {
        switch destination.lowercased() {
        case "firebase": "FIR"
        case "clevertap": "CT"
        case "adjust": "ADJ"
        case "facebook", "meta": "FB"
        case "launchdarkly": "LD"
        case "leanplum": "LP"
        case "crashlytics": "CR"
        case "datadog": "DD"
        case "clarity": "CL"
        case "screeb": "SCR"
        case "sentry": "SEN"
        case "analyticscenter": "AC"
        default: String(destination.prefix(3)).uppercased()
        }
    }
}
#endif
