#if !PEEK_DISABLED && canImport(UIKit)
import Combine
import Foundation
import PeekCore

/// One row of the network list: an HTTP attempt, a socket message, or (with "+ Events") an analytics event.
enum NetworkItem: Identifiable {
    case http(HTTPRecord)
    case socket(SocketRecord)
    case event(EventRecord)

    var id: UUID {
        switch self {
        case let .http(record): record.id
        case let .socket(record): record.id
        case let .event(record): record.id
        }
    }

    var date: Date {
        switch self {
        case let .http(record): record.startedAt
        case let .socket(record): record.date
        case let .event(record): record.date
        }
    }
}

/// One socket.io connection (url + namespace), summarised from its messages.
struct SocketConnection: Identifiable {
    enum State { case connected, reconnecting, disconnected, unknown }

    let id: String
    let host: String
    let namespace: String
    var state: State = .unknown
    var incoming = 0
    var outgoing = 0
    var reconnects = 0
    var since: Date?
}

/// Snapshot of the HTTP and socket stores for the network screens. Filtering happens here, never in a view `body`.
@MainActor
final class NetworkListModel: ObservableObject {
    enum Kind: Equatable { case all, http, socket }

    /// Debounced: free text searches bodies, too costly per keystroke on a full store.
    @Published var searchText = "" { didSet { scheduleFilter() } }
    @Published var errorsOnly = false { didSet { applyFilter() } }
    @Published var module: String? { didSet { applyFilter() } }
    @Published var kind = Kind.all { didSet { applyFilter() } }
    /// Mixes analytics events into the list: one timeline of what the app sent and tracked.
    @Published var showsEvents = false { didSet { applyFilter() } }

    @Published private(set) var all: [HTTPRecord] = []          // newest first
    @Published private(set) var sockets: [SocketRecord] = []    // newest first
    @Published private(set) var events: [EventRecord] = []      // newest first
    @Published private(set) var visible: [HTTPRecord] = []
    @Published private(set) var items: [NetworkItem] = []
    @Published private(set) var modules: [String] = []
    @Published private(set) var connections: [SocketConnection] = []
    @Published private(set) var query = NetworkQuery()

    let store: RecordStore<HTTPRecord>
    let socketStore: RecordStore<SocketRecord>
    let eventStore: RecordStore<EventRecord>
    @Published private(set) var failureCount = 0
    @Published private(set) var medianDuration: TimeInterval?
    private var tasks: [Task<Void, Never>] = []
    private var filterTask: Task<Void, Never>?
    private var redactionChange: AnyCancellable?

    init(store: RecordStore<HTTPRecord>, socketStore: RecordStore<SocketRecord>, eventStore: RecordStore<EventRecord> = Inspector.events) {
        self.store = store
        self.socketStore = socketStore
        self.eventStore = eventStore
        let streams = [store.updates(), socketStore.updates(), eventStore.updates()] // subscribe before the first read
        reload()
        redactionChange = NotificationCenter.default.publisher(for: Inspector.redactionDidChange)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        tasks = streams.map { updates in
            Task { [weak self] in
                for await _ in updates {
                    self?.reload()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    deinit {
        tasks.forEach { $0.cancel() }
        filterTask?.cancel()
    }

    func record(_ id: UUID) -> HTTPRecord? { all.first { $0.id == id } }
    func socket(_ id: UUID) -> SocketRecord? { sockets.first { $0.id == id } }

    /// Every attempt of the same call, oldest first.
    func attempts(of record: HTTPRecord) -> [HTTPRecord] {
        guard let correlation = record.correlationID else { return [record] }
        return all.filter { $0.correlationID == correlation }.reversed()
    }

    func connection(for record: SocketRecord) -> SocketConnection? {
        connections.first { $0.id == Self.connectionID(record) }
    }

    private func reload() {
        // Stored records are the redacted copy; with redaction off, show the real values.
        let redacted = Inspector.redaction.isEnabled
        all = store.records.reversed().map { $0.displayed(redacted: redacted) }
        sockets = socketStore.records.reversed().map { $0.displayed(redacted: redacted) }
        events = eventStore.records.reversed().map { $0.displayed(redacted: redacted) }
        modules = Array(Set(all.compactMap(\.module))).sorted()
        connections = Self.summarise(sockets)
        failureCount = all.reduce(0) { $0 + ($1.isFailure ? 1 : 0) }
        let durations = all.compactMap(\.duration).sorted()
        medianDuration = durations.isEmpty ? nil : durations[durations.count / 2]
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
        let raw = module.map { searchText + " module:\($0.replacingOccurrences(of: " ", with: "_"))" } ?? searchText
        let query = NetworkQuery(raw, errorsOnly: errorsOnly)
        self.query = query
        visible = query.isEmpty ? all : all.filter(query.matches)
        let http = kind == .socket ? [] : visible.map(NetworkItem.http)
        let socket = kind == .http ? [] : (query.isEmpty ? sockets : sockets.filter(query.matches)).map(NetworkItem.socket)
        // Events answer free text and "Errors" (= has warnings); `key:value` tokens are about requests, so they hide events.
        let event = !showsEvents || kind != .all || !query.tokens.isEmpty ? [] : events.filter { event in
            (!errorsOnly || event.hasWarnings) && (query.text.isEmpty || EventListModel.matches(event, query.text))
        }.map(NetworkItem.event)
        // All inputs are newest-first; the stable sort keeps that order between equal dates.
        items = (http + socket + event).sorted { $0.date > $1.date }
    }

    private static func connectionID(_ record: SocketRecord) -> String {
        "\(record.url?.host ?? "?")\(record.namespace)"
    }

    private static func summarise(_ sockets: [SocketRecord]) -> [SocketConnection] {
        var byID: [String: SocketConnection] = [:]
        for record in sockets.reversed() { // oldest first, so the latest lifecycle event wins
            let id = connectionID(record)
            var connection = byID[id] ?? SocketConnection(id: id, host: record.url?.host ?? "?", namespace: record.namespace)
            switch (record.direction, record.name) {
            case (.incoming, _): connection.incoming += 1
            case (.outgoing, _): connection.outgoing += 1
            case (.lifecycle, "connect"):
                connection.state = .connected
                connection.since = record.date
            case (.lifecycle, "disconnect"):
                connection.state = .disconnected
                connection.since = record.date
            case (.lifecycle, "reconnectAttempt"):
                connection.state = .reconnecting
                connection.reconnects += 1
            default: break
            }
            byID[id] = connection
        }
        return byID.values.sorted { $0.id < $1.id }
    }
}
#endif
