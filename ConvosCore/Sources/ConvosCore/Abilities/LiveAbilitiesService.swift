import Foundation

/// Failures of the client-side entitlement lifecycle bookkeeping (not part
/// of the backend's error vocabulary). Thrown by the live transport and
/// mirrored by the mock so surfaces exercise the same error paths in both
/// modes.
public enum LiveAbilitiesServiceError: Error, Sendable, Equatable {
    /// `completeEntitlement` ran without a retained OAuth attempt from a
    /// prior `beginEntitlement` in this process (e.g. the app restarted
    /// mid-authorization). Begin is idempotent, so the recovery is to
    /// re-run connect, which mints a fresh redirect and request id.
    case missingConnectionRequest(abilityId: String)
    /// An extension was requested with no bundle ids. The PUT contract
    /// requires a non-empty selection, so this is rejected client-side
    /// instead of round-tripping a predictable 400 (reachable for catalog
    /// abilities that declare zero bundles).
    case noBundlesSelected(abilityId: String)
}

extension LiveAbilitiesServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingConnectionRequest:
            "Sign-in session expired. Try connecting again."
        case .noBundlesSelected:
            "This connection has no permissions to share yet."
        }
    }
}

/// `AbilitiesServiceProtocol` over the live V2 abilities endpoints.
///
/// The backend is the only source of truth; this service adds two pieces of
/// client-side state:
/// - the last-known catalog (in memory plus `AbilitiesCatalogDiskCache`),
///   which `AbilitiesCatalog.resolving` merges under an
///   `entitlementsUnavailable` response so keep-last-known survives
///   restarts. Both sides are scoped by the caller's inbox id: the disk
///   file is per (environment, inbox) and the in-memory copy resets when
///   the scope changes, so one account's state never leaks into another's.
///   With no resolvable scope (device-only caller, or no provider) the
///   disk cache is bypassed entirely -- an accountless catalog is never
///   persisted over an account-scoped one.
/// - the per-ability OAuth attempt from `beginEntitlement`: the connection
///   request id `completeEntitlement` must echo. Kept across
///   `auth_incomplete` and dropped on any other completion failure, so the
///   next connect tap can re-submit it before minting anything -- the only
///   way a round that went ACTIVE after the retry budget expired ever
///   reaches the entitlement row, since no provider webhook exists. It is
///   process-local by design: not a bearer credential, and a restart
///   mid-auth recovers by re-running begin.
///
/// The consent URL that comes back with it is deliberately **not** retained.
/// It belongs to one provider link session, which expires on its own clock;
/// re-serving a stored one on a later connect tap is how a member reaches a
/// provider page reading "link session has expired" with no way forward. The
/// id and the URL age differently, so they get separate policies: re-submit
/// the id, re-mint the URL.
///
/// Begins and completes are deduplicated per ability with in-flight task
/// maps: actor reentrancy would otherwise let overlapping begins overwrite
/// each other's attempt, or duplicate completes submit the same id twice.
///
/// Mutations are not folded into the last-known catalog the way the mock
/// does: whenever the backend serves `entitlementsUnavailable`, entitlement
/// mutations fail with the same signal, so there is no authoritative
/// mid-outage mutation to preserve.
public actor LiveAbilitiesService: AbilitiesServiceProtocol {
    private let apiClient: any ConvosAPIClientProtocol
    /// Per-environment OAuth callback sent as the initiate `redirectUri`,
    /// same shape as V1: `<scheme>://connections/callback`.
    private let redirectUri: String?
    private let cache: AbilitiesCatalogDiskCache?
    /// The caller's own inbox id: the disk-cache scope, and the PUT's
    /// optional `extendedByInboxId`. Nil (or a nil resolution) omits the
    /// wire field and bypasses the disk cache.
    private let myInboxIdProvider: (@Sendable () async -> String?)?
    /// V1 awareness shim: best-effort ProfileUpdate side-writes mirroring
    /// extend/withdraw for V1-reader agents. Only consulted when
    /// `isShimEnabled()` reads true at mutation time (a debug toggle,
    /// default off), so flips take effect without rebuilding the service.
    private let shimWriter: (any AbilityV1AwarenessShimWriting)?
    private let isShimEnabled: @Sendable () -> Bool

    /// One OAuth round in flight for an ability: the Composio connection
    /// request id `completeEntitlement` must echo. The round's consent URL
    /// is not a field here on purpose -- a URL that is never stored is a
    /// URL that cannot be replayed after its link session expired.
    private struct PendingAttempt {
        let connectionRequestId: String
    }

    private var lastKnownCatalog: AbilitiesCatalog?
    private var hasLoadedCache: Bool = false
    /// The scope `lastKnownCatalog` belongs to; a change resets it.
    private var catalogScope: String?
    /// Monotonic fetch ordering: every `fetchCatalog` takes a sequence
    /// number before its network await and may only commit its result if
    /// no higher-numbered fetch committed first. Without this, actor
    /// reentrancy lets an older response that finishes late clobber newer
    /// state in memory and on disk. `handleAccountDataWiped` bumps the
    /// committed watermark past every in-flight fetch, so a refresh that
    /// was already on the network cannot resurrect wiped data.
    private var fetchSequence: UInt64 = 0
    private var committedFetchSequence: UInt64 = 0
    /// Bumped by `handleAccountDataWiped`. Operations capture it at entry,
    /// before their first await, and refuse to persist anything if it moved:
    /// the sequence watermark only invalidates fetches that took a number
    /// before the wipe, so an operation suspended in the identity-provider
    /// await at wipe time needs this second fence to keep its late results
    /// (a catalog save, a retained OAuth attempt) out of the post-wipe world.
    private var wipeCount: UInt64 = 0
    /// Bumped on every genuine scope change (and on wipe). OAuth attempt
    /// state is only valid within the epoch that created it: in-flight
    /// begin/complete tasks are keyed by epoch so a new account can never
    /// join or mutate the previous account's attempts.
    private var scopeEpoch: UInt64 = 0
    private var pendingAttempts: [String: PendingAttempt] = [:]
    private var inFlightBegins: [String: Task<AbilityEntitlementInitiation, Error>] = [:]
    private var inFlightCompletes: [String: Task<Void, Error>] = [:]

    public init(
        apiClient: any ConvosAPIClientProtocol,
        callbackURLScheme: String?,
        cache: AbilitiesCatalogDiskCache?,
        myInboxIdProvider: (@Sendable () async -> String?)? = nil,
        shimWriter: (any AbilityV1AwarenessShimWriting)? = nil,
        isShimEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.apiClient = apiClient
        self.redirectUri = callbackURLScheme.map { "\($0)://connections/callback" }
        self.cache = cache
        self.myInboxIdProvider = myInboxIdProvider
        self.shimWriter = shimWriter
        self.isShimEnabled = isShimEnabled
    }

    // MARK: - AbilitiesServiceProtocol

    public func fetchCatalog() async throws -> AbilitiesCatalog {
        let wipeMark = wipeCount
        let scope = await myInboxIdProvider?()
        prepareLastKnownCatalog(for: scope)
        // Snapshot before suspending: the actor is reentrant at the await,
        // and a concurrent fetch for another scope may swap
        // `lastKnownCatalog` underneath this one. Merging against the
        // snapshot keeps the result pure to this fetch's scope.
        let lastKnownAtStart = lastKnownCatalog
        fetchSequence += 1
        let sequence = fetchSequence
        let response: AbilitiesAPI.CatalogResponse
        do {
            response = try await apiClient.getAbilities()
        } catch {
            throw mapCatalogError(error)
        }
        let catalog = AbilitiesCatalog.resolving(response: response, lastKnown: lastKnownAtStart)
        // The merged result becomes the new last-known catalog even under
        // the flag, so back-to-back outages keep carrying state forward.
        // Commit only if this scope is still current and nothing newer
        // (a later fetch, or a wipe) committed while we were suspended;
        // the caller still gets this fetch's resolved catalog either way.
        if catalogScope == scope && sequence > committedFetchSequence && wipeCount == wipeMark {
            committedFetchSequence = sequence
            lastKnownCatalog = catalog
            if let scope {
                cache?.save(catalog, scope: scope)
            }
        }
        return catalog
    }

    /// Fire-and-forget refresh for lifecycle hooks (launch, foreground):
    /// updates the last-known catalog so the next screen-appear fetch merges
    /// against fresh state. Failures are logged, never surfaced -- the
    /// visible surfaces run their own throwing fetches.
    public func refreshCatalog() async {
        do {
            _ = try await fetchCatalog()
        } catch {
            Log.warning("[Abilities] background catalog refresh failed: \(error.localizedDescription)")
        }
    }

    /// Finishes the outstanding round for an ability if there is one, and
    /// otherwise opens a new one against a freshly minted link session.
    ///
    /// Every entry point that can reach a `pendingAuth` ability funnels
    /// here -- the browser's Connect button, the conversation toggle's
    /// repair route, the inline connect sheet -- and each is a tap that may
    /// land minutes or hours after the round it is retrying. The two pieces
    /// of that round age very differently, which is why they get opposite
    /// policies:
    ///
    /// - The **consent URL** is dead. It belongs to one provider link
    ///   session with its own expiry, so it is never stored and never
    ///   re-served; a restart always mints a new one.
    /// - The **connection-request id** may well have gone ACTIVE upstream
    ///   in the meantime. Nothing else in the system would notice: there is
    ///   no provider webhook, and the entitlement row flips only on a
    ///   complete this client submits. So the id is retained and re-submitted
    ///   first. When it lands, the round finishes with no sign-in at all.
    ///
    /// Only when that fails (or there is no id) does a fresh round start.
    ///
    /// Concurrent begins for the same ability still share one request --
    /// that is tap-storm deduplication within a single round, not a
    /// resumption across rounds.
    public func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        let wipeMark = wipeCount
        // Resolve the scope first so an account switch is detected here
        // too, not only on catalog fetches: the switch clears the previous
        // account's attempts before a new one can be minted under them.
        let scope = await myInboxIdProvider?()
        prepareLastKnownCatalog(for: scope)
        // Finish before restarting. A round whose completion ran out of
        // retry budget is very often ACTIVE upstream by now, and nothing
        // else will ever notice: there is no provider webhook, and the
        // entitlement row only flips on a complete this client submits.
        // Re-submitting the retained id is cheap, silent, and the only path
        // that finishes such a round without a second sign-in.
        if pendingAttempts[abilityId] != nil, let resumed = await completeRetainedAttempt(abilityId: abilityId) {
            return resumed
        }
        let epoch = scopeEpoch
        let inFlightKey = attemptKey(abilityId: abilityId, epoch: epoch)
        if let inFlight = inFlightBegins[inFlightKey] {
            return try await inFlight.value
        }
        let task = Task { () throws -> AbilityEntitlementInitiation in
            do {
                let response = try await apiClient.createAbilityEntitlement(abilityId: abilityId, redirectUri: redirectUri)
                // Guarded by epoch and wipe mark: if the account changed
                // while the begin was on the network, or a data wipe landed
                // anywhere after entry (including during the identity
                // resolution above), the attempt belongs to the previous
                // identity and must not be retained.
                // Only `pending_auth` leaves a round outstanding. An OAuth
                // ability whose row is already active answers `active` while
                // still carrying the request this call minted on the way
                // through; retaining that id would schedule a completion for
                // a round nobody is going to authorize.
                if response.status == .pendingAuth, let connectionRequestId = response.connectionRequestId,
                   scopeEpoch == epoch, wipeCount == wipeMark {
                    pendingAttempts[abilityId] = PendingAttempt(connectionRequestId: connectionRequestId)
                }
                guard response.status == .pendingAuth else {
                    // Same reason the id is dropped: there is nothing here
                    // for the caller to authorize, so no URL is handed up.
                    return AbilityEntitlementInitiation(status: response.status)
                }
                return AbilityEntitlementInitiation(status: response.status, redirectUrl: response.redirectUrl)
            } catch {
                throw mapServiceError(error, abilityId: abilityId)
            }
        }
        inFlightBegins[inFlightKey] = task
        defer { inFlightBegins[inFlightKey] = nil }
        return try await task.value
    }

    /// Tries to finish the retained round before a restart mints a new one.
    /// Returns the activation when the round completed, nil when the caller
    /// should go on and mint.
    ///
    /// It routes through `completeEntitlement` rather than the client
    /// directly so the retained id keeps exactly one lifecycle: duplicate
    /// completes join the in-flight one, `auth_incomplete` keeps the id for
    /// the next attempt, and any other failure drops it. That is also why
    /// nothing is cleared here on the way out -- an id that survives a
    /// failure is the recovery path, not debris.
    private func completeRetainedAttempt(abilityId: String) async -> AbilityEntitlementInitiation? {
        do {
            try await completeEntitlement(abilityId: abilityId)
            return AbilityEntitlementInitiation(status: .active)
        } catch {
            return nil
        }
    }

    public func completeEntitlement(abilityId: String) async throws {
        let epoch = scopeEpoch
        let inFlightKey = attemptKey(abilityId: abilityId, epoch: epoch)
        // Duplicate completes join the in-flight submission instead of
        // re-posting the same connection-request id.
        if let inFlight = inFlightCompletes[inFlightKey] {
            return try await inFlight.value
        }
        guard let attempt = pendingAttempts[abilityId] else {
            throw LiveAbilitiesServiceError.missingConnectionRequest(abilityId: abilityId)
        }
        let task = Task { () throws in
            do {
                try await apiClient.completeAbilityEntitlement(
                    abilityId: abilityId,
                    connectionRequestId: attempt.connectionRequestId
                )
                removeAttempt(abilityId: abilityId, epoch: epoch, connectionRequestId: attempt.connectionRequestId)
            } catch let error as AbilitiesAPI.EndpointError where error.isAuthIncomplete {
                // Retained on purpose: auth_incomplete is retryable against
                // the same connection request (ownership is verified by id
                // server-side), which is what the bounded completion retry
                // re-submits. A later connect tap is a different matter --
                // it mints its own round and its own id.
                throw error
            } catch {
                // Any other completion failure invalidates the attempt
                // (expired request, wrong toolkit, not owned, transport
                // fault after which the request state is unknown): retrying
                // the same id cannot be trusted to converge, so the next
                // connect re-begins. Begin is idempotent server-side.
                removeAttempt(abilityId: abilityId, epoch: epoch, connectionRequestId: attempt.connectionRequestId)
                throw mapServiceError(error, abilityId: abilityId)
            }
        }
        inFlightCompletes[inFlightKey] = task
        defer { inFlightCompletes[inFlightKey] = nil }
        return try await task.value
    }

    public func revokeEntitlement(abilityId: String) async throws {
        let epoch = scopeEpoch
        do {
            try await apiClient.revokeAbilityEntitlement(abilityId: abilityId)
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
        discardAttempt(abilityId: abilityId, epoch: epoch)
    }

    public func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        let response: AbilitiesAPI.ConversationAbilitiesResponse
        do {
            response = try await apiClient.getConversationAbilities(conversationId: conversationId)
        } catch {
            throw mapCatalogError(error)
        }
        // Only the caller's own opt-ins: the current toggle surface offers
        // PUT/DELETE on every row it renders, and only `extendedByMe`
        // entries accept those. Other members' opt-ins stay server-side
        // until a surface exists to render them read-only.
        return response.abilities
            .filter(\.extendedByMe)
            .map { (entry: AbilitiesAPI.ConversationAbilityEntry) -> ConversationAbility in
                ConversationAbility(
                    abilityId: entry.abilityId,
                    agentInboxId: entry.agentInboxId,
                    bundleIds: entry.bundleIds
                )
            }
    }

    public func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        guard !bundleIds.isEmpty else {
            throw LiveAbilitiesServiceError.noBundlesSelected(abilityId: abilityId)
        }
        let extendedByInboxId = await myInboxIdProvider?()
        do {
            try await apiClient.putConversationAbility(
                conversationId: conversationId,
                abilityId: abilityId,
                agentInboxId: agentInboxId,
                bundleIds: bundleIds,
                extendedByInboxId: extendedByInboxId
            )
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
        if isShimEnabled(), let shimWriter {
            await shimWriter.recordExtension(
                conversationId: conversationId,
                abilityId: abilityId,
                agentInboxId: agentInboxId,
                bundleIds: bundleIds
            )
        }
    }

    public func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        do {
            try await apiClient.deleteConversationAbility(
                conversationId: conversationId,
                abilityId: abilityId,
                agentInboxId: agentInboxId
            )
        } catch APIError.notFound {
            // Already withdrawn (or never extended): the desired end state
            // holds, mirroring the mock's no-op semantics.
            Log.info("[Abilities] withdraw found no opt-in for \(abilityId) (conversationId=\(conversationId)); treating as done")
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
        // Mirrors extend, and runs on the benign not-found path too so a
        // stale shim entry cannot outlive a withdrawal.
        if isShimEnabled(), let shimWriter {
            await shimWriter.recordWithdrawal(
                conversationId: conversationId,
                abilityId: abilityId,
                agentInboxId: agentInboxId
            )
        }
    }

    /// Account-wipe hygiene, on the actor so it serializes with every
    /// fetch commit: invalidates in-flight fetches (a refresh already on
    /// the network resumes past the watermark and cannot recreate the
    /// wiped cache file), drops OAuth attempts, and clears the disk cache
    /// after the watermark bump so nothing committed in between survives.
    public func handleAccountDataWiped() {
        wipeCount += 1
        committedFetchSequence = fetchSequence
        scopeEpoch += 1
        pendingAttempts.removeAll()
        lastKnownCatalog = nil
        catalogScope = nil
        hasLoadedCache = false
        cache?.clearAll()
    }

    // MARK: - Helpers

    /// Loads (or reloads) the last-known catalog for the resolved scope.
    /// A scope change -- account adopted mid-process, account switched --
    /// drops the previous scope's in-memory state before anything can
    /// merge against it, and orphans the previous scope's OAuth attempts
    /// so the new identity can never resume or complete them.
    private func prepareLastKnownCatalog(for scope: String?) {
        guard !hasLoadedCache || scope != catalogScope else { return }
        if hasLoadedCache {
            scopeEpoch += 1
            pendingAttempts.removeAll()
        }
        hasLoadedCache = true
        catalogScope = scope
        if let scope {
            lastKnownCatalog = cache?.load(scope: scope)
        } else {
            lastKnownCatalog = nil
        }
    }

    /// Key for the in-flight begin/complete maps: epoch-qualified so tasks
    /// started under a previous identity are invisible to the current one
    /// (joining them would hand the new account the old account's consent
    /// URL), and so their cleanup can never remove a successor's entry.
    private func attemptKey(abilityId: String, epoch: UInt64) -> String {
        "\(epoch):\(abilityId)"
    }

    /// Drops whatever round is retained for the ability, whichever one it
    /// is. Only for revoke, which invalidates every outstanding round for
    /// the entitlement rather than concluding a particular one.
    private func discardAttempt(abilityId: String, epoch: UInt64) {
        guard scopeEpoch == epoch else { return }
        pendingAttempts.removeValue(forKey: abilityId)
    }

    /// Drops a retained attempt only if it is still the one the caller was
    /// working on: same epoch, same connection-request id.
    ///
    /// `pendingAttempts` is keyed by ability id alone, so a completion that
    /// outlives the surface that started it (the composer modal's connect
    /// deliberately survives dismissal) would otherwise delete an attempt a
    /// later begin had already stored in its place. The next completion then
    /// throws `missingConnectionRequest` -- "sign-in session expired" right
    /// after a successful sign-in. The epoch alone cannot catch it: both
    /// rounds belong to the same account.
    private func removeAttempt(abilityId: String, epoch: UInt64, connectionRequestId: String) {
        guard scopeEpoch == epoch else { return }
        guard pendingAttempts[abilityId]?.connectionRequestId == connectionRequestId else { return }
        pendingAttempts.removeValue(forKey: abilityId)
    }

    /// Maps wire failures onto the service-level error vocabulary the view
    /// models already branch on. Typed endpoint errors without a service
    /// counterpart (`authIncomplete`, `entitlementsUnavailable`, ...) pass
    /// through -- they are `LocalizedError`s with user-facing copy.
    private func mapServiceError(_ error: Error, abilityId: String) -> Error {
        switch error {
        case AbilitiesAPI.EndpointError.unknownAbility:
            AbilitiesServiceError.unknownAbility(abilityId: abilityId)
        case AbilitiesAPI.EndpointError.needsEntitlement:
            AbilitiesServiceError.needsEntitlement(abilityId: abilityId)
        case APIError.forbidden:
            // requireAccount rejection: the JWT carries no account.
            AbilitiesServiceError.accountRequired
        default:
            error
        }
    }

    /// Read-path variant of `mapServiceError` with no ability in scope.
    private func mapCatalogError(_ error: Error) -> Error {
        switch error {
        case APIError.forbidden:
            AbilitiesServiceError.accountRequired
        default:
            error
        }
    }
}

private extension AbilitiesAPI.EndpointError {
    var isAuthIncomplete: Bool {
        if case .authIncomplete = self {
            return true
        }
        return false
    }
}
