#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import UIKit
import PeekCore

/// One attempt. Looks its record up by id on every refresh, so a request completing while open updates in place.
struct NetworkDetailView: View {
    enum Tab: String, CaseIterable { case request = "Request", response = "Response", timing = "Timing", headers = "Headers" }

    @ObservedObject var model: NetworkListModel
    let id: UUID
    @State private var tab = Tab.response

    var body: some View {
        Group {
            if let record = model.record(id) {
                content(record)
            } else {
                Text("This request was cleared or evicted.")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ record: HTTPRecord) -> some View {
        let attempts = model.attempts(of: record)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(record, attempts: attempts)
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .request: RequestSection(record: record)
                case .response: ResponseSection(record: record)
                case .timing: TimingSection(record: record, attempts: attempts)
                case .headers: HeadersSection(record: record)
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // The most common action, one tap away.
                Button { Share.copy(record.curlCommand, what: "cURL") } label: { Image(systemName: "terminal") }
                    .accessibilityLabel("Copy as cURL")
                Menu { RequestActions(record: record) } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Copy or share")
            }
        }
    }

    private func header(_ record: HTTPRecord, attempts: [HTTPRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MethodChip(method: record.method)
                Text(statusText(record))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.color(for: StatusClass(record)).opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(Theme.color(for: StatusClass(record)))
                if !record.isRedacted {
                    Label("Unredacted", systemImage: "lock.open.fill")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.failure.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(Theme.failureText)
                        .accessibilityLabel("Unredacted: contains tokens and personal data")
                }
            }
            Text(record.url.path.isEmpty ? "/" : record.url.path)
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Text([record.url.host, record.module, record.startedAt.formatted(date: .omitted, time: .standard)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
            HStack(spacing: 8) {
                StatTile(title: "Duration", value: record.duration.map(Format.duration) ?? "—")
                StatTile(title: "Sent", value: Format.size(record.requestBody?.originalSize ?? 0))
                StatTile(title: "Received", value: Format.size(record.responseBody?.originalSize ?? 0))
                StatTile(title: "Attempt", value: "\((attempts.firstIndex { $0.id == record.id } ?? 0) + 1) of \(attempts.count)",
                         color: attempts.count > 1 ? Theme.clientError : Theme.text)
            }
        }
    }

    private func statusText(_ record: HTTPRecord) -> String {
        guard let code = record.statusCode else { return record.error == nil ? "Pending" : "Failed" }
        return Format.statusLine(code)
    }
}

// MARK: - Sections

private struct RequestSection: View {
    let record: HTTPRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Labeled("URL") {
                Text(record.url.absoluteString.removingPercentEncoding ?? record.url.absoluteString)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
            if let items = URLComponents(url: record.url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
                Labeled("Query") { KeyValueList(pairs: items.map { ($0.name, $0.value ?? "") }) }
            }
            Labeled("Body") { BodyView(captured: record.requestBody) }
        }
    }
}

private struct ResponseSection: View {
    let record: HTTPRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = record.error {
                Text(error)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.failureText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.failure.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
            BodyView(captured: record.responseBody)
        }
    }
}

private struct HeadersSection: View {
    let record: HTTPRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Labeled("Request") { KeyValueList(pairs: record.requestHeaders.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) }
            Labeled("Response") { KeyValueList(pairs: record.responseHeaders.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) }
        }
    }
}

// MARK: - Shared pieces

struct Labeled<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .tracking(1)
                .foregroundStyle(Theme.tertiaryText)
            content
        }
    }
}

struct KeyValueList: View {
    let pairs: [(String, String)]

    var body: some View {
        if pairs.isEmpty {
            Text("None").font(.footnote).foregroundStyle(Theme.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pairs.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pairs[index].0).font(.caption).foregroundStyle(Theme.tertiaryText)
                        Text(pairs[index].1).font(Theme.mono).foregroundStyle(Theme.text).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .contextMenu {
                        Button("Copy value") { Share.copy(pairs[index].1, what: "value") }
                    }
                    if index < pairs.count - 1 { Divider().overlay(Theme.hairline) }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
    }
}
#endif
