import Foundation
import os

/// Binds each verified pairing-invite nonce to the first joiner inbox
/// that presented it, so a slug captured in transit (photographed QR,
/// leaked pair URL) can't be replayed by a different inbox to pop an
/// unsolicited PIN sheet or pairing banner while the original is still
/// unexpired. The legitimate joiner re-sends its request on a fixed
/// cadence and always matches its own binding.
///
/// Process-wide singleton because more than one `StreamProcessor` exists
/// per process (the syncing manager's and the conversation state
/// machine's) and a replay can arrive on either. Optionally backed by
/// app-group storage (see `configure(appGroup:)`) so bindings also span
/// processes: the Notification Service Extension is a fresh process per
/// push, and without a shared backing its ledger would always be empty.
/// Bindings expire within minutes either way, so losing them re-opens
/// nothing beyond what slug expiry already allows.
public final class PairingNonceLedger: Sendable {
    public static let shared: PairingNonceLedger = PairingNonceLedger()

    private struct Binding {
        let joinerInboxId: String
        let boundAt: Date
    }

    private struct State {
        var bindings: [Data: Binding] = [:]
        var appGroup: String?
    }

    private let state: OSAllocatedUnfairLock<State> = .init(initialState: State())

    init() {}

    /// Backs the ledger with app-group UserDefaults so the app and the
    /// NSE share bindings. Call once per process at messaging bootstrap;
    /// later calls are ignored. Without this the ledger is in-memory
    /// only, which is sufficient inside one long-lived process but blind
    /// to bindings made by the other.
    public func configure(appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            Log.warning("PairingNonceLedger: app-group suite unavailable, staying in-memory")
            return
        }
        // Pre-release builds stored the whole ledger under one key; the
        // blob is unreadable by the per-key format, so clear the residue.
        defaults.removeObject(forKey: "convos.pairing.nonceLedger.v1")
        state.withLock { state in
            guard state.appGroup == nil else { return }
            state.appGroup = appGroup
        }
    }

    /// The joiner inbox the nonce is bound to, if any unexpired binding
    /// exists.
    public func joiner(for nonce: Data) -> String? {
        state.withLock { state in
            mergePersisted(into: &state)
            prune(&state.bindings)
            return state.bindings[nonce]?.joinerInboxId
        }
    }

    /// Binds the nonce to the joiner. First writer wins; rebinding the
    /// same pair refreshes the timestamp so a long handshake's resends
    /// keep the binding alive.
    public func bind(nonce: Data, toJoiner joinerInboxId: String) {
        state.withLock { state in
            mergePersisted(into: &state)
            prune(&state.bindings)
            if let existing = state.bindings[nonce], existing.joinerInboxId != joinerInboxId {
                return
            }
            let binding = Binding(joinerInboxId: joinerInboxId, boundAt: Date())
            state.bindings[nonce] = binding
            persist(nonce: nonce, binding: binding, appGroup: state.appGroup)
        }
    }

    /// Folds the other process's persisted bindings into memory, and
    /// deletes expired persisted entries along the way. On a joiner
    /// conflict the earlier binding wins, preserving first-writer-wins
    /// across processes.
    private func mergePersisted(into state: inout State) {
        guard let appGroup = state.appGroup,
              let defaults = UserDefaults(suiteName: appGroup),
              let domain = defaults.persistentDomain(forName: appGroup) else { return }
        let cutoff = Date().addingTimeInterval(-Constant.retention)
        for (key, value) in domain where key.hasPrefix(Constant.keyPrefix) {
            guard let nonce = Data(base64Encoded: String(key.dropFirst(Constant.keyPrefix.count))),
                  let entry = value as? [String: Any],
                  let joiner = entry[Constant.joinerField] as? String,
                  let timestamp = entry[Constant.boundAtField] as? TimeInterval else {
                defaults.removeObject(forKey: key)
                continue
            }
            let persisted = Binding(joinerInboxId: joiner, boundAt: Date(timeIntervalSince1970: timestamp))
            guard persisted.boundAt > cutoff else {
                defaults.removeObject(forKey: key)
                continue
            }
            if let existing = state.bindings[nonce],
               existing.joinerInboxId != persisted.joinerInboxId,
               existing.boundAt <= persisted.boundAt {
                continue
            }
            state.bindings[nonce] = persisted
        }
    }

    /// Writes one binding under its own per-nonce key. Whole-ledger
    /// snapshot writes would race the other process: the app binding
    /// nonce A and the NSE binding nonce B concurrently would each
    /// overwrite the other's entry, silently dropping replay-guard
    /// state. Per-key writes only ever touch the caller's own nonce.
    private func persist(nonce: Data, binding: Binding, appGroup: String?) {
        guard let appGroup,
              let defaults = UserDefaults(suiteName: appGroup) else { return }
        let entry: [String: Any] = [
            Constant.joinerField: binding.joinerInboxId,
            Constant.boundAtField: binding.boundAt.timeIntervalSince1970,
        ]
        defaults.set(entry, forKey: Constant.keyPrefix + nonce.base64EncodedString())
    }

    /// Drops bindings comfortably older than any slug's validity window,
    /// keeping the table bounded without a timer. Persisted entries are
    /// pruned as they're encountered in `mergePersisted`.
    private func prune(_ bindings: inout [Data: Binding]) {
        let cutoff = Date().addingTimeInterval(-Constant.retention)
        bindings = bindings.filter { $0.value.boundAt > cutoff }
    }

    private enum Constant {
        /// Longest slug validity in the codebase is the iCloud-discovery
        /// flow's 300s window; double it for clock skew headroom.
        static let retention: TimeInterval = 600
        static let keyPrefix: String = "convos.pairing.nonceLedger.v2."
        static let joinerField: String = "j"
        static let boundAtField: String = "t"
    }
}
