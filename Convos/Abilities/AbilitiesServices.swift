import ConvosCore
import Foundation

/// One coherent abilities configuration: the service and the OAuth
/// authorizer that belongs with it, resolved together from a single read
/// of the mock/live toggle. Consumers receive and latch the whole pair for
/// their screen or view-model lifetime, so a mid-session toggle flip can
/// never pair a retained live service with the mock approval sheet (or a
/// retained mock service with a real browser session) -- the next
/// presentation picks up the new pair atomically.
struct AbilitiesSelection {
    let service: any AbilitiesServiceProtocol
    /// Nil in mock mode: the stub authorization sheet stands in, and a
    /// mock connect never opens a real browser.
    let authorizer: (any AbilityAuthorizing)?
    /// The consent-flow seam. Escalation has no live transport, so the
    /// mock is the only implementation in both modes; app code must pass
    /// `AbilitiesServices`' shared instance so grants carry across
    /// surfaces. The default (a fresh, isolated mock) is for previews.
    let escalation: any AbilityEscalationServiceProtocol

    init(
        service: any AbilitiesServiceProtocol,
        authorizer: (any AbilityAuthorizing)? = nil,
        escalation: (any AbilityEscalationServiceProtocol)? = nil
    ) {
        self.service = service
        self.authorizer = authorizer
        self.escalation = escalation ?? MockAbilityEscalationService()
    }
}

/// Process-wide accessor for the active abilities configuration backing
/// the flag-gated V2 abilities surfaces (the App Settings abilities list
/// and the per-conversation abilities section). One service instance
/// app-wide so state changes carry across surfaces (connecting an ability
/// in settings is immediately visible in conversation info).
///
/// `configure(...)` wires the live transport at app start; `useLiveBackend`
/// (always true whenever `FeatureFlags.isAbilitiesV2Enabled` is on, see
/// below) picks which pair `selection` serves. Previews and tests never
/// call `configure`, so they fall back to the mock, mirroring
/// `CreditsServices`.
enum AbilitiesServices {
    /// Set once during `ConvosApp.init` before any surface can read them;
    /// the actor-based service handles its own concurrency.
    nonisolated(unsafe) private static var liveService: LiveAbilitiesService?
    nonisolated(unsafe) private static var catalogCache: AbilitiesCatalogDiskCache?
    private static let mockService: MockAbilitiesService = MockAbilitiesService()
    /// One escalation mock app-wide so grants made in a conversation are
    /// visible in the ability detail's delegations list. Both selection
    /// branches carry it: escalation has no live transport, so the mock is
    /// the only source either way; the `isActive` gate decides whether it
    /// serves anything.
    private static let escalationService: MockAbilityEscalationService = MockAbilityEscalationService(
        isActive: { AbilitiesServices.isEscalationMockEnabled }
    )

    /// The atomic (service, authorizer) pair for the current mode. Resolve
    /// once per screen/view-model lifetime and pass the whole value down;
    /// never read the halves at different times.
    @MainActor
    static var selection: AbilitiesSelection {
        guard let liveService, useLiveBackend else {
            return AbilitiesSelection(service: mockService, escalation: escalationService)
        }
        return AbilitiesSelection(
            service: liveService,
            authorizer: AbilityOAuthAuthorizer(callbackURLScheme: ConfigManager.shared.appUrlScheme),
            escalation: escalationService
        )
    }

    /// Wires the live service to the backend and the session's messaging
    /// stack. Called once from `ConvosApp.init`; built eagerly so flipping
    /// the mock/live toggle later picks it up without a relaunch. The V1
    /// awareness shim gate is read at mutation time, so its toggle is live
    /// immediately too.
    static func configure(session: any SessionManagerProtocol, environment: AppEnvironment) {
        let messaging: AnyMessagingService = session.messagingService()
        let shimWriter = AbilityV1AwarenessShimWriter(
            profileMetadataWriter: messaging.profileMetadataWriter(),
            myInboxIdProvider: {
                try await messaging.sessionStateManager.waitForInboxReadyResult().client.inboxId
            }
        )
        let cache = AbilitiesCatalogDiskCache(environmentName: environment.name)
        catalogCache = cache
        liveService = LiveAbilitiesService(
            apiClient: ConvosAPIClientFactory.client(environment: environment),
            callbackURLScheme: ConfigManager.shared.appUrlScheme,
            cache: cache,
            myInboxIdProvider: {
                try? await messaging.sessionStateManager.waitForInboxReadyResult().client.inboxId
            },
            shimWriter: shimWriter,
            isShimEnabled: { isV1AwarenessShimEnabled }
        )
    }

