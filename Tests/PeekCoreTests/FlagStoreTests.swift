#if !PEEK_DISABLED
import Foundation
import os
import Testing
@testable import PeekCore

@Suite struct FlagStoreTests {
    private func store(enabled: Bool = true, defaults: UserDefaults? = nil) -> FlagStore {
        let store = FlagStore(defaults: defaults)
        store.isEnabled = enabled
        return store
    }

    @Test func servesOverridesOnlyWhileEnabled() {
        let flags = store(enabled: false)
        flags.setOverride(.bool(true), for: "tips")
        #expect(flags.override(for: "tips") == nil)
        flags.isEnabled = true
        #expect(flags.override(for: "tips") == .bool(true))
        flags.setOverride(nil, for: "tips")
        #expect(flags.override(for: "tips") == nil)
    }

    @Test func listsCatalogReadsAndOverridesOverriddenFirst() {
        let flags = store()
        flags.setCatalog(source: "LaunchDarkly") { ["b_remote": .bool(false), "a_remote": .number(8)] }
        flags.didRead("c_read_only", remote: nil, defaultValue: .string("x"))
        flags.didRead("c_read_only", remote: nil, defaultValue: .string("x"))
        flags.setOverride(.number(15), for: "z_overridden")

        let list = flags.flags
        #expect(list.map(\.key) == ["z_overridden", "a_remote", "b_remote", "c_read_only"])
        #expect(list[0].value == .number(15))
        #expect(list[3].reads == 2)
        #expect(list[3].value == .string("x"))
        #expect(flags.source == "LaunchDarkly")
    }

    @Test func tellsListenersWhichFlagChanged() {
        let flags = store()
        let changed = OSAllocatedUnfairLockBox<[String]>([])
        flags.onOverrideChange { key in changed.mutate { $0.append(key) } }
        flags.setOverride(.bool(true), for: "a")
        flags.setOverride(.bool(true), for: "b")
        flags.removeAllOverrides()
        #expect(changed.value.prefix(2) == ["a", "b"])
        #expect(Set(changed.value.dropFirst(2)) == ["a", "b"])
        #expect(flags.overrideCount == 0)
    }

    @Test func overridesSurviveRelaunch() throws {
        let suite = "dev.peek.flags.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        store(defaults: defaults).setOverride(.object(["max_km": .number(25), "zones": .array([.string("ALG")])]), for: "cfg")
        let relaunched = store(defaults: defaults)
        #expect(relaunched.override(for: "cfg") == .object(["max_km": .number(25), "zones": .array([.string("ALG")])]))
    }

    @Test(arguments: [
        ("true", FlagValue.bool(true)),
        ("12.5", .number(12.5)),
        ("1", .number(1)),
        ("\"ALG\"", .string("ALG")),
        ("null", .null),
        ("{\"a\":[1,false]}", .object(["a": .array([.number(1), .bool(false)])])),
    ])
    func parsesJSON(text: String, value: FlagValue) {
        #expect(FlagValue(json: text) == value)
        #expect(FlagValue(json: value.json()) == value)
    }

    @Test func rejectsInvalidJSON() {
        #expect(FlagValue(json: "{max_km: 25}") == nil)
        #expect(FlagValue(json: "") == nil)
    }

    @Test func summarisesContainers() {
        #expect(FlagValue.object(["a": .null, "b": .null]).summary == "{ 2 }")
        #expect(FlagValue.array([.null]).summary == "[ 1 ]")
        #expect(FlagValue.bool(false).summary == "false")
    }
}

/// A tiny lock-protected box for collecting values from `@Sendable` callbacks.
private final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Value { lock.withLock { $0 } }
    func mutate(_ body: @Sendable (inout Value) -> Void) { lock.withLock { body(&$0) } }
}
#endif
