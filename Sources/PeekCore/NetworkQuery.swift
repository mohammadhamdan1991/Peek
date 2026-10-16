#if !PEEK_DISABLED
import Foundation

/// The network list's search: `key:value` tokens plus free text.
///
/// Tokens: `status:5xx` / `status:404` / `status:failed`, `host:api`, `method:post`, `module:checkout`.
/// Free text matches the URL, the error and both bodies.
public struct NetworkQuery: Sendable, Equatable {
    public struct Token: Sendable, Equatable, Hashable {
        public let key: String
        public let value: String
    }

    public static let keys: Set<String> = ["status", "host", "method", "module"]

    public private(set) var tokens: [Token] = []
    public private(set) var text = ""
    public var errorsOnly = false

    public init(_ raw: String = "", errorsOnly: Bool = false) {
        self.errorsOnly = errorsOnly
        var words: [Substring] = []
        for word in raw.split(whereSeparator: \.isWhitespace) {
            let parts = word.split(separator: ":", maxSplits: 1)
            if parts.count == 2, Self.keys.contains(parts[0].lowercased()), !parts[1].isEmpty {
                tokens.append(Token(key: parts[0].lowercased(), value: String(parts[1]).lowercased()))
            } else {
                words.append(word)
            }
        }
        text = words.joined(separator: " ").lowercased()
    }

    public var isEmpty: Bool { tokens.isEmpty && text.isEmpty && !errorsOnly }

    public func matches(_ record: HTTPRecord) -> Bool {
        if errorsOnly, !record.isFailure { return false }
        for token in tokens where !matches(token, record) { return false }
        guard !text.isEmpty else { return true }
        if record.url.absoluteString.lowercased().contains(text) || (record.error?.lowercased().contains(text) ?? false) {
            return true
        }
        // ponytail: decodes bodies per search; 3+ characters keeps it cheap at 1k records, index at capture if it lags.
        return text.count >= 3 && (Self.contains(text, record.requestBody) || Self.contains(text, record.responseBody))
    }

    /// Sockets answer `host:`, `method:ws` and free text (event name, payload); `status:` and `module:` exclude them.
    public func matches(_ record: SocketRecord) -> Bool {
        if errorsOnly, !record.isFailure { return false }
        for token in tokens {
            switch token.key {
            case "host": guard record.url?.host?.lowercased().contains(token.value) ?? false else { return false }
            case "method": guard token.value == "ws" else { return false }
            default: return false
            }
        }
        guard !text.isEmpty else { return true }
        return record.name.lowercased().contains(text)
            || record.namespace.lowercased().contains(text)
            || Self.contains(text, record.payload)
    }

    private func matches(_ token: Token, _ record: HTTPRecord) -> Bool {
        switch token.key {
        case "status":
            switch token.value {
            case "failed", "error": return record.error != nil
            case let value where value.count == 3 && value.hasSuffix("xx"):
                guard let first = value.first?.wholeNumberValue, let code = record.statusCode else { return false }
                return code / 100 == first
            default:
                return record.statusCode.map(String.init) == token.value
            }
        case "host": return record.url.host?.lowercased().contains(token.value) ?? false
        case "method": return record.method.lowercased() == token.value
        // Modules have spaces ("Ride SDK"): `module:ride_sdk` or `module:ridesdk` both match.
        case "module": return record.module.map { Self.squash($0) == Self.squash(token.value) } ?? false
        default: return true
        }
    }

    private static func squash(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func contains(_ text: String, _ body: CapturedBody?) -> Bool {
        guard let body, let string = String(data: body.data, encoding: .utf8) else { return false }
        return string.range(of: text, options: .caseInsensitive) != nil
    }
}

public enum StatusClass: Sendable {
    case pending, success, redirect, clientError, serverError, failed

    public init(_ record: HTTPRecord) {
        switch (record.statusCode, record.error) {
        case (nil, nil): self = .pending
        case (nil, _): self = .failed
        case let (code?, _):
            switch code {
            case ..<300: self = record.error == nil ? .success : .failed
            case 300..<400: self = .redirect
            case 400..<500: self = .clientError
            default: self = .serverError
            }
        }
    }
}
#endif
