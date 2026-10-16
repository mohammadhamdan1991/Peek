#if !PEEK_DISABLED
import Foundation

// Exports only ever see stored records, which are redacted at capture time.

extension HTTPRecord {
    /// A shell-safe cURL command. Redacted secrets stay redacted, so auth headers must be re-added to replay.
    public var curlCommand: String {
        var lines = ["curl -X \(method) \(Self.shellQuote(url.absoluteString))"]
        for (name, value) in requestHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("-H \(Self.shellQuote("\(name): \(value)"))")
        }
        if let body = requestBody {
            if body.isTruncated {
                lines.append("# body truncated to \(body.data.count) of \(body.originalSize) bytes: this replay sends less")
            }
            if let text = String(data: body.data, encoding: .utf8) {
                lines.append("--data-raw \(Self.shellQuote(text))")
            } else {
                lines.append("# binary body (\(body.originalSize) bytes) not included")
            }
        }
        return lines.joined(separator: " \\\n  ")
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// HTTP Archive 1.2 (opens in Charles, Proxyman, browser dev tools).
public enum HAR {
    public static func export(_ records: [HTTPRecord]) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: Any]] = records.map { record in
            var request: [String: Any] = [
                "method": record.method,
                "url": record.url.absoluteString,
                "httpVersion": httpVersion(record),
                "headers": headers(record.requestHeaders),
                "queryString": (URLComponents(url: record.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    .map { ["name": $0.name, "value": $0.value ?? ""] },
                "headersSize": -1,
                "bodySize": record.requestBody?.originalSize ?? 0,
            ]
            // Only JSON-safe values: JSONSerialization raises an ObjC exception (a crash) on anything else.
            if let body = record.requestBody {
                request["postData"] = ["mimeType": mimeType(record.requestHeaders), "text": text(body)]
            }
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: record.startedAt),
                "time": max(milliseconds(record.duration), 0),
                "request": request,
                "response": [
                    "status": record.statusCode ?? 0,
                    "statusText": record.statusCode.map(HTTPURLResponse.localizedString(forStatusCode:)) ?? "",
                    "httpVersion": httpVersion(record),
                    "headers": headers(record.responseHeaders),
                    "content": content(record.responseBody, mimeType: mimeType(record.responseHeaders)),
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": record.responseBody?.originalSize ?? 0,
                ],
                "cache": [String: Any](),
                "timings": timings(record.timing),
            ]
            if let error = record.error { entry["_error"] = error } // HAR custom fields start with "_"
            return entry
        }
        let log: [String: Any] = ["log": [
            "version": "1.2",
            "creator": ["name": "Peek", "version": "1"],
            "entries": entries,
        ]]
        return (try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private static func headers(_ headers: [String: String]) -> [[String: String]] {
        headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
    }

    private static func content(_ body: CapturedBody?, mimeType: String) -> [String: Any] {
        guard let body else { return ["size": 0, "mimeType": mimeType] }
        var content: [String: Any] = ["size": body.originalSize, "mimeType": mimeType, "text": text(body)]
        if String(data: body.data, encoding: .utf8) == nil { content["encoding"] = "base64" }
        if body.isTruncated { content["comment"] = "truncated to \(body.data.count) of \(body.originalSize) bytes" }
        return content
    }

    private static func text(_ body: CapturedBody) -> String {
        String(data: body.data, encoding: .utf8) ?? body.data.base64EncodedString()
    }

    private static func mimeType(_ headers: [String: String]) -> String {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? ""
    }

    /// URLSession reports ALPN ids ("h2", "http/1.1"); HAR viewers expect "HTTP/2", "HTTP/1.1".
    private static func httpVersion(_ record: HTTPRecord) -> String {
        switch record.timing?.networkProtocol?.lowercased() {
        case "h2": "HTTP/2"
        case "h3": "HTTP/3"
        case let alpn?: alpn.uppercased()
        case nil: "HTTP/1.1"
        }
    }

    private static func milliseconds(_ interval: TimeInterval?) -> Double {
        interval.map { ($0 * 1_000).rounded() } ?? -1
    }

    private static func timings(_ timing: HTTPTiming?) -> [String: Double] {
        func ms(_ name: String) -> Double { milliseconds(timing?.phases.first { $0.name == name }?.interval.duration) }
        return ["blocked": -1, "dns": ms("DNS"), "connect": ms("Connect"), "ssl": ms("TLS"),
                "send": max(ms("Request"), 0), "wait": max(ms("Waiting"), 0), "receive": max(ms("Response"), 0)]
    }
}
#endif
