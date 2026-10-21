#if !PEEK_DISABLED && canImport(UIKit)
import Combine
import SwiftUI
import UIKit

/// Sits above the app (and its alerts) but only claims touches on the floating button,
/// or everywhere while the panel is presented. Never key unless the panel needs the keyboard.
final class OverlayWindow: UIWindow {
    let overlay: OverlayViewController

    init(scene: UIWindowScene, overlay: OverlayViewController) {
        self.overlay = overlay
        super.init(windowScene: scene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        tintColor = UIColor(Theme.accent) // UIKit chrome in the panel (bar buttons) follows the window tint
        rootViewController = overlay
        isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { overlay.presentedViewController != nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard overlay.claimsTouch(at: convert(point, to: overlay.view)) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Owns the floating button: drag + edge snap, idle docking, drag-to-hide, long-press menu.
final class OverlayViewController: UIViewController, UIContextMenuInteractionDelegate {
    struct Actions {
        var open: (OverlayViewController) -> Void
        var togglePause: () -> Void
        var copyLastCurl: () -> Void
        var clear: () -> Void
        var hideButtons: () -> Void
    }

    private enum Side: String { case left, right }
    private enum Layout {
        static let container: CGFloat = 72 // 56 pt button + room for badge and tag
        static let margin: CGFloat = 4
        static let hideTargetRadius: CGFloat = 64
        static let dockDelay: Duration = .seconds(3)
    }

    private let model: InspectorModel
    private let actions: Actions
    private let button = UIView()
    private let hideTarget = UIImageView(image: UIImage(systemName: "xmark"))
    private let defaults = UserDefaults(suiteName: "dev.peek")
    private var side: Side
    private var yFraction: CGFloat
    private var isDragging = false
    private var isDocked = false
    private var keyboardOverlap: CGFloat = 0
    private var dockTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: InspectorModel, actions: Actions) {
        self.model = model
        self.actions = actions
        side = defaults?.string(forKey: "button.side").flatMap(Side.init) ?? .right
        yFraction = defaults?.object(forKey: "button.y") as? CGFloat ?? 0.4
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func claimsTouch(at point: CGPoint) -> Bool {
        presentedViewController != nil || (!button.isHidden && button.frame.contains(point))
    }

    func setButtonHidden(_ hidden: Bool) {
        button.isHidden = hidden
        guard !hidden, isViewLoaded else { return }
        // Back from the panel or "Hide until relaunch": undocked, in place for the current size and keyboard.
        isDocked = false
        positionButton(animated: false)
        scheduleDock()
    }

    /// While the panel's window is key, its root controller decides the orientation: follow the app's.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        var host = view.window?.windowScene?.windows.first { $0 !== view.window && !$0.isHidden && $0.rootViewController != nil }?.rootViewController
        while let presented = host?.presentedViewController, !presented.isBeingDismissed { host = presented }
        return host?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Like the button, always dark, whatever the host's mode or the panel's Appearance setting.
        hideTarget.overrideUserInterfaceStyle = .dark
        hideTarget.tintColor = UIColor(Theme.failureText)
        hideTarget.contentMode = .center
        hideTarget.layer.borderColor = UIColor(Theme.failureText).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor
        hideTarget.layer.borderWidth = 1.5
        hideTarget.layer.cornerRadius = 26
        hideTarget.backgroundColor = UIColor(Theme.ground).withAlphaComponent(0.6)
        hideTarget.bounds.size = CGSize(width: 52, height: 52)
        hideTarget.alpha = 0
        hideTarget.isAccessibilityElement = false
        view.addSubview(hideTarget)

        let host = UIHostingController(rootView: FloatingButtonView(model: model))
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        addChild(host)
        button.bounds.size = CGSize(width: Layout.container, height: Layout.container)
        host.view.frame = button.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.addSubview(host.view)
        host.didMove(toParent: self)
        view.addSubview(button)

        button.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        button.addInteraction(UIContextMenuInteraction(delegate: self))

        button.isAccessibilityElement = true
        button.accessibilityLabel = "Network inspector"
        button.accessibilityHint = "Opens captured requests. Actions menu has more."
        button.accessibilityTraits = .button
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Copy last request as cURL") { [weak self] _ in
                self?.actions.copyLastCurl()
                return true
            },
            UIAccessibilityCustomAction(name: "Pause or resume capture") { [weak self] _ in
                self?.actions.togglePause()
                UIAccessibility.post(notification: .announcement, argument: self?.model.isPaused == true ? "Capture paused" : "Capture resumed")
                return true
            },
            UIAccessibilityCustomAction(name: "Clear all") { [weak self] _ in
                self?.actions.clear()
                return true
            },
            UIAccessibilityCustomAction(name: "Move to other side") { [weak self] _ in
                guard let self else { return false }
                side = side == .left ? .right : .left
                persistPosition()
                positionButton(animated: true)
                return true
            },
            UIAccessibilityCustomAction(name: "Hide until relaunch") { [weak self] _ in
                self?.actions.hideButtons()
                return true
            },
        ]
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.button.accessibilityValue = self?.model.accessibilitySummary }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .sink { [weak self] note in self?.keyboardChanged(note) }
            .store(in: &subscriptions)

        scheduleDock()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hideTarget.center = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - view.safeAreaInsets.bottom - 48)
        if !isDragging { positionButton(animated: false) }
    }

    // MARK: Placement

    /// Where the button's center may go: inside the safe area, above the keyboard.
    private var allowedArea: CGRect {
        var area = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: Layout.margin, dy: Layout.margin)
        area.size.height -= max(0, keyboardOverlap - view.safeAreaInsets.bottom)
        return area.insetBy(dx: Layout.container / 2, dy: Layout.container / 2)
    }

    /// `nil` while the window has no room for the button, e.g. mid-transition when a
    /// Safari sheet or a rotation lays it out at zero size: insetting that empty rect
    /// gives `CGRect.null`, whose infinite edges reached the layer as a NaN position
    /// and crashed the host app. The next layout pass places the button.
    private func restingCenter() -> CGPoint? {
        let area = allowedArea
        guard !area.isNull, !area.isInfinite, area.width >= 0, area.height >= 0 else { return nil }
        let fraction = yFraction.isFinite ? min(max(yFraction, 0), 1) : 0.4
        let y = area.minY + fraction * area.height
        let center = isDocked
            ? CGPoint(x: side == .left ? view.bounds.minX : view.bounds.maxX, y: y)
            : CGPoint(x: side == .left ? area.minX : area.maxX, y: y)
        return center.x.isFinite && center.y.isFinite ? center : nil
    }

    private func positionButton(animated: Bool, velocity: CGFloat = 0) {
        guard let center = restingCenter() else { return }
        let alpha: CGFloat = isDocked ? 0.4 : 1
        animate(animated, velocity: velocity) {
            self.button.center = center
            self.button.alpha = alpha
        }
    }

    private func persistPosition() {
        defaults?.set(side.rawValue, forKey: "button.side")
        defaults?.set(Double(yFraction), forKey: "button.y")
    }

    private func animate(_ animated: Bool, velocity: CGFloat = 0, _ changes: @escaping () -> Void) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else { return changes() }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: velocity, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
    }

    // MARK: Gestures

    @objc private func tapped() {
        if isDocked {
            undock()
        } else {
            actions.open(self)
        }
        scheduleDock()
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            dockTask?.cancel()
            isDocked = false
            button.alpha = 1
            animate(true) { self.hideTarget.alpha = 1 }
        case .changed:
            let translation = gesture.translation(in: view)
            button.center.x += translation.x
            button.center.y += translation.y
            gesture.setTranslation(.zero, in: view)
            let overTarget = isOverHideTarget
            animate(true) { self.hideTarget.transform = overTarget ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity }
        case .ended, .cancelled, .failed:
            isDragging = false
            animate(true) {
                self.hideTarget.alpha = 0
                self.hideTarget.transform = .identity
            }
            if gesture.state == .ended, isOverHideTarget {
                actions.hideButtons()
                UIAccessibility.post(notification: .announcement, argument: "Inspector button hidden until relaunch")
                return
            }
            let area = allowedArea
            side = button.center.x < view.bounds.midX ? .left : .right
            yFraction = area.height > 0 ? min(max((button.center.y - area.minY) / area.height, 0), 1) : 0
            persistPosition()
            let distance = restingCenter().map { abs($0.x - button.center.x) } ?? 0
            positionButton(animated: true, velocity: distance > 0 ? abs(gesture.velocity(in: view).x) / distance : 0)
            scheduleDock()
        default:
            break
        }
    }

    private var isOverHideTarget: Bool {
        hypot(button.center.x - hideTarget.center.x, button.center.y - hideTarget.center.y) < Layout.hideTargetRadius
    }

    // MARK: Idle docking

    private func scheduleDock() {
        dockTask?.cancel()
        dockTask = Task { [weak self] in
            try? await Task.sleep(for: Layout.dockDelay)
            // Never dock for VoiceOver or Switch Control users: a half-hidden, faded target is hard to reach.
            guard let self, !Task.isCancelled, !isDragging, presentedViewController == nil,
                  !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning else { return }
            isDocked = true
            positionButton(animated: true)
        }
    }

    private func undock() {
        isDocked = false
        positionButton(animated: true)
    }

    // MARK: Keyboard

    private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = view.window?.screen else { return }
        let local = view.convert(frame, from: screen.coordinateSpace)
        keyboardOverlap = max(0, view.bounds.maxY - local.minY)
        if !isDragging { positionButton(animated: true) }
    }

    // MARK: Long-press menu

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        dockTask?.cancel()
        let paused = model.isPaused
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Open inspector", image: UIImage(systemName: "rectangle.stack")) { _ in
                    guard let self else { return }
                    self.actions.open(self)
                },
                UIAction(title: "Copy last request as cURL", image: UIImage(systemName: "terminal")) { _ in
                    self?.actions.copyLastCurl()
                },
                UIAction(title: paused ? "Resume capture" : "Pause capture", image: UIImage(systemName: paused ? "play" : "pause")) { _ in
                    self?.actions.togglePause()
                },
                UIAction(title: "Hide until relaunch", image: UIImage(systemName: "eye.slash")) { _ in
                    self?.actions.hideButtons()
                },
                UIAction(title: "Clear all", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self?.actions.clear()
                },
            ])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        scheduleDock()
    }
}
#endif
