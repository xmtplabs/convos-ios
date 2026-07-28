import Foundation

/// Failures specific to the live transport's client-side bookkeeping (not
/// part of the backend's error vocabulary).
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
            "This ability has no permissions to share yet."
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
/// - the per-ability OAuth attempt from `beginEntitlement` (connection
///   request id + consent URL). While an attempt is retained, begin
///   short-circuits to it instead of minting a new backend connection
///   request, so "Continue connecting" resumes the same attempt;
///   `completeEntitlement` echoes the retained id, keeps it on
///   `auth_incomplete` (same-id retry), and drops it on any other
///   completion failure so the next connect re-begins. It is
///   process-local by design: not a bearer credential, and a restart
///   mid-auth recovers by re-running begin.
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
    /// request id `completeEntitlement` must echo, plus the consent URL a
    /// resumed begin re-serves.
    private struct PendingAttempt {
        let connectionRequestId: String
        let redirectUrl: String?
    }

    private var lastKnownCatalog: AbilitiesCatalog?
    private var hasLoadedCache: Bool = false
    /// The scope `lastKnownCatalog` belongs to; a change resets it.
    private var catalogScope: String?
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
        let scope = await myInboxIdProvider?()
        prepareLastKnownCatalog(for: scope)
        let response: AbilitiesAPI.CatalogResponse
        do {
            response = try await apiClient.getAbilities()
        } catch {
            throw mapCatalogError(error)
        }
        let catalog = AbilitiesCatalog.resolving(response: response, lastKnown: lastKnownCatalog)
        // The merged result becomes the new last-known catalog even under
        // the flag, so back-to-back outages keep carrying state forward.
        lastKnownCatalog = catalog
        if let scope {
            cache?.save(catalog, scope: scope)
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

    public func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        // Resume before re-begin: a retained attempt means an OAuth round
        // is already open for this ability, and re-serving its consent URL
        // keeps "Continue connecting" on the same backend connection
        // request instead of minting a new one.
        if let attempt = pendingAttempts[abilityId] {
            return AbilityEntitlementInitiation(status: .pendingAuth, redirectUrl: attempt.redirectUrl)
        }
        if let inFlight = inFlightBegins[abilityId] {
            return try await inFlight.value
        }
        let task = Task { () throws -> AbilityEntitlementInitiation in
            do {
                let response = try await apiClient.createAbilityEntitlement(abilityId: abilityId, redirectUri: redirectUri)
                if let connectionRequestId = response.connectionRequestId {
                    pendingAttempts[abilityId] = PendingAttempt(
                        connectionRequestId: connectionRequestId,
                        redirectUrl: response.redirectUrl
                    )
                }
                return AbilityEntitlementInitiation(status: response.status, redirectUrl: response.redirectUrl)
            } catch {
                throw mapServiceError(error, abilityId: abilityId)
            }
        }
        inFlightBegins[abilityId] = task
        defer { inFlightBegins[abilityId] = nil }
        return try await task.value
    }

    public func completeEntitlement(abilityId: String) async throws {
        // Duplicate completes join the in-flight submission instead of
        // re-posting the same connection-request id.
        if let inFlight = inFlightCompletes[abilityId] {
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
                pendingAttempts.removeValue(forKey: abilityId)
            } catch let error as AbilitiesAPI.EndpointError where error.isAuthIncomplete {
                // Retained on purpose: auth_incomplete is retryable against
                // the same connection request (ownership is verified by id
                // server-side), so both an immediate retry and a later
                // "Continue connecting" resume this attempt.
                throw error
            } catch {
                // Any other completion failure invalidates the attempt
                // (expired request, wrong toolkit, not owned, transport
                // fault after which the request state is unknown): retrying
                // the same id cannot be trusted to converge, so the next
                // connect re-begins. Begin is idempotent server-side.
                pendingAttempts.removeValue(forKey: abilityId)
                throw mapServiceError(error, abilityId: abilityId)
            }
        }
        inFlightCompletes[abilityId] = task
        defer { inFlightCompletes[abilityId] = nil }
        return try await task.value
    }

    public func revokeEntitlement(abilityId: String) async throws {
        do {
            try await apiClient.revokeAbilityEntitlement(abilityId: abilityId)
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
        pendingAttempts.removeValue(forKey: abilityId)
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

    // MARK: - Helpers

    /// Loads (or reloads) the last-known catalog for the resolved scope.
    /// A scope change -- account adopted mid-process, account switched --
    /// drops the previous scope's in-memory state before anything can
    /// merge against it.
    private func prepareLastKnownCatalog(for scope: String?) {
        guard !hasLoadedCache || scope != catalogScope else { return }
        hasLoadedCache = true
        catalogScope = scope
        if let scope {
            lastKnownCatalog = cache?.load(scope: scope)
        } else {
            lastKnownCatalog = nil
        }
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
