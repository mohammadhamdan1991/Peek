#if !PEEK_DISABLED && canImport(UIKit)
import Combine
import SwiftUI
import UIKit
import PeekCore

/// One overlay window per connected `UIWindowScene`, kept in step with scene connect / disconnect.
/// Works for scene-based apps and app-delegate apps, which still get an implicit scene.
@MainActor
final class OverlayController: NSObject, UIAdaptivePresentationControllerDelegate {
    let model: InspectorModel
    private let store: RecordStore<HTTPRecord>
    private var windows: [ObjectIdentifier: OverlayWindow] = [:]
    private var areButtonsHidden = false
    private weak var previousKeyWindow: UIWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?

    init(environmentTag: String, store: RecordStore<HTTPRecord>) {
        model = InspectorModel(environmentTag: environmentTag)
        self.store = store
    }

    func start() {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.forEach(attach)

        // UIKit posts scene notifications on the main thread.
        let center = NotificationCenter.default
        center.publisher(for: UIScene.willConnectNotification)
            .compactMap { $0.object as? UIWindowScene }
            .sink { [weak self] in self?.attach($0) }
            .store(in: &subscriptions)
        center.publisher(for: UIScene.didDisconnectNotification)
            .compactMap { $0.object as? UIScene }
            .sink { [weak self] in self?.windows[ObjectIdentifier($0)] = nil }
            .store(in: &subscriptions)

        // Subscribe before the first read, so nothing lands in between unseen.
        let updates = [store.updates(), Inspector.events.updates()]
        model.refresh(from: store, events: Inspector.events)
        refreshTask = Task { [weak self, store] in
            for await _ in Self.merge(updates) {
                guard let self else { return }
                model.refresh(from: store, events: Inspector.events)
                try? await Task.sleep(for: .milliseconds(250)) // ≤ 4 UI updates/s; the stream coalesces meanwhile
            }
        }
    }

    /// One stream that ticks when any of `streams` does. Coalesces like the stores' own streams.
    private static func merge(_ streams: [AsyncStream<Void>]) -> AsyncStream<Void> {
        let (merged, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let tasks = streams.map { stream in Task { for await _ in stream { continuation.yield() } } }
        continuation.onTermination = { _ in tasks.forEach { $0.cancel() } }
        return merged
    }

    // MARK: Windows

    private func attach(_ scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        guard windows[id] == nil else { return }
        let overlay = OverlayViewController(model: model, actions: .init(
            open: { [weak self] in self?.presentPanel(from: $0) },
            togglePause: { [weak self] in self?.togglePause() },
            copyLastCurl: { [store] in
                guard let last = store.records.last?.displayed(redacted: Inspector.redaction.isEnabled) else { return }
                Share.copy(last.curlCommand, what: "cURL")
            },
            clear: { Inspector.clearAll() },
            hideButtons: { [weak self] in self?.setButtonsHidden(true) }
        ))
        overlay.loadViewIfNeeded()
        overlay.setButtonHidden(areButtonsHidden)
        windows[id] = OverlayWindow(scene: scene, overlay: overlay)
    }

    private var activeOverlay: OverlayViewController? {
        let all = Array(windows.values)
        return (all.first { $0.windowScene?.activationState == .foregroundActive } ?? all.first)?.overlay
    }

    func setButtonsHidden(_ hidden: Bool) {
        areButtonsHidden = hidden
        windows.values.forEach { $0.overlay.setButtonHidden(hidden) }
    }

    func togglePause() {
        Inspector.setCapturing(store.isPaused)
    }

    // MARK: Panel

    var isPanelPresented: Bool { windows.values.contains { $0.overlay.presentedViewController != nil } }

    func presentPanel(from overlay: OverlayViewController? = nil) {
        guard !isPanelPresented, let overlay = overlay ?? activeOverlay, let window = overlay.view.window else { return }
        PanelHostingController.resetHostAppearance()
        let panel = PanelHostingController(rootView: PanelView(
            model: model,
            tools: Inspector.tools,
            togglePause: { [weak self] in self?.togglePause() },
            clear: { Inspector.clearAll() },
            close: { [weak self] in self?.dismissPanel() }
        ))
        panel.overrideUserInterfaceStyle = Appearance.current.style
        panel.modalPresentationStyle = .pageSheet
        if let sheet = panel.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        panel.presentationController?.delegate = self

        previousKeyWindow = window.windowScene?.windows.first { $0.isKeyWindow && $0 !== window }
        model.markSeen()
        overlay.setButtonHidden(true)
        overlay.present(panel, animated: true)
        window.makeKey() // after presenting, so canBecomeKey is true; lets search fields take the keyboard
    }

    func dismissPanel() {
        guard let overlay = windows.values.first(where: { $0.overlay.presentedViewController != nil })?.overlay else { return }
        overlay.dismiss(animated: true) { [weak self] in self?.panelDidClose() }
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { panelDidClose() }
    }

    private func panelDidClose() {
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        setButtonsHidden(areButtonsHidden)
    }
}

/// Hosts set global `UINavigationBar.appearance()` / `UITabBar.appearance()` (tints, fonts, even hiding the tab bar);
/// scoped to this class, the panel gets system defaults with the inspector's accent instead.
final class PanelHostingController: UIHostingController<PanelView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        presentingViewController?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }

    private static var didReset = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Appearance can change while the panel is open, from its own menu.
        NotificationCenter.default.addObserver(forName: Appearance.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overrideUserInterfaceStyle = Appearance.current.style }
        }
    }

    static func resetHostAppearance() {
        guard !didReset else { return }
        didReset = true
        let bar = UINavigationBar.appearance(whenContainedInInstancesOf: [PanelHostingController.self])
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor(Theme.text)]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.text)]
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.tintColor = UIColor(Theme.accent)

        // Apps with a custom tab bar often hide the system one app-wide (`UITabBar.appearance().isHidden = true`),
        // which would also hide the panel's Network | Events bar. Scoped to the panel, this wins.
        let tabBar = UITabBar.appearance(whenContainedInInstancesOf: [PanelHostingController.self])
        tabBar.isHidden = false
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabBar.standardAppearance = tabAppearance
        tabBar.scrollEdgeAppearance = tabAppearance
        tabBar.tintColor = UIColor(Theme.accent)
    }
}
#endif
