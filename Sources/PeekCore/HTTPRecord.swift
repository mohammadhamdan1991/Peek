#if !PEEK_DISABLED
import Foundation

/// Anything a `RecordStore` can hold.
public protocol InspectorRecord: Sendable, Identifiable where ID == UUID {
    /// Bytes this record keeps alive; counted against the store's byte budget.
    var byteCost: Int { get }
}

/// A request or response body, capped at capture time.
public struct CapturedBody: Sendable, Hashable {
    public static let defaultLimit = 1_048_576 // 1 MB

    public let data: Data
    public let originalSize: Int
    public var isTruncated: Bool { data.count < originalSize }

    public init(_ data: Data, limit: Int = CapturedBody.defaultLimit) {
        originalSize = data.count
        guard data.count > limit else { self.data = data; return }
        // Cut on a UTF-8 character boundary so truncated text still decodes, instead of looking binary.
        var end = data.startIndex + limit
        while end > data.startIndex, data[end] & 0b1100_0000 == 0b1000_0000 { end -= 1 }
        // subdata copies, so a 50 MB response doesn't stay alive behind a 1 MB slice.
        self.data = data.subdata(in: data.startIndex..<end)
    }
}

public struct HTTPRecord: InspectorRecord {
    public let id: UUID
    /// Shared by every attempt (retries, 401 refresh) of one logical call.
    public var correlationID: UUID?
    public let startedAt: Date
    /// Which feature made the call ("Checkout", "Payments SDK", ...).
    public var module: String?
    public var method: String
    public var url: URL
    public var requestHeaders: [String: String]
    public var requestBody: CapturedBody?
    public var statusCode: Int?
    public var responseHeaders: [String: String]
    public var responseBody: CapturedBody?
    public var error: String?
    public var duration: TimeInterval?
    public var timing: HTTPTiming?
    /// True for the stored, redacted copy; false for `revealed()`, which holds real tokens and personal data.
    public var isRedacted: Bool
    /// The real values behind the redacted ones. In memory only; nil on a revealed copy.
    public var original: Original?

    /// What was actually sent and received, before redaction.
    public struct Original: Sendable {
        public var url: URL
        public var requestHeaders: [String: String]
        public var requestBody: CapturedBody?
        public var responseHeaders: [String: String] = [:]
        public var responseBody: CapturedBody?
        public var error: String?
    }

    public init(
        id: UUID = UUID(),
        correlationID: UUID? = nil,
        startedAt: Date = Date(),
        module: String? = nil,
        method: String,
        url: URL,
        requestHeaders: [String: String] = [:],
        requestBody: CapturedBody? = nil,
        statusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: CapturedBody? = nil,
        error: String? = nil,
        duration: TimeInterval? = nil,
        isRedacted: Bool = true,
        original: Original? = nil
    ) {
        self.id = id
        self.correlationID = correlationID
        self.startedAt = startedAt
        self.module = module
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.error = error
        self.duration = duration
        self.isRedacted = isRedacted
        self.original = original
    }

    /// This record with its real values: tokens, credentials and personal data included.
    public func revealed() -> HTTPRecord {
        guard let original else { return self }
        var record = self
        record.url = original.url
        record.requestHeaders = original.requestHeaders
        record.requestBody = original.requestBody
        record.responseHeaders = original.responseHeaders
        record.responseBody = original.responseBody
        record.error = original.error
        record.isRedacted = false
        record.original = nil
        return record
    }

    public func displayed(redacted: Bool) -> HTTPRecord { redacted ? self : revealed() }

    /// The part of the path that tells similar requests apart, for one-line rows: the last two segments,
    /// e.g. `…/new_projects_overview/entries` for `/api/v1/cms/collections/new_projects_overview/entries`.
    public var shortPath: String {
        let segments = url.path.split(separator: "/")
        guard segments.count > 2 else { return url.path.isEmpty ? "/" : url.path }
        return "…/" + segments.suffix(2).joined(separator: "/")
    }

    public var byteCost: Int {
        [requestBody, responseBody, original?.requestBody, original?.responseBody].reduce(0) { $0 + ($1?.data.count ?? 0) }
    }
    /// A response, or a failure, has arrived.
    public var isComplete: Bool { statusCode != nil || error != nil }
    public var isFailure: Bool { error != nil || (statusCode ?? 0) >= 400 }
}

/// Where an attempt's time went, from `URLSessionTaskMetrics`. Phases are in wire order and may overlap
/// (TLS happens inside connect).
public struct HTTPTiming: Sendable, Hashable {
    public struct Phase: Sendable, Hashable {
        public let name: String
        public let interval: DateInterval
    }

    public var phases: [Phase]
    public var networkProtocol: String?
    public var isReusedConnection: Bool

    public init(
        domainLookup: DateInterval?,
        connect: DateInterval?,
        secureConnection: DateInterval?,
        request: DateInterval?,
        response: DateInterval?,
        networkProtocol: String?,
        isReusedConnection: Bool
    ) {
        var waiting: DateInterval?
        if let request, let response, response.start >= request.end {
            waiting = DateInterval(start: request.end, end: response.start)
        }
        phases = [
            ("DNS", domainLookup), ("Connect", connect), ("TLS", secureConnection),
            ("Request", request), ("Waiting", waiting), ("Response", response),
        ].compactMap { name, interval in interval.map { Phase(name: name, interval: $0) } }
        self.networkProtocol = networkProtocol
        self.isReusedConnection = isReusedConnection
    }

    public var total: DateInterval? {
        guard let start = phases.map(\.interval.start).min(), let end = phases.map(\.interval.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }
}
#endif
