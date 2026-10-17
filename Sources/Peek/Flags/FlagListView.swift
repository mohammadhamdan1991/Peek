#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

/// Snapshot of `Inspector.flags` for the Flags screen. Filtering happens here, never in a view `body`.
@MainActor
final class FlagListModel: ObservableObject {
    enum Filter { case all, overridden, read }

    @Published var searchText = "" { didSet { applyFilter() } }
    @Published var filter = Filter.all { didSet { applyFilter() } }
    @Published private(set) var all: [FlagStore.Flag] = []
    @Published private(set) var visible: [FlagStore.Flag] = []
    @Published private(set) var overriddenCount = 0
    @Published private(set) var readCount = 0

    let store: FlagStore
    private var task: Task<Void, Never>?

    init(store: FlagStore) {
        self.store = store
        let updates = store.updates()
        reload()
        task = Task { [weak self] in
            for await _ in updates { self?.reload() }
        }
    }

    deinit { task?.cancel() }

    /// Also called on appear: reads don't push updates, so their counts refresh when the screen shows.
    func reload() {
        all = store.flags
        overriddenCount = all.reduce(0) { $0 + ($1.isOverridden ? 1 : 0) }
        readCount = all.reduce(0) { $0 + ($1.reads > 0 ? 1 : 0) }
        applyFilter()
    }

    private func applyFilter() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        visible = all.filter { flag in
            switch filter {
            case .all: break
            case .overridden: guard flag.isOverridden else { return false }
            case .read: guard flag.reads > 0 else { return false }
            }
            return text.isEmpty || flag.key.range(of: text, options: .caseInsensitive) != nil
        }
    }
}

struct FlagListView: View {
    @StateObject private var model = FlagListModel(store: Inspector.flags)

    var body: some View {
        List {
            Section {
                header.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            .listRowBackground(Theme.ground)
            .listRowSeparator(.hidden)

            ForEach(model.visible) { flag in
                NavigationLink {
                    FlagDetailView(key: flag.key)
                } label: {
                    FlagRow(flag: flag, source: model.store.source)
                }
                .listRowBackground(Theme.ground)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12))
                .listRowSeparatorTint(Theme.hairline)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .overlay { if model.visible.isEmpty { emptyState } }
        .onAppear { model.reload() }
        .refreshable { model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.overriddenCount > 0 {
                HStack {
                    Label("\(model.overriddenCount) overridden on this device", systemImage: "flag.fill")
                        .font(.footnote)
                    Spacer()
                    Button("Reset all") {
                        model.store.removeAllOverrides()
                        Toast.shared.show("Overrides removed")
                    }
                    .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Theme.warningText)
                .padding(10)
                .background(Theme.clientError.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            SearchField(text: $model.searchText, prompt: "Search \(model.all.count) flags", label: "Search flags")
            HStack(spacing: 8) {
                Chip(title: "All", isOn: model.filter == .all) { model.filter = .all }
                Chip(title: "Overridden · \(model.overriddenCount)", isOn: model.filter == .overridden) {
                    model.filter = model.filter == .overridden ? .all : .overridden
                }
                Chip(title: "Read · \(model.readCount)", isOn: model.filter == .read) {
                    model.filter = model.filter == .read ? .all : .read
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.all.isEmpty ? "flag" : "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiaryText)
            Text(model.all.isEmpty ? "No flags yet" : "Nothing matches")
                .foregroundStyle(Theme.secondaryText)
            if model.all.isEmpty {
                Text("Flags appear when the app reads them, or once its flag provider is connected")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.top, 220)
        .allowsHitTesting(false)
    }
}

struct FlagRow: View {
    let flag: FlagStore.Flag
    let source: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(flag.isOverridden ? Theme.accent : .clear).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                // Breaks only after "_" or "-": iOS would otherwise hyphenate a key mid-word ("CUS-TOM").
                Text(flag.key.replacingOccurrences(of: "_", with: "_\u{200B}").replacingOccurrences(of: "-", with: "-\u{200B}"))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            Spacer(minLength: 8)
            if let value = flag.value { FlagValueBadge(value: value) }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(flag.key), \(flag.value?.summary ?? "no value"), \(detail)")
    }

    private var detail: String {
        var parts: [String] = []
        if flag.isOverridden {
            parts.append("Override")
            if let remote = flag.remote { parts.append("\(source) \(remote.summary)") }
        } else {
            parts.append(flag.remote == nil ? "Default · not in \(source)" : source)
        }
        if flag.reads > 0 { parts.append("read \(flag.reads)×") }
        return parts.joined(separator: " · ")
    }
}

/// `true` in green, `false` in grey, anything else in the accent colour.
struct FlagValueBadge: View {
    let value: FlagValue

    var body: some View {
        Text(value.summary)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(foreground)
            .frame(maxWidth: 120, alignment: .trailing)
    }

    private var foreground: Color {
        switch value {
        case .bool(true): Theme.success
        case .bool(false), .null: Theme.secondaryText
        default: Theme.accent
        }
    }

    private var background: Color {
        switch value {
        case .bool(true): Theme.success.opacity(0.14)
        case .bool(false), .null: Theme.hairline
        default: Theme.accent.opacity(0.16)
        }
    }
}
#endif
