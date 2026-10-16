#if !PEEK_DISABLED
import Foundation

/// A JSON body as indented, collapsible lines for the tree viewer. Built once per body, outside view `body`.
public struct JSONTree: Sendable {
    public enum Kind: Sendable { case object, array, string, number, bool, null }

    public struct Line: Sendable, Identifiable, Hashable {
        /// Path from the root, e.g. `$.driver.trips[0]`; also the collapse key.
        public let id: String
        public let depth: Int
        public let key: String?
        public let kind: Kind
        /// Leaf: the printable value. Container: its size, e.g. "{ 4 keys }".
        public let value: String
        public let childCount: Int
        public var isContainer: Bool { kind == .object || kind == .array }
    }

    public let lines: [Line]

    /// Nil when `data` isn't JSON.
    public init?(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        var lines: [Line] = []
        Self.walk(root, key: nil, path: "$", depth: 0, into: &lines)
        self.lines = lines
    }

    /// Lines to show when the containers in `collapsed` are folded.
    public func visibleLines(collapsed: Set<String>) -> [Line] {
        guard !collapsed.isEmpty else { return lines }
        var visible: [Line] = []
        var hiddenBelow: Int?
        for line in lines {
            if let depth = hiddenBelow {
                if line.depth > depth { continue }
                hiddenBelow = nil
            }
            visible.append(line)
            if line.isContainer, collapsed.contains(line.id) { hiddenBelow = line.depth }
        }
        return visible
    }

    /// `.name`, or `["a.b"]` when the key isn't a plain identifier, so `{"a.b":1}` and `{"a":{"b":1}}` get distinct ids.
    private static func member(_ key: String) -> String {
        let isPlain = !key.isEmpty && !key.first!.isNumber && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard !isPlain else { return "." + key }
        return "[\"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"]"
    }

    private static func walk(_ value: Any, key: String?, path: String, depth: Int, into lines: inout [Line]) {
        switch value {
        case let object as [String: Any]:
            lines.append(Line(id: path, depth: depth, key: key, kind: .object,
                              value: "{ \(object.count) \(object.count == 1 ? "key" : "keys") }", childCount: object.count))
            for (childKey, child) in object.sorted(by: { $0.key < $1.key }) {
                walk(child, key: childKey, path: path + member(childKey), depth: depth + 1, into: &lines)
            }
        case let array as [Any]:
            lines.append(Line(id: path, depth: depth, key: key, kind: .array,
                              value: "[ \(array.count) \(array.count == 1 ? "item" : "items") ]", childCount: array.count))
            for (index, child) in array.enumerated() {
                walk(child, key: "\(index)", path: "\(path)[\(index)]", depth: depth + 1, into: &lines)
            }
        case let string as String:
            lines.append(Line(id: path, depth: depth, key: key, kind: .string, value: "\"\(string)\"", childCount: 0))
        case let number as NSNumber:
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            lines.append(Line(id: path, depth: depth, key: key, kind: isBool ? .bool : .number,
                              value: isBool ? (number.boolValue ? "true" : "false") : number.stringValue, childCount: 0))
        default:
            lines.append(Line(id: path, depth: depth, key: key, kind: .null, value: "null", childCount: 0))
        }
    }
}

extension CapturedBody {
    /// Pretty-printed JSON, else UTF-8 text, else nil (binary).
    public var displayText: String? {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(data: data, encoding: .utf8)
    }
}
#endif
