#if !PEEK_DISABLED
import Foundation

/// One socket.io message or connection change.
public struct SocketRecord: InspectorRecord {
    public enum Direction: String, Sendable {
        case incoming, outgoing, lifecycle
    }

    public let id: UUID
    public let date: Date
    public var url: URL?
    public let namespace: String
    public let direction: Direction
    public let name: String
    /// JSON array of the event's items (redacted), or their text form when not JSON.
    public var payload: CapturedBody?
    /// True for the stored, redacted copy; false for `revealed()`.
    public var isRedacted: Bool
    /// The real url and payload, in memory only; nil on a revealed copy.
    public var original: (url: URL?, payload: CapturedBody?)?

    public init(
        id: UUID = UUID(), date: Date = Date(), url: URL?, namespace: String, direction: Direction, name: String,
        payload: CapturedBody?, isRedacted: Bool = true, original: (url: URL?, payload: CapturedBody?)? = nil
    ) {
        self.id = id
        self.date = date
        self.url = url
        self.namespace = namespace
        self.direction = direction
        self.name = name
        self.payload = payload
        self.isRedacted = isRedacted
        self.original = original
    }

    public func revealed() -> SocketRecord {
        guard let original else { return self }
        var record = self
        record.url = original.url
        record.payload = original.payload
        record.isRedacted = false
        record.original = nil
        return record
    }

    public func displayed(redacted: Bool) -> SocketRecord { redacted ? self : revealed() }

    public var byteCost: Int { (payload?.data.count ?? 0) + (original?.payload?.data.count ?? 0) }
    public var isFailure: Bool { direction == .lifecycle && name == "error" }
}

/// Redacts and stores socket events off the caller's thread, in order. See `HTTPCapture`.
public struct SocketCapture: Sendable {
    public let store: RecordStore<SocketRecord>
    public let policy: RedactionPolicy
    private let queue = DispatchQueue(label: "dev.peek.socket-capture", qos: .utility)

    public init(store: RecordStore<SocketRecord>, policy: RedactionPolicy = RedactionPolicy()) {
        self.store = store
        self.policy = policy
    }

    public func flush() {
        queue.sync {}
    }

    public func record(
        id: UUID,
        date: Date,
        url: String,
        namespace: String,
        direction: SocketRecord.Direction,
        name: String,
        payload: Data?,
        payloadDescription: String?
    ) {
        guard !store.isPaused else { return }
        let redactor = policy.redactor
        queue.async { [store] in
            let raw = payload ?? payloadDescription.map { Data($0.utf8) }
            let url = URL(string: url)
            store.record(SocketRecord(
                id: id,
                date: date,
                url: url.map(redactor.redact(url:)),
                namespace: namespace,
                direction: direction,
                name: name,
                payload: HTTPCapture.capture(raw, with: redactor),
                original: (url, HTTPCapture.capture(raw))
            ))
        }
    }
}
#endif
