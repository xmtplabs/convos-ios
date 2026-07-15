import Foundation

/// Progress events for the account-deletion flow, in emission order.
public enum AccountDeletionProgress: Sendable, Equatable {
    /// Backend deletion request in flight (keys intact, nothing wiped).
    case requestingBackendDeletion
    /// Best-effort XMTP installation teardown after backend confirmation.
    case revokingDevices
    /// Manifest-driven local wipe.
    case wipingLocalData
    case completed
}

public enum AccountDeletionError: Error {
    /// The identity keys are absent or unreadable (and no cached token can
    /// confirm a pending request); true deletion is impossible from this
    /// device right now. Nothing was wiped.
    case identityUnavailable
    /// A pre-send step (token mint, App Check) failed, so the deletion
    /// request was provably never sent. The record was cleared and keys
    /// are intact; the user can simply retry.
    case preflightFailed(underlying: any Error)
    /// The deletion request failed or its outcome is ambiguous. The record
    /// stays in `requested` with keys intact; launch recovery (or an
    /// explicit retry) resolves it.
    case backendRequestFailed(underlying: any Error)
    /// The local wipe did not fully complete. The record stays in
    /// `localWipePending`; the next launch re-runs the manifest.
    case wipeIncomplete(failures: [WipeManifestFailure])
}

/// Seams the deletion flow drives, injected so the whole state machine is
/// testable on macOS with plain closures (no network, no Firebase, no live
/// session).
public struct AccountDeletionDependencies: Sendable {
    /// Reads the on-device identity (nil when the keychain slot is empty).
    public var loadIdentity: @Sendable () throws -> KeychainIdentity?
    /// Stable device identifier for keychain slot names.
    public var deviceId: @Sendable () -> String
    /// Ethereum address for the identity's key (for address-scoped slots).
    public var ethAddress: @Sendable (KeychainIdentity) -> String
    /// Mints an account JWT from stored keys, session-independently
    /// (App Check -> nonce -> sign -> token). Throws
    /// `SIWEAuthError.identityDeleted` when the deletion barrier is hit.
    public var mintToken: @Sendable (KeychainIdentity) async throws -> String
    /// Reads a still-cached account JWT for the record's identity (by the
    /// record's deviceId + ethAddress slot name), if one survives. The
    /// last-resort confirmation path when the identity keys are gone but a
    /// pre-deletion token may still be unexpired.
    public var cachedToken: @Sendable (AccountDeletionRecord) -> String?
    /// `DELETE /v2/accounts/me` with a directly injected JWT.
    public var requestDeletion: @Sendable (UUID, String) async throws -> ConvosAPI.AccountDeletionResponse
    /// Suspends/resumes the automatic 401 re-authentication, process-wide.
    public var setReauthSuspended: @Sendable (Bool) -> Void
    /// Best-effort, bounded XMTP protocol teardown (installation
    /// revocation). Runs only from `backendConfirmed` (keys still exist);
    /// a resume from `localWipePending` skips it.
    public var revokeInstallations: @Sendable (AccountDeletionRecord) async -> Void
    /// Stops live services (bootstrap tasks, cached messaging service)
    /// before the wipe so nothing rebuilds an inbox mid-teardown.
    public var stopServices: @Sendable () async -> Void
    /// Executor over the wipe-manifest handlers.
    public var makeWipeExecutor: @Sendable () -> WipeManifestExecutor
    /// Deletes only the record-scoped slots (address-scoped SIWE JWT and
    /// account-id slots, the record identity's synced backup). Used when a
    /// record's identity was displaced (pairing) and the full manifest
    /// must not run against the new identity.
    public var sweepRecordScopedSlots: @Sendable (AccountDeletionRecord) async -> Void

