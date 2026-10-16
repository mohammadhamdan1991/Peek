#if !PEEK_DISABLED
import Foundation
import os

/// Bounded, thread-safe, in-memory log. Callable synchronously from any thread so capture keeps call order
/// and never waits on the UI; evicts oldest-first past `Limits.count` or `Limits.bytes`.
public final class RecordStore<Record: InspectorRecord>: Sendable {
    public struct Limits: Sendable {
        public var count: Int
        public var bytes: Int
        public init(count: Int, bytes: Int) {
            self.count = count
            self.bytes = bytes
        }
    }

    private struct State: Sendable {
        var records: [Record] = []
        var bytes = 0
        var isPaused: Bool
        var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

        /// Drops the oldest records until both limits hold.
        mutating func evict(to limits: Limits) {
            // ponytail: Array.removeFirst is O(n); fine at 1k records, switch to a ring index if limits grow 10x.
            var evicted = 0
            while evicted < records.count, records.count - evicted > limits.count || bytes > limits.bytes {
                bytes -= records[evicted].byteCost
                evicted += 1
            }
            records.removeFirst(evicted)
        }
    }

    public let limits: Limits
    private let state: OSAllocatedUnfairLock<State>

    /// Stores start paused: nothing is kept until the inspector passes its runtime gate and resumes them.
    public init(limits: Limits, isPaused: Bool = true) {
        self.limits = limits
        state = OSAllocatedUnfairLock(initialState: State(isPaused: isPaused))
    }

    /// Adds `record`, or replaces the one with the same id (a request completing).
    public func record(_ record: Record) {
        let observers = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            guard !s.isPaused else { return [] }
            if let index = s.records.lastIndex(where: { $0.id == record.id }) {
                s.bytes += record.byteCost - s.records[index].byteCost
                s.records[index] = record
            } else {
                s.records.append(record)
                s.bytes += record.byteCost
            }
            s.evict(to: limits)
            return Array(s.observers.values)
        }
        observers.forEach { $0.yield() }
    }

    /// Mutates the record with `id` in place, paused or not. Returns false if it isn't there (never recorded, cleared, evicted).
    @discardableResult
    public func update(id: UUID, _ change: (inout Record) -> Void) -> Bool {
        // Unchecked: `change` runs synchronously under the lock and is never stored.
        let observers = state.withLockUnchecked { s -> [AsyncStream<Void>.Continuation]? in
            guard let index = s.records.lastIndex(where: { $0.id == id }) else { return nil }
            let before = s.records[index].byteCost
            change(&s.records[index])
            s.bytes += s.records[index].byteCost - before
            s.evict(to: limits)
            return Array(s.observers.values)
        }
        observers?.forEach { $0.yield() }
        return observers != nil
    }

    public var records: [Record] { state.withLock { $0.records } }
    public var byteCount: Int { state.withLock { $0.bytes } }

    public var isPaused: Bool {
        get { state.withLock { $0.isPaused } }
        set {
            let observers = state.withLock { s in
                s.isPaused = newValue
                return Array(s.observers.values)
            }
            observers.forEach { $0.yield() }
        }
    }

    public func clear() {
        let observers = state.withLock { s in
            s.records.removeAll()
            s.bytes = 0
            return Array(s.observers.values)
        }
        observers.forEach { $0.yield() }
    }

    /// Fires after every change. Coalesces: a slow reader sees one pending tick, not a backlog.
    public func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}
#endif
