#if !PEEK_DISABLED
import Foundation

/// Human-readable reports for sharing. Markdown pastes cleanly into Jira, Slack, GitHub and Notion;
/// plain text is for everything else. Built from stored (already redacted) records only.
public enum ReportStyle: Sendable {
    case markdown
    case plainText
}

extension HTTPRecord {
    /// "POST /v2/driver/location → 200 OK · 184 ms"
    public var summaryLine: String {
        var line = "\(method) \(url.path.isEmpty ? "/" : url.path)"
        if let statusCode {
            line += " → \(statusCode) \(Self.reason(statusCode))"
        } else {
            line += error == nil ? " → pending" : " → failed"
        }
        if let duration { line += " · \(Self.milliseconds(duration)) ms" }
        return line
    }

    /// Request line, headers and body.
    public func requestReport(_ style: ReportStyle) -> String {
        var parts = [section("Request", style), "\(method) \(url.absoluteString)"]
        parts.append(headers(requestHeaders, style))
        if let body = requestBody { parts.append(Self.body(body, style)) }
        return parts.joined(separator: "\n")
    }

    /// Status, headers, body and error.
    public func responseReport(_ style: ReportStyle) -> String {
        var parts = [section("Response", style)]
        parts.append(statusCode.map { "\($0) \(Self.reason($0))" } ?? (error == nil ? "No response yet" : "No response"))
        if !responseHeaders.isEmpty { parts.append(headers(responseHeaders, style)) }
        if let body = responseBody { parts.append(Self.body(body, style)) }
        if let error { parts.append(style == .markdown ? "**Error:** `\(error)`" : "Error: \(error)") }
        return parts.joined(separator: "\n")
    }

    /// Everything about the attempt: summary, timing, request, response, and a cURL to replay it.
    public func report(_ style: ReportStyle) -> String {
        let title = style == .markdown ? "### \(summaryLine)" : summaryLine
        var meta = ["Started: \(Self.timestamp.string(from: startedAt))"]
        if let host = url.host { meta.append("Host: \(host)") }
        if let module { meta.append("Module: \(module)") }
        if let correlationID { meta.append("Call: \(correlationID.uuidString.prefix(8))") }
        if let timing {
            let phases = timing.phases.map { "\($0.name) \(Self.milliseconds($0.interval.duration)) ms" }.joined(separator: " · ")
            meta.append("Timing: \(phases)\(timing.networkProtocol.map { " (\($0)\(timing.isReusedConnection ? ", reused" : ""))" } ?? "")")
        }
        let metaBlock = style == .markdown ? meta.map { "- \($0)" }.joined(separator: "\n") : meta.joined(separator: "\n")
        let curl = style == .markdown ? "**cURL**\n```bash\n\(curlCommand)\n```" : "cURL:\n\(curlCommand)"
        return [title, metaBlock, requestReport(style), responseReport(style), curl, Self.note(style, isRedacted: isRedacted)]
            .joined(separator: "\n\n")
    }

    private func section(_ title: String, _ style: ReportStyle) -> String {
        style == .markdown ? "**\(title)**" : "--- \(title) ---"
    }

    private func headers(_ headers: [String: String], _ style: ReportStyle) -> String {
        let lines = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        guard !lines.isEmpty else { return style == .markdown ? "_No headers_" : "(no headers)" }
        return style == .markdown ? "```http\n\(lines)\n```" : lines
    }

    static func body(_ body: CapturedBody, _ style: ReportStyle) -> String {
        let text = body.displayText ?? "[\(body.originalSize) bytes of binary data]"
        let truncated = body.isTruncated ? "\n(truncated: \(body.data.count) of \(body.originalSize) bytes kept)" : ""
        guard style == .markdown else { return text + truncated }
        let language = (try? JSONSerialization.jsonObject(with: body.data, options: [.fragmentsAllowed])) != nil ? "json" : ""
        return "```\(language)\n\(text)\n```" + truncated
    }