    public init(
        loadIdentity: @escaping @Sendable () throws -> KeychainIdentity?,
        deviceId: @escaping @Sendable () -> String,
        ethAddress: @escaping @Sendable (KeychainIdentity) -> String,
        mintToken: @escaping @Sendable (KeychainIdentity) async throws -> String,
        cachedToken: @escaping @Sendable (AccountDeletionRecord) -> String?,
        requestDeletion: @escaping @Sendable (UUID, String) async throws -> ConvosAPI.AccountDeletionResponse,
        setReauthSuspended: @escaping @Sendable (Bool) -> Void,
        revokeInstallations: @escaping @Sendable (AccountDeletionRecord) async -> Void,
        stopServices: @escaping @Sendable () async -> Void,
        makeWipeExecutor: @escaping @Sendable () -> WipeManifestExecutor,
        sweepRecordScopedSlots: @escaping @Sendable (AccountDeletionRecord) async -> Void
    ) {
        self.loadIdentity = loadIdentity
        self.deviceId = deviceId
        self.ethAddress = ethAddress
        self.mintToken = mintToken
        self.cachedToken = cachedToken
        self.requestDeletion = requestDeletion
        self.setReauthSuspended = setReauthSuspended
        self.revokeInstallations = revokeInstallations
        self.stopServices = stopServices
        self.makeWipeExecutor = makeWipeExecutor
        self.sweepRecordScopedSlots = sweepRecordScopedSlots
    }
}

