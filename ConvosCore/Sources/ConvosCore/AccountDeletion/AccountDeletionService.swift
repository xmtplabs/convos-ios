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
    /// The identity keys are absent or unreadable; true deletion is
    /// impossible from this device. Nothing was written or wiped.
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

    public init(
        loadIdentity: @escaping @Sendable () throws -> KeychainIdentity?,
        deviceId: @escaping @Sendable () -> String,
        ethAddress: @escaping @Sendable (KeychainIdentity) -> String,
        mintToken: @escaping @Sendable (KeychainIdentity) async throws -> String,
        requestDeletion: @escaping @Sendable (UUID, String) async throws -> ConvosAPI.AccountDeletionResponse,
        setReauthSuspended: @escaping @Sendable (Bool) -> Void,
        revokeInstallations: @escaping @Sendable (AccountDeletionRecord) async -> Void,
        stopServices: @escaping @Sendable () async -> Void,
        makeWipeExecutor: @escaping @Sendable () -> WipeManifestExecutor
    ) {
        self.loadIdentity = loadIdentity
        self.deviceId = deviceId
        self.ethAddress = ethAddress
        self.mintToken = mintToken
        self.requestDeletion = requestDeletion
        self.setReauthSuspended = setReauthSuspended
        self.revokeInstallations = revokeInstallations
        self.stopServices = stopServices
        self.makeWipeExecutor = makeWipeExecutor
    }
}

/// Orchestrates account deletion end to end: durable record first, backend
/// deletion while the keys still exist, best-effort protocol teardown, then
/// the manifest-driven local wipe. Also owns launch recovery for every
/// crash window (see `recoverAtLaunch`).
public actor AccountDeletionService {
    private let store: AccountDeletionStateStore
    private let dependencies: AccountDeletionDependencies

    public init(store: AccountDeletionStateStore, dependencies: AccountDeletionDependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    /// Current durable deletion state (for the settings pending-retry UI
    /// and the provisioning gate).
    public nonisolated func status() -> AccountDeletionLoadResult {
        store.load()
    }

    // MARK: - User-initiated flow

    /// Runs the deletion flow. Resumable: if a record already exists, the
    /// flow continues from its phase (same operation id across retries of
    /// one deletion, per the backend contract).
    public func deleteAccount(
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void
    ) async throws {
        dependencies.setReauthSuspended(true)

        let record: AccountDeletionRecord
        let createdFresh: Bool
        switch store.load() {
        case .record(let existing):
            record = existing
            createdFresh = false
        case .none, .corrupted:
            // A corrupt record file is replaced by this explicit,
            // re-confirmed deletion; `begin` documents that trade.
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
            try await store.begin(fresh)
            record = fresh
            createdFresh = true
        }

        switch record.phase {
        case .requested:
            onProgress(.requestingBackendDeletion)
            // Clearing on a pre-send failure is only sound for a record
            // created by this very call: for a pre-existing record an
            // earlier attempt may already have sent the request, so its
            // outcome stays ambiguous and the record must survive.
            let confirmed = try await requestBackendDeletion(for: record, clearRecordOnPreflightFailure: createdFresh)
            try await runTeardown(from: confirmed, onProgress: onProgress)
        case .backendConfirmed, .localWipePending:
            try await runTeardown(from: record, onProgress: onProgress)
        }
    }

    // MARK: - Remote-deletion wipe (paired device)

    /// Paired-device exit: the backend already deleted the account (the
    /// terminal identity-deleted response arrived outside any local
    /// deletion flow). Writes a `backendConfirmed` record first so a crash
    /// mid-wipe resumes, then runs the normal teardown. No backend call is
    /// made or possible.
    public func wipeAfterRemoteDeletion(
        onProgress: @escaping @Sendable (AccountDeletionProgress) -> Void = { _ in }
    ) async throws {
        dependencies.setReauthSuspended(true)
        let record: AccountDeletionRecord
        switch store.load() {
        case .record(let existing):
            record = existing
        case .none, .corrupted:
            let identity = try? dependencies.loadIdentity()
            let fresh = AccountDeletionRecord(
                operationId: UUID(),
                inboxId: identity?.inboxId ?? "",
                clientId: identity?.clientId ?? "",
                ethAddress: identity.map { dependencies.ethAddress($0) } ?? "",
                deviceId: dependencies.deviceId()
            )
            try await store.begin(fresh)
            record = try await store.advance(to: .backendConfirmed)
        }
        try await runTeardown(from: record, onProgress: onProgress)
    }

    // MARK: - Launch recovery

    /// Resolves a pending deletion at cold launch. The four situations:
    /// no record (normal startup, caller never gets here), `requested`
    /// (retry while a token is mintable; only the barrier's terminal
    /// response or a deletion-endpoint 200 promotes), `backendConfirmed` /
    /// `localWipePending` (resume the wipe, no auth needed), and a corrupt
    /// record (hold provisioning, wait for explicit user action).
    ///
    /// Never throws: recovery is best-effort at launch, and a failure
    /// leaves the durable record in place for the next attempt.
    public func recoverAtLaunch() async {
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
                    try await runTeardown(from: record, onProgress: { _ in })
                } catch {
                    Log.error("AccountDeletion: wipe resume failed at launch; will retry next launch: \(error)")
                }
            }
        }
    }

    // MARK: - Private

    private func recoverRequested(_ record: AccountDeletionRecord) async {
        let identity: KeychainIdentity?
        do {
            identity = try dependencies.loadIdentity()
        } catch {
            Log.error("AccountDeletion: keychain unreadable during recovery; keeping record for retry: \(error)")
            return
        }
        guard identity != nil else {
            // Keys gone with the backend outcome unconfirmed. This state
            // is unreachable through the flow's ordering (teardown never
            // starts before backendConfirmed); if it exists anyway, no
            // retry can ever be authenticated, so the only honest exit is
            // finishing the local wipe.
            Log.error("AccountDeletion: requested record with no identity; completing local wipe (backend outcome unresolvable)")
            await dependencies.stopServices()
            let result = await dependencies.makeWipeExecutor().run(record: record)
            if result.isComplete {
                try? await store.clear()
                dependencies.setReauthSuspended(false)
            }
            return
        }
        do {
            let confirmed = try await requestBackendDeletion(for: record, clearRecordOnPreflightFailure: false)
            try await runTeardown(from: confirmed, onProgress: { _ in })
        } catch {
            // Keys intact, record stays `requested`; the settings row
            // surfaces "deletion pending" with a retry affordance.
            Log.warning("AccountDeletion: recovery retry did not resolve; record stays requested: \(error)")
        }
    }

    /// Mints a token and calls the deletion endpoint, promoting the record
    /// to `backendConfirmed` on either confirmation channel (a 200 from
    /// the endpoint, or the barrier's terminal identity-deleted response
    /// at mint). Everything else leaves keys intact and the outcome
    /// unconfirmed.
    private func requestBackendDeletion(
        for record: AccountDeletionRecord,
        clearRecordOnPreflightFailure: Bool
    ) async throws -> AccountDeletionRecord {
        let identity: KeychainIdentity?
        do {
            identity = try dependencies.loadIdentity()
        } catch {
            throw AccountDeletionError.identityUnavailable
        }
        guard let identity else {
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
                try? await store.clear()
                dependencies.setReauthSuspended(false)
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
}
