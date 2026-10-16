#if !PEEK_DISABLED
import Foundation

/// Strips secrets and personal data before anything is stored, so the UI and every export only ever see redacted data.
/// Best-effort: it masks known header names, key patterns and token shapes, not every secret an API could invent.
public struct Redactor: Sendable {
    public static let mask = "••• redacted"

    /// Header name patterns, matched like `keys` (`*token*` catches `X-Auth-Token`).
    public var headers: [String]
    /// Query-item and JSON key patterns. Matching ignores case, `_` and `-`
    /// (`access_token` == `accessToken`); a leading or trailing `*` is a wildcard.
    public var keys: [String]
    public var redactsPhoneNumbers: Bool
    public var redactsEmails: Bool

    public init(headers: [String], keys: [String], redactsPhoneNumbers: Bool = true, redactsEmails: Bool = true) {
        self.headers = headers.map(Self.normalize)
        self.keys = keys.map(Self.normalize)
        self.redactsPhoneNumbers = redactsPhoneNumbers
        self.redactsEmails = redactsEmails
    }

    public static let `default` = Redactor(
        headers: ["*authorization", "cookie", "set-cookie", "*apikey", "x-app-check", "*token*", "*secret*", "*session*", "*signature"],
        keys: ["*token*", "*secret*", "*password*", "*apikey", "authorization", "otp", "pin", "card*", "cvv", "iban", "*signature"]
    )

    public func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, header in
            result[header.key] = Self.matches(header.key, patterns: self.headers) ? Self.mask : redact(text: header.value)
        }
    }

    public func redact(url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.contains(where: { isSensitive(key: $0.name) })
        else { return url }
        components.queryItems = items.map { isSensitive(key: $0.name) ? URLQueryItem(name: $0.name, value: Self.mask) : $0 }
        return components.url ?? url
    }

    /// JSON bodies are redacted key by key; other UTF-8 bodies get the text patterns; binary passes through.
    public func redact(body: Data) -> Data {
        if let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
            var verdicts: [String: Bool] = [:] // API payloads repeat the same keys hundreds of times
            if let redacted = try? JSONSerialization.data(
                withJSONObject: redact(json: json, verdicts: &verdicts),
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
            ) {
                return redacted
            }
        }
        guard let text = String(data: body, encoding: .utf8) else { return body }
        if let form = redact(form: text) { return Data(form.utf8) }
        return Data(redact(text: text).utf8)
    }

    public func isSensitive(key: String) -> Bool {
        Self.matches(key, patterns: keys)
    }

    private static func matches(_ name: String, patterns: [String]) -> Bool {
        let key = normalize(name)
        return patterns.contains { pattern in
            switch (pattern.hasPrefix("*"), pattern.hasSuffix("*")) {
            case (true, true): key.contains(pattern.dropFirst().dropLast())
            case (true, false): key.hasSuffix(pattern.dropFirst())
            case (false, true): key.hasPrefix(pattern.dropLast())
            case (false, false): key == pattern
            }
        }
    }

    private func redact(json: Any, verdicts: inout [String: Bool]) -> Any {
        switch json {
        case let object as [String: Any]:
            var result = [String: Any](minimumCapacity: object.count)
            for (key, value) in object {
                let sensitive = verdicts[key] ?? {
                    let verdict = isSensitive(key: key)
                    verdicts[key] = verdict
                    return verdict
                }()
                result[key] = sensitive ? Self.mask : redact(json: value, verdicts: &verdicts)
            }
            return result
        case let array as [Any]:
            return array.map { redact(json: $0, verdicts: &verdicts) }
        case let string as String:
            return redact(text: string)
        default:
            return json
        }
    }

    /// `a=1&token=x`: masks sensitive keys like query items. Nil when the text isn't a form.
    private func redact(form text: String) -> String? {
        guard text.contains("="), !text.contains(where: \.isWhitespace),
              let items = URLComponents(string: "?" + text)?.queryItems, !items.isEmpty
        else { return nil }
        var components = URLComponents()
        components.queryItems = items.map {
            URLQueryItem(name: $0.name, value: isSensitive(key: $0.name) ? Self.mask : $0.value.map(redact(text:)))
        }
        return components.percentEncodedQuery
    }

    /// Masks token shapes (Bearer, JWT), emails and phone numbers in free text: string values, header values,
    /// error messages, socket payloads. Runs for every JSON string, so it must stay cheap: cached regexes, and
    /// quick prechecks that skip the (common) strings that can't contain a match.
    public func redact(text: String) -> String {
        var text = text
        if text.contains("eyJ") || text.range(of: "bearer", options: .caseInsensitive) != nil {
            text = Self.replace(Self.token, in: text, with: Self.mask)
        }
        if redactsEmails, text.utf8.contains(UInt8(ascii: "@")) {
            text = Self.replace(Self.email, in: text, with: "••• email")
        }
        if redactsPhoneNumbers, text.utf8.lazy.filter({ (48...57).contains($0) }).count >= 9 {
            text = Self.replace(Self.phone, in: text, with: "••• phone")
        }
        return text
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // NSRegularExpression is immutable and documented thread-safe once built.
    nonisolated(unsafe) private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: .caseInsensitive
    )
    nonisolated(unsafe) private static let token = try! NSRegularExpression(
        pattern: #"(?<=bearer )[\w.~+/=-]+|eyJ[\w-]+\.[\w-]+(?:\.[\w-]*)?"#, options: .caseInsensitive
    )
    // ponytail: heuristic — "+" international numbers, or 10-digit local numbers starting with 0 (DZ/MA/TN).
    // Bare digit runs are left alone so ids and timestamps survive; tighten per market if numbers leak.
    nonisolated(unsafe) private static let phone = try! NSRegularExpression(
        pattern: #"(?<![\w+])(?:\+\d{1,3}(?:[\s-]?\d){8,11}|0\d(?:[\s-]?\d){8})(?!\d)"#
    )

    /// ASCII-lowercased with `_` and `-` removed, in one pass (Foundation's string APIs were the hot spot).
    private static func normalize(_ key: String) -> String {
        String(decoding: key.utf8.compactMap { byte -> UInt8? in
            switch byte {
            case UInt8(ascii: "_"), UInt8(ascii: "-"): nil
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): byte + 32
            default: byte
            }
        }, as: UTF8.self)
    }
}
#endif