/// Orchestrates account deletion end to end: durable record first, backend
/// deletion while the keys still exist, best-effort protocol teardown, then
/// the manifest-driven local wipe. Also owns launch recovery for every
/// crash window (see `recoverAtLaunch`).
///
/// Invariants enforced here:
/// - The record is bound to an identity: nothing is ever minted, deleted,
///   or wiped using an identity that does not match the record's
///   inboxId/clientId/ethAddress (pairing can displace the identity while
///   a deletion is pending).
/// - A `requested` record is never resolved by a local wipe alone; only
///   the deletion endpoint's 200 or the barrier's terminal mint response
///   confirms. A surviving cached token is retried as a last resort when
///   the keys are gone; otherwise the record holds.
/// - All entry points (user flow, launch recovery, remote-deletion wipe)
///   are single-flighted: a second caller joins the in-flight run instead
///   of interleaving with it across actor suspension points.
public actor AccountDeletionService {
    private let store: AccountDeletionStateStore
    private let dependencies: AccountDeletionDependencies
    /// In-flight run, if any. Actor isolation alone does not serialize
    /// whole flows (reentrancy interleaves at suspension points), so every
    /// public entry point funnels through `singleFlight`.
    private var activeRun: Task<Void, any Error>?

    public init(store: AccountDeletionStateStore, dependencies: AccountDeletionDependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    /// Current durable deletion state (for the settings pending-retry UI
    /// and the provisioning gate).
    public nonisolated func status() -> AccountDeletionLoadResult {
        store.load()
    }

    // MARK: - Entry points (single-flighted)

    /// Runs the deletion flow. Resumable: if a record already exists, the
    /// flow continues from its phase (same operation id across retries of
    /// one deletion, per the backend contract). A caller arriving while
    /// another run is in flight joins that run.
    public func deleteAccount(
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void
    ) async throws {
        try await singleFlight {
            try await self.performDeleteAccount(onProgress: onProgress)
        }
    }

    /// Resolves a pending deletion at cold launch. Never throws: recovery
    /// is best-effort at launch, and a failure leaves the durable record in
    /// place for the next attempt.
    public func recoverAtLaunch() async {
        do {
            try await singleFlight {
                await self.performRecoverAtLaunch()
            }
        } catch {
            Log.error("AccountDeletion: launch recovery run failed: \(error)")
        }
    }

    /// Paired-device exit: the backend already deleted the account (the
    /// terminal identity-deleted response arrived outside any local
    /// deletion flow). Writes a `backendConfirmed` record first so a crash
    /// mid-wipe resumes, then runs the normal teardown. No backend call is
    /// made or possible.
    public func wipeAfterRemoteDeletion(
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void = { _ in }
    ) async throws {
        try await singleFlight {
            try await self.performWipeAfterRemoteDeletion(onProgress: onProgress)
        }
    }

    private func singleFlight(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let running = activeRun {
            // Join the in-flight run: every entry point operates on the
            // same durable record, so the first run's outcome is the
            // outcome.
            try await running.value
            return
        }
        let task = Task { try await operation() }
        activeRun = task
        defer { activeRun = nil }
        try await task.value
    }

    // MARK: - User-initiated flow

    private func performDeleteAccount(
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void
    ) async throws {
        dependencies.setReauthSuspended(true)

        var existingRecord: AccountDeletionRecord?
        switch store.load() {
        case .record(let existing):
            let identity = try? dependencies.loadIdentity()
            if let identity, !matches(existing, identity) {
                // The pending record belongs to keys this device no longer
                // holds (pairing displaced them). Never mint or wipe with
                // the new identity under the old record; resolve the old
                // record as far as a surviving cached token allows, sweep
                // only its record-scoped slots, then honor the user's
                // explicit intent to delete the current account.
                await resolveDisplacedRecord(existing)
                existingRecord = nil
            } else {
                existingRecord = existing
            }
        case .none, .corrupted:
            // A corrupt record file is replaced by this explicit,
            // re-confirmed deletion; `begin` documents that trade.
            existingRecord = nil
        }

        let active: AccountDeletionRecord
        let createdFresh: Bool
        if let existingRecord {
            active = existingRecord
            createdFresh = false
        } else {
            active = try await beginFreshRecord()
            createdFresh = true
        }

        switch active.phase {
        case .requested:
            onProgress(.requestingBackendDeletion)
            let confirmed = try await confirmRequested(active, clearRecordOnPreflightFailure: createdFresh)
            try await runTeardown(from: confirmed, onProgress: onProgress)
        case .backendConfirmed, .localWipePending:
            try await resumeConfirmedTeardown(from: active, onProgress: onProgress)
        }
    }

    private func beginFreshRecord() async throws -> AccountDeletionRecord {
        let identity: KeychainIdentity?
        do {
            identity = try dependencies.loadIdentity()
        } catch {
            dependencies.setReauthSuspended(false)
            throw AccountDeletionError.identityUnavailable
        }
        guard let identity else {
            dependencies.setReauthSuspended(false)
            throw AccountDeletionError.identityUnavailable
        }
        let fresh = AccountDeletionRecord(
            operationId: UUID(),
            inboxId: identity.inboxId,
            clientId: identity.clientId,
            ethAddress: dependencies.ethAddress(identity),
            deviceId: dependencies.deviceId()
        )
        do {
            try await store.begin(fresh)
        } catch {
            // No record persisted and nothing sent: an otherwise healthy
            // session must not stay reauth-wedged.
            dependencies.setReauthSuspended(false)
            throw error
        }
        return fresh
    }

    // MARK: - Launch recovery

    /// The four launch situations: no record (normal startup), `requested`
    /// (retry while a token is mintable; only the barrier's terminal
    /// response or a deletion-endpoint 200 promotes), `backendConfirmed` /
    /// `localWipePending` (resume the wipe, no auth needed), and a corrupt
    /// record (hold provisioning, wait for explicit user action).
    private func performRecoverAtLaunch() async {
        switch store.load() {
        case .none:
            return
        case .corrupted:
            // Phase unknowable. Fail safe: hold provisioning (the store's
            // load result already does) and suspend re-auth; an explicit
            // user retry from settings writes a fresh record.
            dependencies.setReauthSuspended(true)
            Log.error("AccountDeletion: corrupt deletion record at launch; holding provisioning until explicit retry")
        case .record(let record):
            dependencies.setReauthSuspended(true)
            switch record.phase {
            case .requested:
                await recoverRequested(record)
            case .backendConfirmed, .localWipePending:
                do {
                    try await resumeConfirmedTeardown(from: record, onProgress: { _ in })
                } catch {
                    Log.error("AccountDeletion: wipe resume failed at launch; will retry next launch: \(error)")
                }
            }
        }
    }

    private func recoverRequested(_ record: AccountDeletionRecord) async {
        let identity: KeychainIdentity?
        do {
            identity = try dependencies.loadIdentity()
        } catch {
            Log.error("AccountDeletion: keychain unreadable during recovery; keeping record for retry: \(error)")
            return
        }
        guard let identity else {
            // Keys gone with the backend outcome unconfirmed. Never resolve
            // this with a local wipe: only a surviving pre-deletion token
            // can still confirm. Otherwise hold — record kept, provisioning
            // gated, re-auth suspended — until an explicit retry or a
            // future launch resolves it.
            if let confirmed = await confirmWithCachedToken(record) {
                do {
                    try await runTeardown(from: confirmed, onProgress: { _ in })
                } catch {
                    Log.error("AccountDeletion: wipe after cached-token confirmation failed; will resume next launch: \(error)")
                }
            } else {
                Log.error("AccountDeletion: requested record with no identity and no usable cached token; holding (no local wipe without backend confirmation)")
            }
            return
        }
        guard matches(record, identity) else {
            // Pairing displaced the record's identity. Resolve the old
            // record as far as possible without touching the new identity,
            // then lift the suspension so the live identity keeps working.
            await resolveDisplacedRecord(record)
            dependencies.setReauthSuspended(false)
            return
        }
        do {
            let confirmed = try await confirmRequested(record, clearRecordOnPreflightFailure: false)
            try await runTeardown(from: confirmed, onProgress: { _ in })
        } catch {
            // Keys intact, record stays `requested`; the settings row
            // surfaces "deletion pending" with a retry affordance.
            Log.warning("AccountDeletion: recovery retry did not resolve; record stays requested: \(error)")
        }
    }

    // MARK: - Remote-deletion wipe (paired device)

    private func performWipeAfterRemoteDeletion(
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void
    ) async throws {
        dependencies.setReauthSuspended(true)
        let identity = try? dependencies.loadIdentity()
        let record: AccountDeletionRecord
        switch store.load() {
        case .record(let existing):
            if let identity, !matches(existing, identity) {
                await resolveDisplacedRecord(existing)
                record = try await beginRemoteWipeRecord(identity: identity)
            } else {
                record = existing
            }
        case .none, .corrupted:
            record = try await beginRemoteWipeRecord(identity: identity)
        }
        try await runTeardown(from: record, onProgress: onProgress)
    }

    private func beginRemoteWipeRecord(identity: KeychainIdentity?) async throws -> AccountDeletionRecord {
        let fresh = AccountDeletionRecord(
            operationId: UUID(),
            inboxId: identity?.inboxId ?? "",
            clientId: identity?.clientId ?? "",
            ethAddress: identity.map { dependencies.ethAddress($0) } ?? "",
            deviceId: dependencies.deviceId()
        )
        try await store.begin(fresh)
        return try await store.advance(to: .backendConfirmed)
    }

    // MARK: - Confirmation

    /// Resolves a `requested` record to `backendConfirmed`. With matching
    /// identity keys, mints and calls the deletion endpoint; promotion
    /// happens only on the endpoint's 200 or the barrier's terminal
    /// identity-deleted response at mint. Everything else leaves keys
    /// intact and the outcome unconfirmed.
    private func confirmRequested(
        _ record: AccountDeletionRecord,
        clearRecordOnPreflightFailure: Bool
    ) async throws -> AccountDeletionRecord {
        let identity: KeychainIdentity?
        do {
            identity = try dependencies.loadIdentity()
        } catch {
            throw AccountDeletionError.identityUnavailable
        }
        guard let identity else {
            // Keys gone: the only remaining confirmation channel is a
            // surviving pre-deletion token.
            if let confirmed = await confirmWithCachedToken(record) {
                return confirmed
            }
            throw AccountDeletionError.identityUnavailable
        }
        guard matches(record, identity) else {
            // Callers route displaced records through
            // `resolveDisplacedRecord` before getting here; this is a
            // defensive backstop, never a deletion with the wrong keys.
            Log.error("AccountDeletion: identity does not match the pending record; refusing to mint or delete")
            throw AccountDeletionError.identityUnavailable
        }

        let jwt: String
        do {
            jwt = try await dependencies.mintToken(identity)
        } catch SIWEAuthError.identityDeleted {
            // Terminal barrier response: a prior attempt committed.
            return try await store.advance(to: .backendConfirmed)
        } catch {
            if clearRecordOnPreflightFailure {
                // The deletion request was provably never sent, so this
                // maps to the "no record, local intact" failure row:
                // clean failure, keys intact, plain retry from settings.
                // Reauth resumes only when the record is actually gone; a
                // surviving record keeps the suspension so launch recovery
                // retries it instead of silently diverging from the UI.
                do {
                    try await store.clear()
                    dependencies.setReauthSuspended(false)
                } catch {
                    Log.error("AccountDeletion: failed to clear record after pre-send failure; launch recovery will retry: \(error)")
                }
            }
            throw AccountDeletionError.preflightFailed(underlying: error)
        }

        do {
            let response = try await dependencies.requestDeletion(record.operationId, jwt)
            if response.operationId != record.operationId.uuidString.lowercased() {
                // Stored-record echo from a different operation: a prior
                // deletion already committed for this account.
                Log.info("AccountDeletion: endpoint echoed a different stored operationId; prior deletion had committed")
            }
            return try await store.advance(to: .backendConfirmed, purgeWindowHours: response.purgeWindowHours)
        } catch {
            // Sent but not confirmed (network drop, 429, 500, expired
            // token). Record stays `requested`, keys intact.
            throw AccountDeletionError.backendRequestFailed(underlying: error)
        }
    }

    /// Last-resort confirmation with a surviving pre-deletion JWT (15-min
    /// TTL) read from the record's own slot names. Returns the promoted
    /// record on a 200; nil for every failure (never a confirmation).
    private func confirmWithCachedToken(_ record: AccountDeletionRecord) async -> AccountDeletionRecord? {
        guard let token = dependencies.cachedToken(record) else { return nil }
        do {
            let response = try await dependencies.requestDeletion(record.operationId, token)
            Log.info("AccountDeletion: pending request confirmed via surviving cached token")
            return try await store.advance(to: .backendConfirmed, purgeWindowHours: response.purgeWindowHours)
        } catch {
            Log.warning("AccountDeletion: cached-token confirmation attempt failed: \(error)")
            return nil
        }
    }

    /// Resolves a record whose identity was displaced by pairing: attempts
    /// a cached-token backend confirmation for the old account, sweeps only
    /// the record-scoped slots (the old address-scoped keychain entries and
    /// synced backup — never the live identity, database, or caches, which
    /// belong to the new identity), and clears the record. When no token
    /// survives, the old backend account cannot be reached from this device
    /// again; that is logged loudly rather than hidden behind a wipe.
    private func resolveDisplacedRecord(_ record: AccountDeletionRecord) async {
        if let token = dependencies.cachedToken(record) {
            do {
                _ = try await dependencies.requestDeletion(record.operationId, token)
                Log.info("AccountDeletion: displaced record's backend deletion confirmed via surviving cached token")
            } catch {
                Log.error("AccountDeletion: displaced record could not be confirmed (\(error)); its backend account is unreachable from this device")
            }
        } else {
            Log.error("AccountDeletion: displaced record has no surviving token; its backend account is unreachable from this device")
        }
        await dependencies.sweepRecordScopedSlots(record)
        do {
            try await store.clear()
        } catch {
            Log.error("AccountDeletion: failed to clear displaced record: \(error)")
        }
    }

    // MARK: - Teardown

    /// Resumes a confirmed teardown, guarding against an identity displaced
    /// between confirmation and wipe: the full manifest (which deletes the
    /// keychain identity, database, and caches) must never run against an
    /// identity the record does not describe. Records synthesized without
    /// an identity (empty inboxId, remote-deletion wipe on an empty
    /// keychain) skip the check.
    private func resumeConfirmedTeardown(
        from record: AccountDeletionRecord,
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void
    ) async throws {
        if let identity = try? dependencies.loadIdentity(),
           !record.inboxId.isEmpty,
           !matches(record, identity) {
            Log.error("AccountDeletion: confirmed record's identity was displaced; sweeping record-scoped slots only")
            await dependencies.sweepRecordScopedSlots(record)
            try await store.clear()
            dependencies.setReauthSuspended(false)
            return
        }
        try await runTeardown(from: record, onProgress: onProgress)
    }

    /// Runs protocol teardown and the local wipe from a confirmed record.
    /// Revocation is attempted only from `backendConfirmed` (keys still
    /// exist); a resume from `localWipePending` goes straight to the
    /// manifest.
    private func runTeardown(
        from record: AccountDeletionRecord,
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void
    ) async throws {
        var current = record
        if current.phase == .backendConfirmed {
            onProgress(.revokingDevices)
            await dependencies.revokeInstallations(current)
            current = try await store.advance(to: .localWipePending)
        }

        onProgress(.wipingLocalData)
        await dependencies.stopServices()
        let result = await dependencies.makeWipeExecutor().run(record: current)
        guard result.isComplete else {
            throw AccountDeletionError.wipeIncomplete(failures: result.failures)
        }
        try await store.clear()
        dependencies.setReauthSuspended(false)
        onProgress(.completed)
    }

    // MARK: - Identity binding

    private func matches(_ record: AccountDeletionRecord, _ identity: KeychainIdentity) -> Bool {
        record.inboxId == identity.inboxId
            && record.clientId == identity.clientId
            && record.ethAddress == dependencies.ethAddress(identity).lowercased()
    }
}
