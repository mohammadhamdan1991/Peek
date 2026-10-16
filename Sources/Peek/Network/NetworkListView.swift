#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

struct NetworkListView: View {
    @StateObject private var model = NetworkListModel(store: Inspector.http, socketStore: Inspector.sockets)

    var body: some View {
        List {
            Section {
                header.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            .listRowBackground(Theme.ground)
            .listRowSeparator(.hidden)

            ForEach(model.items) { item in
                Group {
                    switch item {
                    case let .http(record):
                        NavigationLink {
                            NetworkDetailView(model: model, id: record.id)
                        } label: {
                            RequestRow(record: record)
                        }
                        .contextMenu { RequestActions(record: record) }
                        .listRowBackground(record.isFailure ? Theme.failure.opacity(0.05) : Theme.ground)
                    case let .socket(record):
                        NavigationLink {
                            SocketDetailView(model: model, id: record.id)
                        } label: {
                            SocketRow(record: record)
                        }
                        .contextMenu { SocketActions(record: record) }
                        .listRowBackground(record.direction == .lifecycle ? Theme.clientError.opacity(0.04) : Theme.ground)
                    case let .event(event):
                        NavigationLink {
                            EventDetailView(event: event)
                        } label: {
                            EventRow(event: event)
                        }
                        .contextMenu { EventActions(event: event) }
                        .listRowBackground(event.hasWarnings ? Theme.clientError.opacity(0.05) : Theme.event.opacity(0.04))
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12)) // room for the disclosure chevron
                .listRowSeparatorTint(Theme.hairline)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .overlay { if model.items.isEmpty { emptyState } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Exports what's on screen: the current search and filters apply.
                Menu {
                    let count = model.visible.count
                    Section("\(count) request\(count == 1 ? "" : "s") on screen") {
                        Button { Share.file(HAR.export(model.visible), named: "Requests.har") } label: {
                            Label("Share as HAR (Proxyman, Charles, Chrome)", systemImage: "doc.zipper")
                        }
                        Button { Share.file(Data(TextLog.export(model.visible, style: .markdown).utf8), named: "Requests.md") } label: {
                            Label("Share as Markdown log", systemImage: "doc.richtext")
                        }
                        Button { Share.text(TextLog.export(model.visible, style: .plainText)) } label: {
                            Label("Share as plain text", systemImage: "doc.plaintext")
                        }
                        Button { Share.copy(TextLog.export(model.visible, style: .markdown), what: "\(count) requests") } label: {
                            Label("Copy as Markdown", systemImage: "doc.on.doc")
                        }
                        Button { Share.copy(model.visible.map(\.url.absoluteString).joined(separator: "\n"), what: "URLs") } label: {
                            Label("Copy URLs", systemImage: "link")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.visible.isEmpty || model.kind == .socket) // exports are HTTP; sockets share per message
                .accessibilityLabel("Export requests")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatTile(title: "Requests", value: "\(model.all.count)")
                StatTile(title: "Failed", value: "\(model.failureCount)", color: model.failureCount > 0 ? Theme.failureText : Theme.text)
                StatTile(title: "Median", value: model.medianDuration.map(Format.duration) ?? "—")
            }
            SearchField(text: $model.searchText, tokens: model.query.tokens)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "All", isOn: !model.errorsOnly && model.module == nil && model.kind == .all) {
                        model.errorsOnly = false
                        model.module = nil
                        model.kind = .all
                    }
                    Chip(title: "Errors · \(model.failureCount)", isOn: model.errorsOnly) { model.errorsOnly.toggle() }
                    Chip(title: "HTTP", isOn: model.kind == .http) { model.kind = model.kind == .http ? .all : .http }
                    if !model.sockets.isEmpty {
                        Chip(title: "Socket · \(model.sockets.count)", isOn: model.kind == .socket) {
                            model.kind = model.kind == .socket ? .all : .socket
                        }
                    }
                    if !model.events.isEmpty {
                        Chip(title: "+ Events", isOn: model.showsEvents) { model.showsEvents.toggle() }
                            .accessibilityHint("Mixes analytics events into the list, in time order")
                    }
                    ForEach(model.modules, id: \.self) { module in
                        Chip(title: module, isOn: model.module == module) {
                            model.module = model.module == module ? nil : module
                        }
                    }
                }
            }
            if model.kind == .socket {
                ForEach(model.connections) { ConnectionCard(connection: $0) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            let nothingYet = model.all.isEmpty && model.sockets.isEmpty
            Image(systemName: nothingYet ? "antenna.radiowaves.left.and.right" : "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiaryText)
            Text(nothingYet ? "No traffic yet" : "Nothing matches")
                .foregroundStyle(Theme.secondaryText)
            if model.all.isEmpty, model.store.isPaused {
                Text("Capture is paused").font(.footnote).foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.top, 220)
        .allowsHitTesting(false)
    }
}

struct RequestRow: View {
    let record: HTTPRecord

    var body: some View {
        let status = StatusClass(record)
        HStack(spacing: 12) {
            Rectangle().fill(Theme.color(for: status)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    MethodChip(method: record.method)
                    Text(record.shortPath)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.head) // the end of a path is what tells requests apart
                }
                Text([record.url.host, record.module].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.status(record))
                    .font(.system(.footnote, design: .monospaced).weight(.medium))
                    .foregroundStyle(Theme.color(for: status))
                Text(Format.meta(record))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.trailing, 4)
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Small pieces

struct MethodChip: View {
    let method: String

    var body: some View {
        Text(method.uppercased())
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Theme.color(forMethod: method))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var color: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.tertiaryText)
            Text(value).font(.system(.headline, design: .monospaced)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .foregroundStyle(isOn ? Theme.ground : Theme.text)
                .background(isOn ? Theme.text : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Theme.text : Theme.hairline))
                .padding(.vertical, 6) // 44 pt tap target around the 32 pt capsule
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct SearchField: View {
    @Binding var text: String
    var tokens: [NetworkQuery.Token] = []
    var prompt = "Search, or status:5xx host: method: module:"
    var label = "Search requests"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                TextField("", text: $text, prompt: Text(prompt).foregroundColor(Theme.tertiaryText))
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(label)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))

            if !tokens.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tokens, id: \.self) { token in
                        Text("\(token.key):\(token.value)")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}

enum Format {
    static func duration(_ interval: TimeInterval) -> String {
        interval < 1 ? "\(Int((interval * 1_000).rounded())) ms" : String(format: "%.1f s", interval)
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1_000 ? "\(bytes) B" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "200 OK", "404 Not Found" (Foundation calls 200 "no error").
    static func statusLine(_ code: Int) -> String {
        "\(code) " + (code == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: code).capitalized)
    }

    static func status(_ record: HTTPRecord) -> String {
        if let code = record.statusCode { return record.error == nil ? "\(code)" : "\(code) ✗" }
        return record.error == nil ? "…" : "failed"
    }

    static func meta(_ record: HTTPRecord) -> String {
        var parts: [String] = []
        if let seconds = record.duration { parts.append(duration(seconds)) }
        if let body = record.responseBody { parts.append(size(body.originalSize)) }
        parts.append(age(record.startedAt))
        return parts.joined(separator: " · ")
    }

    /// "now" for the last few seconds (avoids "in 0 sec" from clock jitter), then "12 sec ago", "3 min ago".
    static func age(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 5 ? "now" : date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }
}
#endif
