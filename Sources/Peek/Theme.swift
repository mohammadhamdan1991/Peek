#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

/// The inspector's own tokens, so it looks the same in every host and never depends on the host's design system.
/// Each has a dark and a light value; the panel picks one from the Appearance setting, the floating button is always dark.
enum Theme {
    static let ground = Color(dark: 0x0E1013, light: 0xF4F5F7)
    static let surface = Color(dark: 0x16191E, light: 0xFFFFFF)
    static let code = Color(dark: 0x121418, light: 0xF0F1F4)
    static let hairline = Color(dark: 0x23272E, light: 0xDDE0E6)
    static let text = Color(dark: 0xF2F3F5, light: 0x14171C)
    static let secondaryText = Color(dark: 0xB4BAC4, light: 0x464D58)
    static let tertiaryText = Color(dark: 0x8A919C, light: 0x646B76)
    static let accent = Color(dark: 0xB9A6FF, light: 0x6547D6)
    static let onAccent = Color(dark: 0x17131F, light: 0xFFFFFF)

    static let success = Color(dark: 0x3DDC97, light: 0x14804F)
    static let redirect = Color(dark: 0x5AA9FF, light: 0x1F63C7)
    static let clientError = Color(dark: 0xFFB547, light: 0xB06100)
    static let failure = Color(dark: 0xFF5C69, light: 0xD42A38)
    static let failureText = Color(dark: 0xFF8A94, light: 0xC0222F)
    static let socket = Color(dark: 0xB9A6FF, light: 0x6547D6)
    static let event = Color(dark: 0x4FD1C5, light: 0x0E8A7E)
    static let eventText = Color(dark: 0x7FE3D8, light: 0x0A7268)
    static let warningText = Color(dark: 0xFFC777, light: 0x8F4F00)

    static let mono = Font.system(.footnote, design: .monospaced)

    static func color(for status: StatusClass) -> Color {
        switch status {
        case .pending: tertiaryText
        case .success: success
        case .redirect: redirect
        case .clientError: clientError
        case .serverError, .failed: failure
        }
    }

    static func color(forMethod method: String) -> Color {
        switch method.uppercased() {
        case "GET": redirect
        case "POST": success
        case "PUT", "PATCH": clientError
        case "DELETE": failureText
        default: secondaryText
        }
    }
}

/// The panel's light or dark look. Saved, so it outlives relaunch; Dark is the default.
enum Appearance: String, CaseIterable {
    case dark, light, system

    private static let key = "dev.peek.appearance"
    static let didChange = Notification.Name("Peek.appearanceDidChange")

    @MainActor static var current: Appearance {
        get { UserDefaults.standard.string(forKey: key).flatMap(Appearance.init) ?? .dark }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match device"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: .unspecified
        }
    }
}

extension Color {
    /// Resolves per trait collection, so UIKit chrome built from it (`UIColor(Theme.accent)`) follows too.
    init(dark: UInt32, light: UInt32) {
        self.init(UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark) })
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
