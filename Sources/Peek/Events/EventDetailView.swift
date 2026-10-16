#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

/// One event: what each destination got, what's wrong, and the network calls around it.
struct EventDetailView: View {
    let event: EventRecord

    /// A destination that was sent to, or one that was dropped.
    @State private var selection: String?
    @StateObject private var network = NetworkListModel(store: Inspector.http, socketStore: Inspector.sockets)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                destinations
                if event.hasWarnings { warnings }
                properties
                nearby
            }
            .padding(16)
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Share.copy(event.jsonText, what: "event JSON") } label: { Image(systemName: "curlybraces") }
                    .accessibilityLabel("Copy event as JSON")
                Menu { EventActions(event: event) } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Copy or share")
            }
        }
    }

    private var selected: String { selection ?? event.deliveries.first?.destination ?? event.dropped.first ?? "" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(event.name)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                if !event.isRedacted {
                    Label("Unredacted", systemImage: "lock.open.fill")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.failure.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(Theme.failureText)
                }
            }
            let total = event.deliveries.count + event.dropped.count
            Text([event.kind == .event ? nil : event.kind.label, event.source,
                  event.date.formatted(date: .omitted, time: .standard),
                  "sent to \(event.deliveries.count) of \(total)"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var destinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(event.deliveries.map(\.destination) + event.dropped, id: \.self) { destination in
                    let isDropped = event.dropped.contains(destination)
                    let isOn = selected == destination
                    Button { selection = destination } label: {
                        Text(destination)
                            .font(.footnote)
                            .strikethrough(isDropped)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .foregroundStyle(isOn ? Theme.ground : isDropped ? Theme.failureText : Theme.text)
                            .background(isOn ? (isDropped ? Theme.failureText : Theme.text) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isDropped ? Theme.failure.opacity(0.5) : Theme.hairline,
                                                                                    style: StrokeStyle(lineWidth: 1, dash: isDropped ? [3] : [])))
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isDropped ? "\(destination), dropped" : destination)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(event.warnings.count) warning\(event.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.warningText)
            ForEach(event.warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(warning.tag)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 5)
                        .background(Theme.clientError.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Theme.warningText)
                    Text(warning.message)
                        .font(.footnote)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.clientError.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.clientError.opacity(0.3)))
    }

    @ViewBuilder private var properties: some View {
        Labeled("Properties · \(selected)") {
            if let delivery = event.deliveries.first(where: { $0.destination == selected }) {
                if delivery.name != event.name {
                    Text("Sent as \(delivery.name)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if delivery.properties.isEmpty {
                    Text("None").font(.footnote).foregroundStyle(Theme.tertiaryText)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(delivery.properties.enumerated()), id: \.offset) { index, property in
                            PropertyRow(property: property, isFlagged: event.warnings.contains { $0.message.hasPrefix(property.key + " ") })
                            if index < delivery.properties.count - 1 { Divider().overlay(Theme.hairline) }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                }
            } else {
                Text("Not sent: the app has no tracker for \(selected).")
                    .font(.footnote)
                    .foregroundStyle(Theme.failureText)
            }
        }
    }

    /// Requests that started within 2 s of the event, oldest first.
    @ViewBuilder private var nearby: some View {
        let around = network.all.filter { abs($0.startedAt.timeIntervalSince(event.date)) <= 2 }.sorted { $0.startedAt < $1.startedAt }
        Labeled("Network ±2 s") {
            if around.isEmpty {
                Text("No requests").font(.footnote).foregroundStyle(Theme.tertiaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(around, id: \.id) { record in
                        NavigationLink {
                            NetworkDetailView(model: network, id: record.id)
                        } label: {
                            HStack(spacing: 8) {
                                MethodChip(method: record.method)
                                Text(record.shortPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 4)
                                Text(Format.status(record))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.color(for: StatusClass(record)))
                                Text(String(format: "%+.1fs", record.startedAt.timeIntervalSince(event.date)))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .padding(10)
                            .frame(minHeight: 44)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct PropertyRow: View {
    let property: EventRecord.Property
    let isFlagged: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(property.key).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.accent)
                Text(typeLine).font(.caption2).foregroundStyle(Theme.tertiaryText)
            }
            .frame(width: 128, alignment: .leading)
            Text(property.value.displayText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if property.isSuper {
                Text("SUPER")
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel("Super property, added to every event")
            }
        }
        .padding(10)
        .background(isFlagged ? Theme.clientError.opacity(0.07) : .clear)
        .contextMenu {
            Button("Copy value") { Share.copy(property.value.displayText, what: "value") }
            Button("Copy key") { Share.copy(property.key, what: "key") }
        }
        .accessibilityElement(children: .combine)
    }

    private var typeLine: String {
        if case let .string(text) = property.value, text.count > 40 { return "string · \(text.count) chars" }
        return property.value.typeName
    }

    private var color: Color {
        switch property.value {
        case .string: Theme.success
        case .int, .double: Theme.clientError
        case .bool: Theme.redirect
        case .other: Theme.failureText
        }
    }
}

/// Copy / share for one event. Used by the detail menu and the row long-press menu.
struct EventActions: View {
    let event: EventRecord

    var body: some View {
        Section("Copy") {
            Button { Share.copy(event.name, what: "event name") } label: { Label("Event name", systemImage: "textformat") }
            Button { Share.copy(event.jsonText, what: "event JSON") } label: { Label("JSON", systemImage: "curlybraces") }
            Button { Share.copy(event.report(.markdown), what: "report") } label: { Label("Report (Markdown)", systemImage: "doc.richtext") }
        }
        Section("Share") {
            Button { Share.text(event.report(.markdown)) } label: { Label("Report for Jira / Slack", systemImage: "square.and.arrow.up") }
            Button { Share.file(Data(event.jsonText.utf8), named: event.name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) + ".json") } label: { Label("JSON file", systemImage: "doc") }
        }
    }
}
#endif
