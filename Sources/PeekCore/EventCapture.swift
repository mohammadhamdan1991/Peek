#if !PEEK_DISABLED
import Foundation

/// Turns an analytics event into an `EventRecord`: checks it, redacts it per `policy` (keeping the real values
/// alongside), stores it.
///
/// Callable from any thread. The caller pays for converting the values (they're `Any`, so not `Sendable`)
/// and an enqueue; checks, redaction and storage run on a private serial queue.
public struct EventCapture: Sendable {
    /// One destination's share of an event, as the host's sink has it.
    public struct Delivery {
        public let destination: String
        public let name: String
        public let properties: [String: Any]?

        public init(destination: String, name: String, properties: [String: Any]?) {
            self.destination = destination
            self.name = name
            self.properties = properties
        }
    }

    public let store: RecordStore<EventRecord>
    public let policy: RedactionPolicy
    private let queue = DispatchQueue(label: "dev.peek.event-capture", qos: .utility)
    private let typesByName = TypeMemory()

    public init(store: RecordStore<EventRecord>, policy: RedactionPolicy = RedactionPolicy()) {
        self.store = store
        self.policy = policy
    }

    public func flush() {
        queue.sync {}
    }

    /// - Parameters:
    ///   - superPropertyKeys: keys the app adds to every event, shown as such.
    ///   - dropped: what the event asked for at destinations the app doesn't send to.
    ///   - hostWarnings: anything else the host knows is wrong.
    public func track(
        kind: EventRecord.Kind = .event,
        source: String? = nil,
        deliveries: [Delivery],
        superPropertyKeys: Set<String> = [],
        dropped: [Delivery] = [],
        hostWarnings: [String] = []
    ) {
        let all = deliveries + dropped
        guard !store.isPaused, let first = all.first else { return }
        let date = Date()
        let redactor = policy.redactor
        let typed = deliveries.map { delivery in
            EventRecord.Delivery(
                destination: delivery.destination,
                name: delivery.name,
                properties: (delivery.properties ?? [:]).map {
                    EventRecord.Property(key: $0.key, value: EventRecord.Value($0.value), isSuper: superPropertyKeys.contains($0.key))
                }.sorted { ($0.isSuper ? 1 : 0, $0.key) < ($1.isSuper ? 1 : 0, $1.key) }
            )
        }
        let name = all.first { $0.destination.lowercased() == "firebase" }?.name ?? first.name
        let droppedNames = dropped.map(\.destination)
        queue.async { [store, typesByName] in
            // Checks see the values as sent; redaction comes after.
            let isTracked = kind.isTracked
            // A tracked event asking for a destination the app has no tracker for is a bug; a direct call that
            // isn't sent in this build (Crashlytics on staging) is just how that build works.
            var warnings = !isTracked ? [] : droppedNames.map {
                EventRecord.Warning(tag: "DROP", message: "\($0) was requested, but the app doesn't send to it. Not sent.")
            }
            warnings += hostWarnings.map { EventRecord.Warning(tag: "APP", message: $0) }
            // SDK rules and PII checks are about tracked events: identity calls carry phone and email by design.
            if isTracked { warnings += EventChecks.warnings(for: typed) }
            let types = Dictionary(typed.flatMap { $0.properties.map { ($0.key, $0.value.typeName) } }, uniquingKeysWith: { first, _ in first })
            for change in isTracked ? typesByName.changes(name: name, types: types) : [] {
                warnings.append(EventRecord.Warning(tag: "TYPE", message: change))
            }
            store.record(EventRecord(
                date: date, kind: kind, name: name, source: source,
                deliveries: typed.map { Self.redact($0, with: redactor) },
                dropped: droppedNames,
                warnings: EventChecks.unique(warnings),
                originalDeliveries: typed
            ))
        }
    }

