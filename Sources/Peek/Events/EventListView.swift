#if !PEEK_DISABLED && canImport(UIKit)
import Combine
import SwiftUI
import PeekCore

/// Snapshot of the event store for the Events screen. Filtering happens here, never in a view `body`.
@MainActor
final class EventListModel: ObservableObject {
    /// Debounced: free text also searches property values.
    @Published var searchText = "" { didSet { scheduleFilter() } }
    @Published var warningsOnly = false { didSet { applyFilter() } }
    @Published var droppedOnly = false { didSet { applyFilter() } }
    @Published var destination: String? { didSet { applyFilter() } }
    @Published var kind: EventRecord.Kind? { didSet { applyFilter() } }

    @Published private(set) var all: [EventRecord] = [] // newest first
    @Published private(set) var visible: [EventRecord] = []
    @Published private(set) var destinations: [String] = []
    /// Kinds other than plain events that are present, with their counts, in a fixed order.
    @Published private(set) var kindCounts: [(kind: EventRecord.Kind, count: Int)] = []
    @Published private(set) var warningCount = 0
    @Published private(set) var droppedCount = 0

    let store: RecordStore<EventRecord>
    private var task: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var redactionChange: AnyCancellable?

    init(store: RecordStore<EventRecord>) {
        self.store = store
        let updates = store.updates() // subscribe before the first read
        reload()
        redactionChange = NotificationCenter.default.publisher(for: Inspector.redactionDidChange)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        task = Task { [weak self] in
            for await _ in updates {
                self?.reload()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    deinit {
        task?.cancel()
        filterTask?.cancel()
    }

    var isFiltered: Bool { warningsOnly || droppedOnly || destination != nil || kind != nil || !searchText.isEmpty }

    private func reload() {
        let redacted = Inspector.redaction.isEnabled
        all = store.records.reversed().map { $0.displayed(redacted: redacted) }
        destinations = Array(Set(all.flatMap { $0.deliveries.map(\.destination) })).sorted()
        warningCount = all.reduce(0) { $0 + ($1.hasWarnings ? 1 : 0) }
        // Only tracked events: an error Crashlytics skips in this build isn't a dropped event.
        droppedCount = all.reduce(0) { $0 + ($1.kind.isTracked && !$1.dropped.isEmpty ? 1 : 0) }
        let counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        kindCounts = EventRecord.Kind.allCases.filter { $0 != .event }.compactMap { kind in counts[kind].map { (kind, $0) } }
        applyFilter()
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.applyFilter()
        }
    }

    private func applyFilter() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        visible = all.filter { event in
            if warningsOnly, !event.hasWarnings { return false }
            if droppedOnly, event.dropped.isEmpty || !event.kind.isTracked { return false }
            if let destination, !event.deliveries.contains(where: { $0.destination == destination }) { return false }
            if let kind, event.kind != kind { return false }
            return text.isEmpty || Self.matches(event, text)
        }
    }

    static func matches(_ event: EventRecord, _ text: String) -> Bool {
        func has(_ string: String) -> Bool { string.range(of: text, options: .caseInsensitive) != nil }
        return has(event.name) || event.source.map(has) == true || event.deliveries.contains { delivery in
            has(delivery.name) || delivery.properties.contains { has($0.key) || has($0.value.displayText) }
        }
    }
}

struct EventListView: View {
    @StateObject private var model = EventListModel(store: Inspector.events)

