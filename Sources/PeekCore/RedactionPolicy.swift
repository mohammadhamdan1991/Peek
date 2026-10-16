#if !PEEK_DISABLED
import Foundation
import os

/// The redaction rules, and whether the panel shows redacted data. Shared by HTTP, socket and event capture.
///
/// Capture always stores both copies: the redacted values, and the real ones (in memory only, never written to
/// disk). `isEnabled` only picks which one the panel shows and exports, so switching it off reveals everything
/// already captured, and switching it back hides it again.
public final class RedactionPolicy: Sendable {
    private struct State: Sendable {
        var redactor: Redactor
        var isEnabled: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(redactor: Redactor = .default, isEnabled: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(redactor: redactor, isEnabled: isEnabled))
    }

    /// True: show and export the redacted copy. False: the real values.
    public var isEnabled: Bool {
        get { state.withLock { $0.isEnabled } }
        set { state.withLock { $0.isEnabled = newValue } }
    }

    public func setRedactor(_ redactor: Redactor) {
        state.withLock { $0.redactor = redactor }
    }

    /// The rules capture applies to build the redacted copy.
    public var redactor: Redactor {
        state.withLock { $0.redactor }
    }
}
#endif