    /// One direct SDK call outside an analytics sink: identity, user properties, a log, an error, an attribution.
    /// Each destination gets the same name and properties; `notSentTo` shows destinations this build skips.
    public func record(
        _ kind: EventRecord.Kind,
        _ name: String,
        to destinations: [String],
        notSentTo skipped: [String] = [],
        properties: [String: Any]? = nil,
        source: String? = nil
    ) {
        func deliveries(_ names: [String]) -> [Delivery] { names.map { .init(destination: $0, name: name, properties: properties) } }
        track(kind: kind, source: source, deliveries: deliveries(destinations), dropped: deliveries(skipped))
    }

    static func redact(_ delivery: EventRecord.Delivery, with redactor: Redactor) -> EventRecord.Delivery {
        var delivery = delivery
        delivery.properties = delivery.properties.map { property in
            var property = property
            if redactor.isSensitive(key: property.key) {
                property.value = .string(Redactor.mask)
            } else if case let .string(text) = property.value {
                property.value = .string(redactor.redact(text: text))
            } else if case let .other(type, text) = property.value {
                property.value = .other(type: type, text: redactor.redact(text: text))
            }
            return property
        }
        return delivery
    }

    /// Property types last seen per event name. Touched only on `queue`.
    ///
    /// A property switching type (`fare` sent as a string, then a double) breaks dashboards and funnels, so it's
    /// flagged. Keys coming and going is normal (optional properties), so it isn't.
    private final class TypeMemory: @unchecked Sendable {
        private var types: [String: [String: String]] = [:]

        func changes(name: String, types new: [String: String]) -> [String] {
            let old = types[name] ?? [:]
            types[name, default: [:]].merge(new) { _, latest in latest }
            return new.keys.sorted().compactMap { key in
                guard let before = old[key], let now = new[key], before != now else { return nil }
                return "\(key) was sent as \(before) earlier this session, now as \(now)."
            }
        }
    }
}

/// What each SDK rejects or mangles, and what shouldn't leave the device. Labels, never changes, the payload.
enum EventChecks {
    static func warnings(for deliveries: [EventRecord.Delivery]) -> [EventRecord.Warning] {
        var warnings: [EventRecord.Warning] = []
        for delivery in deliveries {
            switch delivery.destination.lowercased() {
            case "firebase": warnings += firebase(delivery)
            case "clevertap": warnings += cleverTap(delivery)
            case "adjust": warnings += adjust(delivery)
            default: break
            }
            for property in delivery.properties where !property.isSuper {
                if case let .other(type, _) = property.value {
                    warnings.append(.init(tag: "TYPE", message: "\(property.key) is a \(type) value; SDKs may reject it or send it inconsistently."))
                }
                let risks = risks(key: property.key, value: property.value)
                if !risks.isEmpty {
                    warnings.append(.init(tag: "PII", message: "\(property.key) may contain \(risks.joined(separator: ", "))."))
                }
            }
        }
        return warnings
    }

    static func unique(_ warnings: [EventRecord.Warning]) -> [EventRecord.Warning] {
        var seen = Set<EventRecord.Warning>()
        return warnings.filter { seen.insert($0).inserted }
    }

    // MARK: Firebase (https://firebase.google.com/docs/reference/cpp/group/event-names, Analytics limits)

    static let firebaseReservedNames: Set<String> = [
        "ad_activeview", "ad_click", "ad_exposure", "ad_query", "ad_reward", "adunit_exposure", "app_background",
        "app_clear_data", "app_exception", "app_remove", "app_store_refund", "app_store_subscription_cancel",
        "app_store_subscription_convert", "app_store_subscription_renew", "app_update", "app_upgrade",
        "dynamic_link_app_open", "dynamic_link_app_update", "dynamic_link_first_open", "error", "first_open",
        "first_visit", "in_app_purchase", "notification_dismiss", "notification_foreground", "notification_open",
        "notification_receive", "os_update", "session_start", "session_start_with_rollout", "user_engagement",
    ]

