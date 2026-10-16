#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

/// The inspector's own tokens, so it looks the same in every host and never depends on the host's design system.
enum Theme {
    static let ground = Color(hex: 0x0E1013)
    static let surface = Color(hex: 0x16191E)
    static let hairline = Color(hex: 0x23272E)
    static let text = Color(hex: 0xF2F3F5)
    static let secondaryText = Color(hex: 0xB4BAC4)
    static let tertiaryText = Color(hex: 0x8A919C)
    static let accent = Color(hex: 0xB9A6FF)
    static let onAccent = Color(hex: 0x17131F)

    static let success = Color(hex: 0x3DDC97)
    static let redirect = Color(hex: 0x5AA9FF)
    static let clientError = Color(hex: 0xFFB547)
    static let failure = Color(hex: 0xFF5C69)
    static let failureText = Color(hex: 0xFF8A94)
    static let socket = Color(hex: 0xB9A6FF)
    static let event = Color(hex: 0x4FD1C5)
    static let eventText = Color(hex: 0x7FE3D8)
    static let warningText = Color(hex: 0xFFC777)

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

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
#endif
