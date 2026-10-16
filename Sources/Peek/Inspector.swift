#if !PEEK_DISABLED && canImport(UIKit)
import os
import StoreKit
import SwiftUI
@_exported import PeekCore

/// A screen in the inspector panel. The Network tool is built in; later phases (Events, Flags, ...)
/// and host apps add theirs with `Inspector.register(_:)`.
@MainActor
public protocol InspectorTool {
    var title: String { get }
    /// SF Symbol name.
    var systemImage: String { get }
    func makeView() -> AnyView
}

public struct InspectorConfiguration: Sendable {
    /// Shown on the floating button: "DEV", "STG", "PRE".
    public var environmentTag: String
    /// The host's own answer to "is this production?": Peek refuses to start when true.
    public var isProductionEnvironment: Bool
    /// Exact non-production bundle ids, e.g. `com.example.app.staging`. Nil (the default) allows any bundle.
    public var allowedBundleIdentifiers: Set<String>?
    public var redactor: Redactor
    /// Whether each launch starts with redaction on. The in-panel switch lasts until relaunch, so a
    /// forgotten "off" never outlives the session.
    public var redactsByDefault: Bool
    /// Also capture every completion-handler `URLSession` task (SDKs, image loading, a networking layer
    /// without inspector hooks) by swizzling. Off when the app feeds `Inspector.capture` itself, or those
    /// requests show twice. See `URLSessionCapture`.
    public var capturesAllURLSessionTraffic: Bool

    public init(
        environmentTag: String = "DEV",
        isProductionEnvironment: Bool = false,
        allowedBundleIdentifiers: Set<String>? = nil,
        redactor: Redactor = .default,
        redactsByDefault: Bool = true,
        capturesAllURLSessionTraffic: Bool = false
    ) {
        self.environmentTag = environmentTag
        self.isProductionEnvironment = isProductionEnvironment
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.redactor = redactor
        self.redactsByDefault = redactsByDefault
        self.capturesAllURLSessionTraffic = capturesAllURLSessionTraffic
    }
}

/// Entry point. Hosts call this only inside `#if !PEEK_DISABLED`, from non-production configurations.
@MainActor
public enum Inspector {
    /// Captured HTTP traffic. Starts paused; nothing is kept unless `start` passes the runtime gate.
    public nonisolated static let http = RecordStore<HTTPRecord>(limits: .init(count: 1_000, bytes: 25 * 1_048_576))
    /// What a networking layer feeds: redacts, truncates and merges attempt events into `http`.
    /// Whether new captures are redacted. Shared by HTTP and sockets.
    public nonisolated static let redaction = RedactionPolicy()
    public nonisolated static let capture = HTTPCapture(store: http, policy: redaction)
    /// Captured socket.io messages and connection changes. Starts paused, like `http`.
    public nonisolated static let sockets = RecordStore<SocketRecord>(limits: .init(count: 2_000, bytes: 10 * 1_048_576))
    /// What a socket layer feeds: redacts and stores events into `sockets`.
    public nonisolated static let socketCapture = SocketCapture(store: sockets, policy: redaction)
    /// Analytics events as the app's sink handed them to each SDK. Starts paused, like `http`.
    public nonisolated static let events = RecordStore<EventRecord>(limits: .init(count: 2_000, bytes: 5 * 1_048_576))
    /// What an analytics sink feeds: checks, redacts and stores events into `events`.
    public nonisolated static let eventCapture = EventCapture(store: events, policy: redaction)

    public private(set) static var configuration: InspectorConfiguration?
    static private(set) var tools: [any InspectorTool] = [NetworkTool(), EventsTool()]
    private static var controller: OverlayController?
    private static var isStarting = false
    private static let logger = Logger(subsystem: "dev.peek", category: "gate")

    /// Checks the runtime gate, then shows the floating button on every scene.
    ///
    /// The bundle and environment checks run now, so launch traffic is captured; the App Store check is
    /// async, so the button appears only once it passes, and an App Store install drops what was captured.
    public static func start(_ configuration: InspectorConfiguration = InspectorConfiguration()) {
        guard controller == nil, !isStarting else { return }
        func evaluate(isAppStoreInstall: Bool) -> InspectorGate.Decision {
            InspectorGate.evaluate(.init(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                allowedBundleIdentifiers: configuration.allowedBundleIdentifiers,
                isProductionEnvironment: configuration.isProductionEnvironment,
                isAppStoreInstall: isAppStoreInstall
            ))
        }
        func stayOff(_ decision: InspectorGate.Decision) {
            setCapturing(false)
            clearAll()
            logger.notice("Peek stays off: \(String(describing: decision), privacy: .public)")
        }
        let early = evaluate(isAppStoreInstall: false)
        guard early == .allowed else { return stayOff(early) }

        isStarting = true
        redaction.setRedactor(configuration.redactor)
        redaction.isEnabled = configuration.redactsByDefault
        setCapturing(true)
        if configuration.capturesAllURLSessionTraffic { URLSessionCapture.install(capture) }
        Task {
            let decision = evaluate(isAppStoreInstall: await isAppStoreInstall())
            isStarting = false
            guard decision == .allowed else { return stayOff(decision) }
            self.configuration = configuration
            controller = OverlayController(environmentTag: configuration.environmentTag, store: http)
            controller?.start()
        }
    }

    static func setCapturing(_ isOn: Bool) {
        http.isPaused = !isOn
        sockets.isPaused = !isOn
        events.isPaused = !isOn
    }

    static func clearAll() {
        http.clear()
        sockets.clear()
        events.clear()
    }

    public static func show() { controller?.presentPanel() }
    public static func hide() { controller?.dismissPanel() }

    /// For a host's shake handler: opens the panel, or closes it if open.
    public static func toggle() {
        guard let controller else { return }
        controller.isPanelPresented ? controller.dismissPanel() : controller.presentPanel()
    }

    /// Brings the floating button back after "Hide until relaunch".
    public static func showButton() { controller?.setButtonsHidden(false) }

    /// Turn redaction off to see and share requests, sockets and events with their real tokens and credentials,
    /// including everything already captured (the real values are kept in memory). Lasts until relaunch.
    public static var isRedactionEnabled: Bool {
        get { redaction.isEnabled }
        set {
            redaction.isEnabled = newValue
            NotificationCenter.default.post(name: redactionDidChange, object: nil)
        }
    }

    /// Posted on the main actor when `isRedactionEnabled` changes, so open screens redraw with the other copy.
    static let redactionDidChange = Notification.Name("Peek.redactionDidChange")

    public static func register(_ tool: some InspectorTool) {
        tools.append(tool)
    }

    /// App Store installs never run the inspector, whatever the build flags say.
    private static func isAppStoreInstall() async -> Bool {
        // An Xcode / ad-hoc build without App Store metadata throws here: that is not an App Store install.
        guard let result = try? await AppTransaction.shared else { return false }
        switch result {
        case let .verified(transaction), let .unverified(transaction, _):
            return transaction.environment == .production
        }
    }
}

/// Built-in Network tool.
private struct NetworkTool: InspectorTool {
    let title = "Network"
    let systemImage = "arrow.up.arrow.down"

    func makeView() -> AnyView { AnyView(NetworkListView()) }
}

/// Built-in Events tool (Phase 2).
private struct EventsTool: InspectorTool {
    let title = "Events"
    let systemImage = "waveform.path.ecg"

    func makeView() -> AnyView { AnyView(EventListView()) }
}
#endif