    private static func firebase(_ delivery: EventRecord.Delivery) -> [EventRecord.Warning] {
        var messages: [String] = []
        let name = delivery.name
        if let problem = firebaseNameProblem(name) { messages.append("Event name \(problem); Firebase drops the event.") }
        if firebaseReservedNames.contains(name) { messages.append("'\(name)' is reserved by Firebase; the event is dropped.") }
        let own = delivery.properties
        if own.count > 25 { messages.append("\(own.count) properties; Firebase keeps 25 and drops the rest.") }
        for property in own {
            if let problem = firebaseNameProblem(property.key) { messages.append("Property '\(property.key)' \(problem); Firebase drops it.") }
            if case let .string(value) = property.value, value.count > 100 {
                messages.append("\(property.key) is \(value.count) characters; Firebase keeps the first 100.")
            }
        }
        return messages.map { .init(tag: "FIR", message: $0) }
    }

    private static func firebaseNameProblem(_ name: String) -> String? {
        if name.count > 40 { return "'\(name)' is \(name.count) characters (max 40)" }
        if ["firebase_", "google_", "ga_"].contains(where: name.hasPrefix) { return "'\(name)' uses a reserved prefix" }
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first), first.isASCII,
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
        else { return "'\(name)' must start with a letter and use only letters, digits and _" }
        return nil
    }

    // MARK: CleverTap (https://docs.clevertap.com/docs/platform-considerations)

    private static func cleverTap(_ delivery: EventRecord.Delivery) -> [EventRecord.Warning] {
        var messages: [String] = []
        let forbidden = Set(#"%<>|&.:;$"'\"#)
        if delivery.name.contains(where: forbidden.contains) {
            messages.append("Event name '\(delivery.name)' has a character CleverTap doesn't allow (% < > | & . : ; $ \" ' \\).")
        }
        if delivery.properties.count > 256 { messages.append("\(delivery.properties.count) properties; CleverTap keeps 256.") }
        for property in delivery.properties {
            if property.key.count > 120 { messages.append("Property key '\(property.key.prefix(30))…' is over 120 characters.") }
            if case let .string(value) = property.value, value.count > 512 {
                messages.append("\(property.key) is \(value.count) characters; CleverTap keeps 512.")
            }
        }
        return messages.map { .init(tag: "CT", message: $0) }
    }

    // MARK: Adjust: the "name" is the event token from the Adjust dashboard

    private static func adjust(_ delivery: EventRecord.Delivery) -> [EventRecord.Warning] {
        let isToken = delivery.name.count == 6 && delivery.name.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        guard !isToken else { return [] }
        return [.init(tag: "ADJ", message: "'\(delivery.name)' doesn't look like an Adjust event token (6 letters or digits); Adjust ignores unknown tokens.")]
    }

    // MARK: Personal data

    /// Keys alone flag only what's rarely safe to send (credentials, phone, email). URLs and errors need the value
    /// to look like one: a `reason` of "tokenNotExpired" or a `deep_link_type` of "promo" are fine.
    static func risks(key: String, value: EventRecord.Value) -> [String] {
        let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
        var risks: Set<String> = []
        if ["token", "authorization", "authheader", "authbearer", "session", "secret", "password"].contains(where: key.contains) {
            risks.insert("credential or session data")
        }
        if ["phone", "mobile", "msisdn"].contains(where: key.contains) { risks.insert("phone data") }
        if key.contains("email") { risks.insert("email data") }
        if case let .string(text) = value {
            if ["error", "reason", "details", "message"].contains(where: key.contains), text.contains(" "), text.count > 40 {
                risks.insert("a raw error message") // a sentence, not a code like "tokenNotExpired"
            }
            let lower = text.lowercased()
            if lower.contains("bearer ") || lower.contains("access_token") { risks.insert("credential or session data") }
            if lower.contains("://") || lower.hasPrefix("www.") { risks.insert("a raw URL") }
            if text.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil {
                risks.insert("email data")
            }
            if looksLikePhone(text) { risks.insert("phone data") }
        }
        return risks.sorted()
    }

    static func looksLikePhone(_ value: String) -> Bool {
        guard let range = value.range(of: #"\+?[\d\s()-]{7,}"#, options: .regularExpression) else { return false }
        let candidate = value[range]
        guard (7...15).contains(candidate.filter(\.isNumber).count) else { return false }
        return candidate.hasPrefix("+") || candidate.contains(" ") || candidate.contains("(")
    }
}
#endif
