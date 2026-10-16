#if !PEEK_DISABLED && canImport(UIKit)
import Foundation
import PeekCore

/// What the floating button and the panel show. Refreshed from the store at most 4 times a second.
@MainActor
final class InspectorModel: ObservableObject {
    let environmentTag: String

    @Published private(set) var requestCount = 0
    @Published private(set) var failureCount = 0
    @Published private(set) var unseenFailures = 0
    @Published private(set) var medianDuration: TimeInterval?
    @Published private(set) var isPaused = false
    @Published var isRedactionEnabled = Inspector.isRedactionEnabled {
        didSet {
            guard isRedactionEnabled != oldValue else { return }
            Inspector.isRedactionEnabled = isRedactionEnabled
            Toast.shared.show(isRedactionEnabled ? "Secrets hidden" : "Showing real tokens and personal data")
        }
    }

    private var seenFailures = 0

    init(environmentTag: String) {
        self.environmentTag = environmentTag
    }

    /// Failed requests and events with warnings both count as problems for the badge.
    func refresh(from store: RecordStore<HTTPRecord>, events: RecordStore<EventRecord>) {
        let records = store.records
        requestCount = records.count
        failureCount = records.reduce(0) { $0 + ($1.isFailure ? 1 : 0) } + events.records.reduce(0) { $0 + ($1.hasWarnings ? 1 : 0) }
        seenFailures = min(seenFailures, failureCount) // evicted failures were seen or are gone
        unseenFailures = failureCount - seenFailures
        let durations = records.compactMap(\.duration).sorted()
        medianDuration = durations.isEmpty ? nil : durations[durations.count / 2]
        isPaused = store.isPaused
    }

    func markSeen() {
        seenFailures = failureCount
        unseenFailures = 0
    }

    var accessibilitySummary: String {
        var parts = ["\(requestCount) requests"]
        if unseenFailures > 0 { parts.append("\(unseenFailures) new problems") }
        if isPaused { parts.append("capture paused") }
        return parts.joined(separator: ", ")
    }
}
#endif