    var body: some View {
        List {
            Section {
                header.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            .listRowBackground(Theme.ground)
            .listRowSeparator(.hidden)

            ForEach(model.visible, id: \.id) { event in
                NavigationLink {
                    EventDetailView(event: event)
                } label: {
                    EventRow(event: event)
                }
                .contextMenu { EventActions(event: event) }
                .listRowBackground(event.hasWarnings ? Theme.clientError.opacity(0.05) : Theme.ground)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12))
                .listRowSeparatorTint(Theme.hairline)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .overlay { if model.visible.isEmpty { emptyState } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Exports what's on screen: the current search and filters apply.
                Menu {
                    let count = model.visible.count
                    Section("\(count) event\(count == 1 ? "" : "s") on screen") {
                        Button { Share.file(Data(TextLog.jsonLines(model.visible).utf8), named: "Events.jsonl") } label: {
                            Label("Share as JSON Lines", systemImage: "curlybraces")
                        }
                        Button {
                            Share.file(Data(model.visible.map { $0.report(.markdown) }.joined(separator: "\n\n---\n\n").utf8), named: "Events.md")
                        } label: {
                            Label("Share as Markdown log", systemImage: "doc.richtext")
                        }
                        Button { Share.copy(TextLog.jsonLines(model.visible), what: "\(count) events") } label: {
                            Label("Copy as JSON Lines", systemImage: "doc.on.doc")
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.visible.isEmpty)
                .accessibilityLabel("Export events")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatTile(title: "Events", value: "\(model.all.count)")
                StatTile(title: "Warnings", value: "\(model.warningCount)", color: model.warningCount > 0 ? Theme.clientError : Theme.text)
                StatTile(title: "Dropped", value: "\(model.droppedCount)", color: model.droppedCount > 0 ? Theme.failureText : Theme.text)
            }
            SearchField(text: $model.searchText, prompt: "Search name, property, value", label: "Search events")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: "All", isOn: !model.warningsOnly && !model.droppedOnly && model.destination == nil && model.kind == nil) {
                        model.warningsOnly = false
                        model.droppedOnly = false
                        model.destination = nil
                        model.kind = nil
                    }
                    Chip(title: "Warnings · \(model.warningCount)", isOn: model.warningsOnly) { model.warningsOnly.toggle() }
                    if model.droppedCount > 0 {
                        Chip(title: "Dropped · \(model.droppedCount)", isOn: model.droppedOnly) { model.droppedOnly.toggle() }
                    }
                    ForEach(model.kindCounts, id: \.kind) { item in
                        Chip(title: "\(item.kind.pluralLabel) · \(item.count)", isOn: model.kind == item.kind) {
                            model.kind = model.kind == item.kind ? nil : item.kind
                        }
                    }
                    ForEach(model.destinations, id: \.self) { destination in
                        Chip(title: destination, isOn: model.destination == destination) {
                            model.destination = model.destination == destination ? nil : destination
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.all.isEmpty ? "waveform.path.ecg" : "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(Theme.tertiaryText)
            Text(model.all.isEmpty ? "No events yet" : "Nothing matches")
                .foregroundStyle(Theme.secondaryText)
            if model.all.isEmpty {
                Text(model.store.isPaused ? "Capture is paused" : "Events appear when the app tracks them")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.top, 220)
        .allowsHitTesting(false)
    }
}

struct EventRow: View {
    let event: EventRecord

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(event.hasWarnings ? Theme.clientError : Theme.event.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let icon = event.kind.systemImage {
                        Image(systemName: icon).font(.caption2)
                            .foregroundStyle(event.kind == .error ? Theme.failureText : Theme.tertiaryText)
                            .accessibilityLabel(event.kind.label)
                    }
                    Text(event.name)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if event.hasWarnings {
                        Text("\(event.warnings.count)")
                            .font(.system(.caption2, design: .monospaced).weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.clientError.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.warningText)
                            .accessibilityLabel("\(event.warnings.count) warnings")
                    }
                }
                HStack(spacing: 4) {
                    DestinationChips(event: event)
                    if let source = event.source {
                        Text(source).font(.caption2).foregroundStyle(Theme.tertiaryText).lineLimit(1).padding(.leading, 4)
                    }
                }
            }
            .padding(.vertical, 10)
            Spacer(minLength: 8)
            Text(Format.age(event.date))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }
}

extension EventRecord.Kind {
    var pluralLabel: String {
        switch self {
        case .event: "Events"
        case .screenView: "Screens"
        case .identity: "Identity"
        case .log: "Logs"
        case .error: "Errors"
        }
    }

    /// Nil for plain events, the common case.
    var systemImage: String? {
        switch self {
        case .event: nil
        case .screenView: "rectangle.portrait"
        case .identity: "person.crop.circle"
        case .log: "text.alignleft"
        case .error: "exclamationmark.octagon"
        }
    }
}

/// FIR · CT · ADJ, with dropped destinations struck through in red.
struct DestinationChips: View {
    let event: EventRecord

    var body: some View {
        HStack(spacing: 4) {
            ForEach(event.deliveries.map(\.destination), id: \.self) { chip($0, dropped: false) }
            ForEach(event.dropped, id: \.self) { chip($0, dropped: true) }
        }
    }

    private func chip(_ destination: String, dropped: Bool) -> some View {
        Text(Destination.shortName(destination))
            .font(.system(.caption2, design: .monospaced).weight(.medium))
            .strikethrough(dropped)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(dropped ? Theme.failure.opacity(0.16) : Theme.hairline, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(dropped ? Theme.failureText : Theme.secondaryText)
            .accessibilityLabel(dropped ? "\(destination), dropped" : destination)
    }
}
#endif