    static func note(_ style: ReportStyle, isRedacted: Bool) -> String {
        let text = isRedacted
            ? "Captured by Peek. Secrets and personal data are redacted."
            : "Captured by Peek with redaction OFF: contains tokens and personal data. Share only with people who may see them."
        return style == .markdown ? (isRedacted ? "_\(text)_" : "> ⚠️ **\(text)**") : text
    }

    static func reason(_ code: Int) -> String {
        code == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }

    static func milliseconds(_ interval: TimeInterval) -> Int { Int((interval * 1_000).rounded()) }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

extension SocketRecord {
    public func report(_ style: ReportStyle) -> String {
        let title = "\(direction.rawValue) \(name)"
        var lines = [style == .markdown ? "### socket.io \(title)" : "socket.io \(title)"]
        let meta = [
            "Time: \(HTTPRecord.timestamp.string(from: date))",
            "Server: \(url?.absoluteString ?? "?")",
            "Namespace: \(namespace)",
        ]
        lines.append(style == .markdown ? meta.map { "- \($0)" }.joined(separator: "\n") : meta.joined(separator: "\n"))
        if let payload { lines.append(HTTPRecord.body(payload, style)) }
        lines.append(HTTPRecord.note(style, isRedacted: isRedacted))
        return lines.joined(separator: "\n\n")
    }
}

extension EventRecord {
    /// One JSON object: what each destination got, plus dropped destinations and warnings.
    public var json: [String: Any] {
        var object: [String: Any] = [
            "name": name,
            "kind": kind.rawValue,
            "time": HTTPRecord.timestamp.string(from: date),
            "deliveries": deliveries.map { delivery in
                ["destination": delivery.destination, "name": delivery.name,
                 "properties": Dictionary(delivery.properties.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { first, _ in first })]
            },
            "redacted": isRedacted,
        ]
        if let source { object["source"] = source }
        if !dropped.isEmpty { object["dropped"] = dropped }
        if !warnings.isEmpty { object["warnings"] = warnings.map { "[\($0.tag)] \($0.message)" } }
        return object
    }

    public var jsonText: String {
        let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public func report(_ style: ReportStyle) -> String {
        var lines = [style == .markdown ? "### Analytics event `\(name)`" : "Analytics event \(name)"]
        let meta = ["Time: \(HTTPRecord.timestamp.string(from: date))", source.map { "Source: \($0)" },
                    "Sent to: \(deliveries.map(\.destination).joined(separator: ", "))",
                    dropped.isEmpty ? nil : "Dropped: \(dropped.joined(separator: ", "))"].compactMap { $0 }
        lines.append(style == .markdown ? meta.map { "- \($0)" }.joined(separator: "\n") : meta.joined(separator: "\n"))
        if !warnings.isEmpty {
            let list = warnings.map { "[\($0.tag)] \($0.message)" }
            lines.append(style == .markdown ? "**Warnings**\n" + list.map { "- \($0)" }.joined(separator: "\n") : "Warnings:\n" + list.joined(separator: "\n"))
        }
        lines.append(style == .markdown ? "```json\n\(jsonText)\n```" : jsonText)
        lines.append(HTTPRecord.note(style, isRedacted: isRedacted))
        return lines.joined(separator: "\n\n")
    }
}

/// Many records as one log, newest first.
public enum TextLog {
    public static func export(_ records: [HTTPRecord], style: ReportStyle) -> String {
        let separator = style == .markdown ? "\n\n---\n\n" : "\n\n========================================\n\n"
        return records.map { $0.report(style) }.joined(separator: separator)
    }

    /// One compact JSON object per line (JSON Lines), for scripts and diffing two sessions.
    public static func jsonLines(_ events: [EventRecord]) -> String {
        events.compactMap { event in
            (try? JSONSerialization.data(withJSONObject: event.json, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) }
        }.joined(separator: "\n")
    }
}
#endif
