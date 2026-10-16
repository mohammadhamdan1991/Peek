#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI

/// The button's look only; touches, dragging and the menu live in `OverlayViewController` (UIKit),
/// so the overlay window can hit-test against a real frame.
struct FloatingButtonView: View {
    static let diameter: CGFloat = 56

    @ObservedObject var model: InspectorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if model.unseenFailures > 0 {
                Circle()
                    .stroke(Theme.failure, lineWidth: 2)
                    .scaleEffect(pulse && !reduceMotion ? 1.55 : 1)
                    .opacity(pulse && !reduceMotion ? 0 : 0.55)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }

            Image(systemName: model.isPaused ? "pause" : "arrow.up.arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: Self.diameter, height: Self.diameter)
                .inspectorGlass()
                .overlay(
                    Circle().strokeBorder(model.unseenFailures > 0 ? Theme.failure.opacity(0.6) : .white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            badge
                .offset(x: -Self.diameter / 2 + 2, y: -Self.diameter / 2 + 4)

            Text(model.isPaused ? "PAUSED" : model.environmentTag)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(model.isPaused ? Color(hex: 0x4A505A) : Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(model.isPaused ? Theme.text : Theme.onAccent)
                .offset(y: Self.diameter / 2 + 1)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true) // the UIKit container carries the label and actions
    }

    @ViewBuilder private var badge: some View {
        let failures = model.unseenFailures
        if failures > 0 || model.requestCount > 0 {
            Text(failures > 0 ? "\(failures)" : "\(model.requestCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(failures > 0 ? Theme.onAccent : .white) // dark on red: 6:1, white was 3:1
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(failures > 0 ? Theme.failure : Color(hex: 0x3A3F48), in: Capsule())
        }
    }
}

extension View {
    @ViewBuilder func inspectorGlass() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.tint(Theme.ground.opacity(0.55)), in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
                .background(Theme.ground.opacity(0.55), in: Circle())
        }
    }
}
#endif
