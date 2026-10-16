#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI

/// The sheet the floating button opens: one tab per registered tool, opening on the first (Network).
/// With a single tool the tab bar is hidden, so the panel opens straight into it.
struct PanelView: View {
    @ObservedObject var model: InspectorModel
    let tools: [any InspectorTool]
    let togglePause: () -> Void
    let clear: () -> Void
    let close: () -> Void

    @State private var selection = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $selection) {
            ForEach(tools.indices, id: \.self) { index in
                NavigationStack {
                    tools[index].makeView()
                        .navigationTitle(tools[index].title)
                        .navigationBarTitleDisplayMode(.inline)
                        .background(Theme.ground.ignoresSafeArea())
                        .toolbar { panelToolbar }
                }
                .tabItem { Label(tools[index].title, systemImage: tools[index].systemImage) }
                .tag(index)
                .toolbar(tools.count > 1 ? .visible : .hidden, for: .tabBar)
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) { ToastView() }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.3), value: Toast.shared.message)
    }

    /// Close and environment on the left; capture options on the right, before the tool's own actions (e.g. share).
    @ToolbarContentBuilder private var panelToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: close) { Image(systemName: "xmark") }
                .accessibilityLabel("Close inspector")
        }
        ToolbarItem(placement: .topBarLeading) {
            Text(model.environmentTag)
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Environment \(model.environmentTag)")
        }
        if !model.isRedactionEnabled {
            ToolbarItem(placement: .topBarLeading) {
                Label("Unredacted", systemImage: "lock.open.fill")
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.failureText)
                    .accessibilityLabel("Redaction is off: showing real tokens and personal data")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: togglePause) {
                    Label(model.isPaused ? "Resume capture" : "Pause capture", systemImage: model.isPaused ? "play" : "pause")
                }
                Toggle(isOn: $model.isRedactionEnabled) {
                    Label("Redact secrets", systemImage: model.isRedactionEnabled ? "lock.fill" : "lock.open")
                }
                Button(role: .destructive, action: clear) {
                    Label("Clear all", systemImage: "trash")
                }
            } label: {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "ellipsis.circle")
            }
            .accessibilityLabel("Capture options")
        }
    }
}
#endif
