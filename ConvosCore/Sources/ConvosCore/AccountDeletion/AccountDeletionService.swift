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
    /// A pre-send step failed (nothing was sent) and the record could not
    /// be cleared afterwards. The record is held marked as aborted: launch
    /// recovery retries only the cleanup and never re-sends the deletion,
    /// so nothing gets deleted unless the user explicitly retries.
    case preflightFailedRecordHeld(underlying: any Error)
    /// A pending record belongs to an identity this device no longer holds
    /// (pairing displaced it) and its backend deletion could not be
    /// confirmed. The record is held for a later retry; the requested
    /// operation did not run.
    case displacedRecordUnresolved
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
    /// must not run against the new identity. Throws so a failed delete
    /// holds the record for a later retry instead of abandoning the slots;
    /// the deletes are idempotent (a missing item is success), so a
    /// partial sweep re-runs safely.
    public var sweepRecordScopedSlots: @Sendable (AccountDeletionRecord) async throws -> Void

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
        sweepRecordScopedSlots: @escaping @Sendable (AccountDeletionRecord) async throws -> Void
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
/// - All entry points (user flow, launch recovery, remote-deletion wipe,
///   local reset) are single-flighted: a caller repeating the in-flight
///   operation joins it, and a caller with a different operation is
///   serialized behind it and then runs its own — never adopting an
///   outcome that does not answer its request (a delete joining a
///   hold-only recovery run must not report success).
public actor AccountDeletionService {
    /// Which operation a run performs. Only same-kind callers may share an
    /// outcome; different kinds serialize.
    private enum RunKind {
        case userDeletion
        case launchRecovery
        case remoteWipe
        case localReset
    }

    private struct ActiveRun {
        let kind: RunKind
        let id: UInt64
        let task: Task<Void, any Error>
    }

    private let store: AccountDeletionStateStore
    private let dependencies: AccountDeletionDependencies
    /// In-flight run, if any. Actor isolation alone does not serialize
    /// whole flows (reentrancy interleaves at suspension points), so every
    /// public entry point funnels through `singleFlight`.
    private var activeRun: ActiveRun?
    private var runCounter: UInt64 = 0
    /// True once a run in this process completed the full teardown (record
    /// cleared after a finished wipe). Lets a delete or remote-wipe caller
    /// serialized behind the completing run report completion truthfully
    /// instead of failing on the now-empty keychain.
    private var didCompleteTeardown: Bool = false

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
        try await singleFlight(kind: .userDeletion) {
            try await self.performDeleteAccount(onProgress: onProgress)
        }
    }

    /// Resolves a pending deletion at cold launch. Never throws: recovery
    /// is best-effort at launch, and a failure leaves the durable record in
    /// place for the next attempt.
    public func recoverAtLaunch() async {
        do {
            try await singleFlight(kind: .launchRecovery) {
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
        try await singleFlight(kind: .remoteWipe) {
            try await self.performWipeAfterRemoteDeletion(onProgress: onProgress)
        }
    }

    /// Runs a caller-supplied local reset (key destruction included) under
    /// the same gate as the deletion runs, so "no deletion record exists"
    /// and "the reset runs" are one atomic step: a deletion cannot persist
    /// a `requested` record between the check and the reset destroying the
    /// keys, and a reset cannot start while a deletion run is in flight.
    /// Throws `AccountDeletionInProgressError` while any record is active
    /// (or a corrupt record's phase is unknowable).
    public func performLocalResetIfIdle(_ reset: @escaping @Sendable () async throws -> Void) async throws {
        try await singleFlight(kind: .localReset) {
            guard case .none = self.store.load() else {
                throw AccountDeletionInProgressError()
            }
            try await reset()
        }
    }

    private func singleFlight(kind: RunKind, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let active = activeRun, active.kind == kind {
            // Same operation already in flight: its outcome answers this
            // caller too.
            try await active.task.value
            return
        }
        // Either no run is active, or a different operation is in flight.
        // A different operation's outcome must never be adopted (a delete
        // joining a hold-only recovery run would report success without
        // deleting anything), so serialize behind it and then run this
        // caller's own operation against the durable state it left.
        let predecessor = activeRun?.task
        runCounter += 1
        let id = runCounter
        let task = Task {
            if let predecessor {
                // The predecessor's failure is not this run's failure.
                _ = try? await predecessor.value
            }
            try await operation()
        }
        activeRun = ActiveRun(kind: kind, id: id, task: task)
        defer {
            if activeRun?.id == id {
                activeRun = nil
            }
        }
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
                // the new identity under the old record; only a confirmed
                // backend deletion may resolve the old record. Unconfirmed,
                // it is held and this delete cannot start (one durable
                // record at a time). The live identity keeps working, so
                // its re-auth resumes.
                guard await resolveDisplacedRecord(existing) else {
                    dependencies.setReauthSuspended(false)
                    throw AccountDeletionError.displacedRecordUnresolved
                }
                existingRecord = nil
            } else {
                existingRecord = existing
            }
        case .none, .corrupted:
            // A corrupt record file is replaced by this explicit,
            // re-confirmed deletion; `begin` documents that trade.
            existingRecord = nil
        }

        if existingRecord == nil, didCompleteTeardown {
            // A teardown already completed in this process. Only a
            // successful keychain read that finds no identity proves the
            // account is gone; then a caller serialized behind the
            // completing run gets completion rather than a false
            // "identity unavailable" failure. A read error is not that
            // proof — a re-provisioned identity may exist behind it — so
            // fail retryably instead of claiming success.
            let liveIdentity: KeychainIdentity?
            do {
                liveIdentity = try dependencies.loadIdentity()
            } catch {
                dependencies.setReauthSuspended(false)
                throw AccountDeletionError.identityUnavailable
            }
            if liveIdentity == nil {
                dependencies.setReauthSuspended(false)
                onProgress(.completed)
                return
            }
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
            if record.phase == .requested, record.preflightAborted == true {
                // The deletion request was provably never sent and the UI
                // reported a clean failure; the account is alive. Retry
                // only the cleanup — never re-send the deletion without
                // explicit user intent — and leave re-auth alone.
                do {
                    try await store.clear()
                    Log.info("AccountDeletion: cleared aborted pre-send record at launch")
                } catch {
                    Log.error("AccountDeletion: aborted pre-send record still cannot be cleared; will retry next launch: \(error)")
                }
                return
            }
            if record.phase == .requested, record.sendAttempted != true {
                // No durable send marker means the request was provably
                // never sent (sends happen only after the marker persists)
                // - including the case where the user saw a failure but
                // neither the clear nor the abort marker could be written.
                // Never auto-send at launch: hold and surface; the settings
                // pending row offers the explicit retry, and the account is
                // alive so re-auth stays untouched.
                Log.warning("AccountDeletion: requested record has no send marker; holding for explicit retry, never auto-sending")
                return
            }
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
            // Pairing displaced the record's identity. Only a confirmed
            // backend deletion resolves the old record; unconfirmed, it is
            // held for a later retry. Either way the suspension lifts so
            // the live identity keeps working.
            if await resolveDisplacedRecord(record) == false {
                Log.error("AccountDeletion: displaced record held unresolved at launch; will retry")
            }
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
        let identity: KeychainIdentity?
        do {
            identity = try dependencies.loadIdentity()
        } catch {
            // An unreadable keychain is not proof the identity is gone: a
            // present-but-unreadable identity must never be treated as
            // absent, which would synthesize an empty-scoped record and run
            // the full manifest unbound (deleting the account's iCloud
            // key backup by an empty inboxId while the record clears). Fail
            // retryably; the sheet retry and launch recovery remain exits.
            throw AccountDeletionError.identityUnavailable
        }
        let record: AccountDeletionRecord
        switch store.load() {
        case .record(let existing):
            if let identity, !matches(existing, identity) {
                guard await resolveDisplacedRecord(existing) else {
                    throw AccountDeletionError.displacedRecordUnresolved
                }
                record = try await beginRemoteWipeRecord(identity: identity)
            } else if existing.phase == .requested {
                // Reaching a remote wipe means the backend deletion is
                // certain (the terminal identity-deleted barrier is the only
                // way in), but a reused record can still say `requested`.
                // Advance it so the durable phase reflects the wipe: a crash
                // mid-wipe then resumes from `backendConfirmed` instead of
                // holding forever on a `requested` record whose keys and
                // token slots the manifest already destroyed.
                record = try await store.advance(to: .backendConfirmed)
            } else {
                record = existing
            }
        case .none:
            if didCompleteTeardown {
                // The wipe already ran in this process. Completion may be
                // reported only when the keychain readably holds no
                // identity; a read error could hide a re-provisioned
                // identity, so it fails retryably rather than claiming
                // the wipe covered it.
                let liveIdentity: KeychainIdentity?
                do {
                    liveIdentity = try dependencies.loadIdentity()
                } catch {
                    throw AccountDeletionError.identityUnavailable
                }
                if liveIdentity == nil {
                    dependencies.setReauthSuspended(false)
                    onProgress(.completed)
                    return
                }
            }
            record = try await beginRemoteWipeRecord(identity: identity)
        case .corrupted:
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
                // Reauth resumes only when the record is actually gone.
                try await clearRecordAfterPreflightFailure(preflightError: error)
            }
            throw AccountDeletionError.preflightFailed(underlying: error)
        }

        if record.sendAttempted != true {
            do {
                // Durably record that a send is about to happen. Launch
                // recovery auto-resends only records carrying this marker,
                // so a record whose failure the user already saw (and
                // whose abort marker could not be persisted) can never be
                // silently re-sent. If the marker itself cannot be
                // persisted, do not send: an unmarked record with an
                // in-flight request would be exactly that ambiguity.
                try await store.markSendAttempted()
            } catch {
                if clearRecordOnPreflightFailure {
                    try await clearRecordAfterPreflightFailure(preflightError: error)
                }
                throw AccountDeletionError.preflightFailed(underlying: error)
            }
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

    /// Clears the record after a provably-unsent request. When the clear
    /// fails, the surviving record must not silently re-send the deletion
    /// at the next launch after the UI reported a clean failure: it is
    /// marked aborted so launch recovery retries only the cleanup, and the
    /// caller is told the pending state is stuck rather than reset.
    private func clearRecordAfterPreflightFailure(preflightError: any Error) async throws {
        do {
            try await store.clear()
            dependencies.setReauthSuspended(false)
        } catch {
            Log.error("AccountDeletion: failed to clear record after pre-send failure; holding it as aborted: \(error)")
            do {
                try await store.markPreflightAborted()
            } catch {
                Log.error("AccountDeletion: could not mark the stuck record as aborted: \(error)")
            }
            // The account is alive and nothing was sent; re-auth resumes.
            dependencies.setReauthSuspended(false)
            throw AccountDeletionError.preflightFailedRecordHeld(underlying: preflightError)
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

    /// Resolves a record whose identity was displaced by pairing. Only a
    /// confirmed backend deletion may resolve it: for a `requested` record
    /// a surviving cached token is tried against the deletion endpoint, and
    /// on that 200 (or when the record was already past `requested`) the
    /// record-scoped slots are swept (the old address-scoped keychain
    /// entries and synced backup — never the live identity, database, or
    /// caches, which belong to the new identity) and the record cleared.
    /// Returns false without touching the slots or the record when
    /// confirmation fails or no token survives: the record is held so a
    /// later retry can still confirm, instead of permanently abandoning a
    /// potentially live backend account. Also returns false when the sweep
    /// itself fails, so the record survives to retry the slot deletes (the
    /// sweep is idempotent) instead of abandoning them.
    private func resolveDisplacedRecord(_ record: AccountDeletionRecord) async -> Bool {
        if record.phase == .requested {
            guard record.sendAttempted == true else {
                // No durable send marker means the deletion request was
                // provably never sent (sends happen only after the marker
                // persists), so the old backend account is still alive. Never
                // auto-send it via the cached token here - that would breach
                // the "unmarked records are never auto-sent" invariant and
                // could silently delete a live account after a pairing swap.
                // Hold instead; its synced backup (the live account's iCloud
                // recovery channel) is left untouched because no sweep runs.
                Log.error("AccountDeletion: displaced record has no send marker; holding it (never auto-sending a provably-unsent deletion)")
                return false
            }
            guard let token = dependencies.cachedToken(record) else {
                Log.error("AccountDeletion: displaced record has no surviving token; holding it (no resolution without backend confirmation)")
                return false
            }
            do {
                _ = try await dependencies.requestDeletion(record.operationId, token)
                Log.info("AccountDeletion: displaced record's backend deletion confirmed via surviving cached token")
            } catch {
                Log.error("AccountDeletion: displaced record could not be confirmed (\(error)); holding it for a later retry")
                return false
            }
            do {
                // Durably mark the confirmation before the slots go: a
                // crash below resumes through the confirmed-displaced path
                // without needing the (about to be swept) cached token.
                try await store.advance(to: .backendConfirmed)
            } catch {
                // With the confirmation unpersisted, the cached-token slot
                // is still the record's only recovery channel; never
                // destroy it in that state. Hold and retry later — the
                // endpoint call is idempotent for this operation.
                Log.error("AccountDeletion: could not persist displaced record confirmation; keeping the record and its slots for a retry: \(error)")
                return false
            }
        }
        do {
            // The record clear below is gated on the sweep: a transient
            // Keychain/iCloud failure here would otherwise permanently
            // abandon the swept slots (including the deleted account's
            // synced key backup) with no retry once the record is gone.
            try await dependencies.sweepRecordScopedSlots(record)
        } catch {
            Log.error("AccountDeletion: displaced record slot sweep failed; keeping the record for a retry: \(error)")
            return false
        }
        do {
            try await store.clear()
        } catch {
            Log.error("AccountDeletion: failed to clear displaced record: \(error)")
            return false
        }
        return true
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
        let liveIdentity: KeychainIdentity?
        do {
            liveIdentity = try dependencies.loadIdentity()
        } catch {
            // A read error is not proof the identity is unchanged: a present-
            // but-unreadable displaced identity must not skip the displacement
            // guard and let the full manifest destroy the new identity's local
            // data. Fail retryably; recovery re-runs next launch.
            throw AccountDeletionError.identityUnavailable
        }
        if let identity = liveIdentity,
           !record.inboxId.isEmpty,
           !matches(record, identity) {
            Log.error("AccountDeletion: confirmed record's identity was displaced; sweeping record-scoped slots only")
            guard await resolveDisplacedRecord(record) else {
                // Already confirmed, so only a failed record clear lands
                // here; the record survives and the next launch retries.
                throw AccountDeletionError.displacedRecordUnresolved
            }
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
        didCompleteTeardown = true
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
