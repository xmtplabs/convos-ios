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

    init(service: any AbilitiesServiceProtocol, authorizer: (any AbilityAuthorizing)? = nil) {
        self.service = service
        self.authorizer = authorizer
    }
}

/// Process-wide accessor for the active abilities configuration backing
/// the flag-gated V2 abilities surfaces (the App Settings abilities list
/// and the per-conversation abilities section). One service instance
/// app-wide so state changes carry across surfaces (connecting an ability
/// in settings is immediately visible in conversation info).
///
/// `configure(...)` wires the live transport at app start; the Debug menu's
/// mock/live sub-toggle (default live) picks which pair `selection`
/// serves. Previews and tests never call `configure`, so they fall back to
/// the mock, mirroring `CreditsServices`.
enum AbilitiesServices {
    /// Set once during `ConvosApp.init` before any surface can read them;
    /// the actor-based service handles its own concurrency.
    nonisolated(unsafe) private static var liveService: LiveAbilitiesService?
    nonisolated(unsafe) private static var catalogCache: AbilitiesCatalogDiskCache?
    private static let mockService: MockAbilitiesService = MockAbilitiesService()

    /// The atomic (service, authorizer) pair for the current mode. Resolve
    /// once per screen/view-model lifetime and pass the whole value down;
    /// never read the halves at different times.
    static var selection: AbilitiesSelection {
        guard let liveService, useLiveBackend else {
            return AbilitiesSelection(service: mockService)
        }
        return AbilitiesSelection(
            service: liveService,
            authorizer: AbilityOAuthAuthorizer(callbackURLScheme: ConfigManager.shared.appUrlScheme)
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
    static func refreshCatalogInBackground() async {
        guard useLiveBackend, let liveService else { return }
        await liveService.refreshCatalog()
    }

    /// Account-wipe hygiene: drops every account's persisted catalog. The
    /// synchronous clear removes the files immediately; the actor hop then
    /// invalidates the service's in-flight fetches and re-clears, so a
    /// catalog refresh that was already on the network can neither commit
    /// nor recreate the wiped files when it resumes.
    static func handleAccountDataWiped() {
        catalogCache?.clearAll()
        guard let liveService else { return }
        Task { await liveService.handleAccountDataWiped() }
    }

    /// Debug sub-toggle under the Abilities V2 flag: live backend versus
    /// the in-memory mock. Defaults to live; production always reads live
    /// (the stored override is only writable from the Debug menu, which
    /// dev/local builds alone can reach -- runtime-gated rather than
    /// `#if DEBUG` for the same reason documented on `CreditsServices`).
    static var useLiveBackend: Bool {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return true }
        if let stored = UserDefaults.standard.object(forKey: Constant.useLiveBackendKey) as? Bool {
            return stored
        }
        return true
    }

    static func setUseLiveBackend(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useLiveBackendKey)
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

    private enum Constant {
        static let useLiveBackendKey: String = "abilitiesServices.useLiveBackend"
        static let v1AwarenessShimEnabledKey: String = "abilitiesServices.v1AwarenessShimEnabled"
    }
}
