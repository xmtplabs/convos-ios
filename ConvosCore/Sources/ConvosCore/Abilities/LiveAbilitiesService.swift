import Foundation

/// Failures specific to the live transport's client-side bookkeeping (not
/// part of the backend's error vocabulary).
public enum LiveAbilitiesServiceError: Error, Sendable, Equatable {
    /// `completeEntitlement` ran without a connection-request id from a
    /// prior `beginEntitlement` in this process (e.g. the app restarted
    /// mid-authorization). Begin is idempotent, so the recovery is to
    /// re-run connect, which mints a fresh redirect and request id.
    case missingConnectionRequest(abilityId: String)
}

extension LiveAbilitiesServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingConnectionRequest:
            "Sign-in session expired. Try connecting again."
        }
    }
}

/// `AbilitiesServiceProtocol` over the live V2 abilities endpoints.
///
/// The backend is the only source of truth; this service adds exactly two
/// pieces of client-side state:
/// - the last-known catalog (in memory plus `AbilitiesCatalogDiskCache`),
///   which `AbilitiesCatalog.resolving` merges under an
///   `entitlementsUnavailable` response so keep-last-known survives
///   restarts, and
/// - the per-ability Composio connection-request id from `beginEntitlement`,
///   which `completeEntitlement` echoes back for post-callback ownership
///   verification. It is process-local by design: not a bearer credential,
///   and a restart mid-auth recovers by re-running begin (idempotent).
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
    /// The caller's own inbox id for the PUT's optional `extendedByInboxId`.
    /// Nil (or a nil resolution) omits the field, which the wire allows.
    private let myInboxIdProvider: (@Sendable () async -> String?)?

    private var lastKnownCatalog: AbilitiesCatalog?
    private var hasLoadedCache: Bool = false
    private var pendingConnectionRequestIds: [String: String] = [:]

    public init(
        apiClient: any ConvosAPIClientProtocol,
        callbackURLScheme: String?,
        cache: AbilitiesCatalogDiskCache?,
        myInboxIdProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.apiClient = apiClient
        self.redirectUri = callbackURLScheme.map { "\($0)://connections/callback" }
        self.cache = cache
        self.myInboxIdProvider = myInboxIdProvider
    }

    // MARK: - AbilitiesServiceProtocol

    public func fetchCatalog() async throws -> AbilitiesCatalog {
        loadCacheIfNeeded()
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
        cache?.save(catalog)
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
        do {
            let response = try await apiClient.createAbilityEntitlement(abilityId: abilityId, redirectUri: redirectUri)
            if let connectionRequestId = response.connectionRequestId {
                pendingConnectionRequestIds[abilityId] = connectionRequestId
            }
            return AbilityEntitlementInitiation(status: response.status, redirectUrl: response.redirectUrl)
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
    }

    public func completeEntitlement(abilityId: String) async throws {
        guard let connectionRequestId = pendingConnectionRequestIds[abilityId] else {
            throw LiveAbilitiesServiceError.missingConnectionRequest(abilityId: abilityId)
        }
        do {
            try await apiClient.completeAbilityEntitlement(
                abilityId: abilityId,
                connectionRequestId: connectionRequestId
            )
            // Only cleared on success: an `auth_incomplete` retry needs the
            // same id, since ownership is verified against it server-side.
            pendingConnectionRequestIds.removeValue(forKey: abilityId)
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
    }

    public func revokeEntitlement(abilityId: String) async throws {
        do {
            try await apiClient.revokeAbilityEntitlement(abilityId: abilityId)
        } catch {
            throw mapServiceError(error, abilityId: abilityId)
        }
        pendingConnectionRequestIds.removeValue(forKey: abilityId)
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
    }

    // MARK: - Helpers

    private func loadCacheIfNeeded() {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        lastKnownCatalog = cache?.load()
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
