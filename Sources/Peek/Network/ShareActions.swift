#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PeekCore

/// Copy and share for captured traffic. Shares real text and real files, so the system sheet offers
/// Copy, Mail, Slack, AirDrop, Save to Files… Everything shared is the stored, already-redacted data.
@MainActor
enum Share {
    /// Device-only (no Universal Clipboard) and gone after 10 minutes, since copies can hold tokens.
    static func copy(_ text: String, what: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)]
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Toast.shared.show("Copied \(what)")
    }

    static func text(_ text: String) {
        present([text]) {}
    }

    /// Written encrypted-at-rest, deleted when the share sheet closes (and any leftovers before the next share).
    static func file(_ data: Data, named name: String) {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("Peek", isDirectory: true)
        let url = directory.appendingPathComponent(name)
        do {
            try? files.removeItem(at: directory)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            present([url]) { try? files.removeItem(at: url) }
        } catch {
            Toast.shared.show("Couldn't create \(name)")
        }
    }

    /// File-name-safe stem, e.g. "POST-v2-driver-location".
    static func fileStem(_ record: HTTPRecord) -> String {
        let path = record.url.path.split(separator: "/").suffix(3).joined(separator: "-")
        return "\(record.method)-\(path.isEmpty ? "root" : path)"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }

    private static func present(_ items: [Any], completion: @escaping () -> Void) {
        guard let presenter = topViewController() else { return completion() }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in completion() }
        sheet.popoverPresentationController?.sourceView = presenter.view // iPad
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        presenter.present(sheet, animated: true)
    }

    /// The inspector panel's window is key while it's open; share from its top-most presented controller.
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Short confirmation at the bottom of the panel ("Copied cURL").
@MainActor
final class Toast: ObservableObject {
    static let shared = Toast()
    @Published private(set) var message: String?

    func show(_ message: String) {
        self.message = message
        UIAccessibility.post(notification: .announcement, argument: message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.message == message { self?.message = nil }
        }
    }
}

struct ToastView: View {
    @ObservedObject var toast = Toast.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let message = toast.message {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .padding(.bottom, 24)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityHidden(true) // announced via UIAccessibility instead
        }
    }
}

/// Every copy / share action for one request. Used by the detail menu and the row long-press menu.
struct RequestActions: View {
    let record: HTTPRecord

    var body: some View {
        Section("Copy") {
            Button { Share.copy(record.url.absoluteString, what: "URL") } label: { Label("URL", systemImage: "link") }
            Button { Share.copy(record.curlCommand, what: "cURL") } label: { Label("cURL", systemImage: "terminal") }
            Button { Share.copy(record.requestReport(.plainText), what: "request") } label: {
                Label("Request (headers + body)", systemImage: "arrow.up.doc")
            }
            Button { Share.copy(record.responseReport(.plainText), what: "response") } label: {
                Label("Response (headers + body)", systemImage: "arrow.down.doc")
            }
            if let body = record.responseBody, let text = body.displayText {
                Button { Share.copy(text, what: "response body") } label: { Label("Response body", systemImage: "curlybraces") }
            }
            Button { Share.copy(record.report(.markdown), what: "report") } label: {
                Label("Full report (Markdown)", systemImage: "doc.richtext")
            }
        }
        Section("Share") {
            Button { Share.text(record.report(.markdown)) } label: {
                Label("Report for Jira / Slack (Markdown)", systemImage: "square.and.arrow.up")
            }
            Button { Share.text(record.report(.plainText)) } label: { Label("Report (plain text)", systemImage: "doc.plaintext") }
            Button { Share.text(record.curlCommand) } label: { Label("cURL", systemImage: "terminal") }
            Button { Share.file(HAR.export([record]), named: Share.fileStem(record) + ".har") } label: {
                Label("HAR file", systemImage: "doc.zipper")
            }
            if let body = record.responseBody {
                let isJSON = (try? JSONSerialization.jsonObject(with: body.data, options: [.fragmentsAllowed])) != nil
                Button {
                    Share.file(Data((body.displayText ?? "").utf8), named: Share.fileStem(record) + (isJSON ? ".json" : ".txt"))
                } label: {
                    Label("Response body file", systemImage: "doc")
                }
            }
        }
    }
}

/// Copy / share for one socket message.
struct SocketActions: View {
    let record: SocketRecord

    var body: some View {
        Button { Share.copy(record.name, what: "event name") } label: { Label("Copy event name", systemImage: "textformat") }
        if let text = record.payload?.displayText {
            Button { Share.copy(text, what: "payload") } label: { Label("Copy payload", systemImage: "curlybraces") }
        }
        Button { Share.copy(record.report(.markdown), what: "report") } label: { Label("Copy report (Markdown)", systemImage: "doc.richtext") }
        Button { Share.text(record.report(.markdown)) } label: { Label("Share report", systemImage: "square.and.arrow.up") }
    }
}
#endif
