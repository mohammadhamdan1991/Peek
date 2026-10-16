#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import UIKit
import PeekCore

private extension SocketRecord.Direction {
    var glyph: String {
        switch self {
        case .incoming: "↓"
        case .outgoing: "↑"
        case .lifecycle: "•"
        }
    }

    var label: String {
        switch self {
        case .incoming: "recv"
        case .outgoing: "emit"
        case .lifecycle: "conn"
        }
    }

    var color: Color {
        switch self {
        case .incoming: Theme.socket
        case .outgoing: Theme.redirect
        case .lifecycle: Theme.clientError
        }
    }
}

struct SocketRow: View {
    let record: SocketRecord

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(record.direction.color.opacity(0.7)).frame(width: 3)
            Text(record.direction.glyph)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .frame(width: 26, height: 26)
                .background(record.direction.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(record.direction.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(record.isFailure ? Theme.failureText : Theme.text)
                    .lineLimit(1)
                Text([record.url?.host, record.namespace].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.direction.label)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(record.direction.color)
                Text([record.payload.map { Format.size($0.originalSize) },
                      Format.age(record.date)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.trailing, 4)
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionCard: View {
    let connection: SocketConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.namespace).font(.system(.subheadline, design: .monospaced).weight(.medium)).foregroundStyle(Theme.text)
                    Text(connection.host).font(.caption).foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 7, height: 7)
                    Text(stateText).font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(stateColor.opacity(0.14), in: Capsule())
                .foregroundStyle(stateColor)
            }
            HStack(spacing: 8) {
                StatTile(title: "Since", value: connection.since.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                StatTile(title: "Reconnects", value: "\(connection.reconnects)", color: connection.reconnects > 0 ? Theme.clientError : Theme.text)
                StatTile(title: "↑ / ↓", value: "\(connection.outgoing) / \(connection.incoming)")
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        switch connection.state {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case .unknown: "Unknown"
        }
    }

    private var stateColor: Color {
        switch connection.state {
        case .connected: Theme.success
        case .reconnecting: Theme.clientError
        case .disconnected: Theme.failure
        case .unknown: Theme.tertiaryText
        }
    }
}

struct SocketDetailView: View {
    @ObservedObject var model: NetworkListModel
    let id: UUID

    var body: some View {
        Group {
            if let record = model.socket(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(record)
                        if let connection = model.connection(for: record) {
                            ConnectionCard(connection: connection)
                        }
                        Labeled("Payload") { BodyView(captured: record.payload) }
                    }
                    .padding(16)
                }
            } else {
                Text("This message was cleared or evicted.")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let record = model.socket(id) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { SocketActions(record: record) } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Copy or share")
                }
            }
        }
    }

    private func header(_ record: SocketRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.direction.label.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(record.direction.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(record.direction.color)
            Text(record.name)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Text([record.url?.host, record.namespace, record.date.formatted(date: .omitted, time: .standard)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}
#endif
