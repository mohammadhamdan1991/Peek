#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import UIKit
import PeekCore

/// A captured body: JSON as a collapsible tree (or raw), images as a preview, other text as text.
/// Parsing runs off the main thread, once per body.
struct BodyView: View {
    let captured: CapturedBody?

    @State private var parsed: Parsed?
    @State private var showsRaw = false
    @State private var collapsed: Set<String> = []

    private struct Parsed {
        let tree: JSONTree?
        let text: String?
        let image: UIImage?
    }

    var body: some View {
        Group {
            if let body = captured {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Format.size(body.originalSize) + (body.isTruncated ? " · truncated to \(Format.size(body.data.count))" : ""))
                            .font(.caption)
                            .foregroundStyle(body.isTruncated ? Theme.clientError : Theme.tertiaryText)
                        Spacer()
                        if parsed?.tree != nil {
                            Picker("View", selection: $showsRaw) {
                                Text("Tree").tag(false)
                                Text("Raw").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 130)
                        }
                    }
                    viewer
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.code, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                }
                .task(id: body) {
                    parsed = nil
                    collapsed = []
                    let result = await Task.detached(priority: .userInitiated) {
                        Parsed(tree: JSONTree(body.data), text: body.displayText, image: UIImage(data: body.data))
                    }.value
                    guard !Task.isCancelled else { return } // the body changed meanwhile; its own task fills in
                    parsed = result
                }
            } else {
                Text("No body").font(.footnote).foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    @ViewBuilder private var viewer: some View {
        if let parsed {
            if let image = parsed.image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280)
            } else if let tree = parsed.tree, !showsRaw {
                JSONTreeView(lines: tree.visibleLines(collapsed: collapsed), collapsed: $collapsed)
            } else if let text = parsed.text {
                Text(text)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .contextMenu { Button("Copy") { Share.copy(text, what: "body") } }
            } else {
                Text("Binary data").font(.footnote).foregroundStyle(Theme.tertiaryText)
            }
        } else {
            ProgressView().tint(Theme.secondaryText)
        }
    }
}

private struct JSONTreeView: View {
    let lines: [JSONTree.Line]
    @Binding var collapsed: Set<String>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                row(line)
            }
        }
    }

    private func row(_ line: JSONTree.Line) -> some View {
        let isCollapsed = collapsed.contains(line.id)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if line.isContainer {
                Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            if let key = line.key {
                Text(key + ":").foregroundStyle(Theme.accent)
            }
            Text(line.value)
                .foregroundStyle(color(line.kind))
                .lineLimit(line.isContainer ? 1 : nil)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.leading, CGFloat(line.depth) * 14)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard line.isContainer else { return }
            if isCollapsed { collapsed.remove(line.id) } else { collapsed.insert(line.id) }
        }
        .contextMenu {
            Button("Copy value") { Share.copy(line.value, what: "value") }
            Button("Copy path") { Share.copy(line.id, what: "path") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(line.isContainer ? .isButton : [])
        .accessibilityHint(line.isContainer ? (isCollapsed ? "Double-tap to expand" : "Double-tap to collapse") : "")
    }

    private func color(_ kind: JSONTree.Kind) -> Color {
        switch kind {
        case .object, .array: Theme.tertiaryText
        case .string: Theme.success
        case .number: Theme.clientError
        case .bool: Theme.redirect
        case .null: Theme.failureText
        }
    }
}
#endif