    /// Launch/foreground refresh hook: updates the live service's
    /// last-known catalog so screen-appear fetches merge against fresh
    /// state. The service resolves its account scope (inbox readiness)
    /// before touching the network or the cache, so a cold-launch call
    /// simply waits for identity instead of writing an accountless
    /// catalog. No-op in mock mode or before `configure`.
    @MainActor
    static func refreshCatalogInBackground() async {
        guard useLiveBackend, let liveService else { return }
        await liveService.refreshCatalog()
    }

    /// Account-wipe hygiene: drops every account's persisted catalog. The
    /// synchronous clear removes the files immediately; the actor hop then
    /// invalidates the service's in-flight fetches and re-clears, so a
    /// catalog refresh that was already on the network can neither commit
    /// nor recreate the wiped files when it resumes.
    ///
    /// Advancing `AbilitiesAccountEpoch` is the view-model half of the same
    /// fence: clearing the actor and the disk says nothing to a screen that
    /// is already holding a snapshot (see `AbilitiesAccountEpoch`).
    static func handleAccountDataWiped() {
        catalogCache?.clearAll()
        advanceAccountEpoch()
        guard let liveService else { return }
        Task { await liveService.handleAccountDataWiped() }
    }

    /// Synchronous whenever the caller is already on the main actor, which
    /// every wipe site is. Deferring the bump to a queued task would leave
    /// a window in which a fetch started under the wiped account can still
    /// commit, because the view models would not yet know the epoch moved.
    private static func advanceAccountEpoch() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { AbilitiesAccountEpoch.shared.advance() }
        } else {
            Task { @MainActor in AbilitiesAccountEpoch.shared.advance() }
        }
    }

    /// Debug sub-toggle under the Abilities V2 flag: live backend versus
    /// the in-memory mock. Coupled to `FeatureFlags.isAbilitiesV2Enabled` in
    /// both directions so the two can never disagree: enabling V2 forces
    /// this on (write-time, in the flag's setter); turning this off forces
    /// V2 off (write-time, below). This getter also reports live whenever
    /// V2 is on regardless of what is stored, so a combination saved before
    /// this coupling existed self-heals on the next read instead of
    /// resurfacing after a relaunch -- there is no user-visible control for
    /// this flag on its own; the Debug menu exposes a single "Abilities v2"
    /// toggle. Defaults to live; production always reads live (the stored
    /// override is only writable from the Debug menu, which dev/local
    /// builds alone can reach -- runtime-gated rather than `#if DEBUG` for
    /// the same reason documented on `CreditsServices`).
    @MainActor
    static var useLiveBackend: Bool {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return true }
        if FeatureFlags.shared.isAbilitiesV2Enabled {
            return true
        }
        if let stored = UserDefaults.standard.object(forKey: Constant.useLiveBackendKey) as? Bool {
            return stored
        }
        return true
    }

    @MainActor
    static func setUseLiveBackend(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useLiveBackendKey)
        if !value {
            FeatureFlags.shared.isAbilitiesV2Enabled = false
        }
    }

    /// Debug sub-toggle for the V1 awareness shim (ProfileUpdate metadata
    /// side-writes on extend/withdraw, for A/B testing agent awareness
    /// during the MCP transition). Default off; never on in production.
    static var isV1AwarenessShimEnabled: Bool {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
        return UserDefaults.standard.bool(forKey: Constant.v1AwarenessShimEnabledKey)
    }

    static func setV1AwarenessShimEnabled(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.v1AwarenessShimEnabledKey)
    }

    /// Debug sub-toggle for the mock consent flow (agent ability-use
    /// requests and delegations). Default off; a dev flips this sub-toggle to
    /// demo the full consent flow so enabling the abilities flag alone does
    /// not inject the scripted card; production always reads false.
    static var isEscalationMockEnabled: Bool {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
        if let stored = UserDefaults.standard.object(forKey: Constant.escalationMockEnabledKey) as? Bool {
            return stored
        }
        return false
    }

    static func setEscalationMockEnabled(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.escalationMockEnabledKey)
    }

    private enum Constant {
        static let useLiveBackendKey: String = "abilitiesServices.useLiveBackend"
        static let v1AwarenessShimEnabledKey: String = "abilitiesServices.v1AwarenessShimEnabled"
        static let escalationMockEnabledKey: String = "abilitiesServices.escalationMockEnabled"
    }
}
