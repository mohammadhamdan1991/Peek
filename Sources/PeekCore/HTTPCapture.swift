#if !PEEK_DISABLED
import Foundation

/// Turns per-attempt network events into one `HTTPRecord` each, redacted per `policy` with the real values kept
/// alongside (see `RedactionPolicy`); events for an attempt merge by `id`.
///
/// Callable from any thread. The caller (a networking callback) only pays for an enqueue: redaction and
/// storage run on a private serial queue, so request completion is never delayed and event order is kept.
public struct HTTPCapture: Sendable {
    /// Bodies above this are not parsed for redaction; they're replaced by a size note instead of risking a leak.
    // ponytail: 5 MB covers every API payload; stream-redact if large JSON bodies ever need inspecting.
    static let redactableLimit = 5 * 1_048_576

    public let store: RecordStore<HTTPRecord>
    public let policy: RedactionPolicy
    private let queue = DispatchQueue(label: "dev.peek.capture", qos: .utility)

    public init(store: RecordStore<HTTPRecord>, policy: RedactionPolicy = RedactionPolicy()) {
        self.store = store
        self.policy = policy
    }

    /// Blocks until every event handed over so far is stored. For tests and exports.
    public func flush() {
        queue.sync {}
    }

    public func started(
        id: UUID,
        correlationID: UUID?,
        startedAt: Date,
        method: String,
        url: URL,
        headers: [String: String]?,
        body: Data?,
        module: String? = nil
    ) {
        guard !store.isPaused else { return }
        let redactor = policy.redactor // the rules when the event happens, not when the queue gets to it
        queue.async { [store] in
            store.record(HTTPRecord(
                id: id,
                correlationID: correlationID,
                startedAt: startedAt,
                module: module,
                method: method,
                url: redactor.redact(url: url),
                requestHeaders: redactor.redact(headers: headers ?? [:]),
                requestBody: Self.capture(body, with: redactor),
                original: .init(url: url, requestHeaders: headers ?? [:], requestBody: Self.capture(body))
            ))
        }
    }

    /// A response or a failure. Fields left `nil` keep what an earlier event set, so a decoding error
    /// reported after the response adds the error without dropping the status or body.
    public func finished(
        id: UUID,
        correlationID: UUID?,
        method: String,
        url: URL?,
        statusCode: Int?,
        headers: [String: String]?,
        body: Data?,
        error: String?,
        duration: TimeInterval?
    ) {
        // Not gated on pause: an attempt captured before pausing still gets its response (the store drops new ones).
        let redactor = policy.redactor
        let finishedAt = Date()
        queue.async { [store] in
            let rawHeaders = headers, rawBody = Self.capture(body), rawError = error
            let headers = headers.map(redactor.redact(headers:))
            let body = Self.capture(body, with: redactor)
            let error = error.map(redactor.redact(text:))
            let found = store.update(id: id) { record in
                record.statusCode = statusCode ?? record.statusCode
                record.responseHeaders = headers ?? record.responseHeaders
                record.responseBody = body ?? record.responseBody
                record.error = error ?? record.error
                record.duration = duration ?? record.duration
                if var original = record.original {
                    original.responseHeaders = rawHeaders ?? original.responseHeaders
                    original.responseBody = rawBody ?? original.responseBody
                    original.error = rawError ?? original.error
                    record.original = original
                }
            }
            // A failure before anything went on the wire (encoding, interceptors) has no started event.
            // A success with no record was cleared or evicted mid-flight: don't bring back half of it.
            guard !found, error != nil, let url else { return }
            store.record(HTTPRecord(
                id: id,
                correlationID: correlationID,
                startedAt: finishedAt.addingTimeInterval(-(duration ?? 0)),
                method: method,
                url: redactor.redact(url: url),
                statusCode: statusCode,
                responseHeaders: headers ?? [:],
                responseBody: body,
                error: error,
                duration: duration,
                original: .init(url: url, requestHeaders: [:], requestBody: nil, responseHeaders: rawHeaders ?? [:],
                                responseBody: rawBody, error: rawError)
            ))
        }
    }

    public func timing(id: UUID, _ timing: HTTPTiming) {
        queue.async { [store] in store.update(id: id) { $0.timing = timing } }
    }

    /// The body as sent, capped like any captured body.
    static func capture(_ data: Data?) -> CapturedBody? {
        guard let data, !data.isEmpty else { return nil }
        return CapturedBody(data)
    }

    static func capture(_ data: Data?, with redactor: Redactor) -> CapturedBody? {
        guard let data, !data.isEmpty else { return nil }
        guard data.count <= redactableLimit else {
            return CapturedBody(Data("[\(data.count) bytes — too large to redact, not kept]".utf8))
        }
        return CapturedBody(redactor.redact(body: data))
    }
}
#endif
