import Foundation
import os

/// Binds each verified pairing-invite nonce to the first joiner inbox
/// that presented it, so a slug captured in transit (photographed QR,
/// leaked pair URL) can't be replayed by a different inbox to pop an
/// unsolicited PIN sheet while the original is still unexpired. The
/// legitimate joiner re-sends its request on a fixed cadence and always
/// matches its own binding.
///
/// Process-wide singleton because more than one `StreamProcessor` exists
/// per process (the syncing manager's and the conversation state
/// machine's) and a replay can arrive on either. In-memory only: slugs
/// expire within minutes, so a process restart forgetting bindings
/// re-opens nothing beyond what expiry already allows.
public final class PairingNonceLedger: Sendable {
    public static let shared: PairingNonceLedger = PairingNonceLedger()

    private struct Binding {
        let joinerInboxId: String
        let boundAt: Date
    }

    private let bindings: OSAllocatedUnfairLock<[Data: Binding]> = .init(initialState: [:])

    init() {}

    /// The joiner inbox the nonce is bound to, if any unexpired binding
    /// exists.
    public func joiner(for nonce: Data) -> String? {
        bindings.withLock { state in
            prune(&state)
            return state[nonce]?.joinerInboxId
        }
    }

    /// Binds the nonce to the joiner. First writer wins; rebinding the
    /// same pair refreshes the timestamp so a long handshake's resends
    /// keep the binding alive.
    public func bind(nonce: Data, toJoiner joinerInboxId: String) {
        bindings.withLock { state in
            prune(&state)
            if let existing = state[nonce], existing.joinerInboxId != joinerInboxId {
                return
            }
            state[nonce] = Binding(joinerInboxId: joinerInboxId, boundAt: Date())
        }
    }

    /// Drops bindings comfortably older than any slug's validity window,
    /// keeping the table bounded without a timer.
    private func prune(_ state: inout [Data: Binding]) {
        let cutoff = Date().addingTimeInterval(-Constant.retention)
        state = state.filter { $0.value.boundAt > cutoff }
    }

    private enum Constant {
        /// Longest slug validity in the codebase is the iCloud-discovery
        /// flow's 300s window; double it for clock skew headroom.
        static let retention: TimeInterval = 600
    }
}
