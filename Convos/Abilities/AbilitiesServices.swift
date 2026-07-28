import ConvosCore
import Foundation

/// Process-wide accessor for the active `AbilitiesServiceProtocol` backing
/// the flag-gated V2 abilities surfaces (the App Settings abilities list
/// and the per-conversation abilities section). One instance app-wide so
/// state changes carry across surfaces (connecting an ability in settings
/// is immediately visible in conversation info).
///
/// `configure(...)` wires the live transport at app start; the Debug menu's
/// mock/live sub-toggle (default live) picks which instance `shared`
/// serves. Previews and tests never call `configure`, so they fall back to
/// the mock, mirroring `CreditsServices`.
enum AbilitiesServices {
    /// Set once during `ConvosApp.init` before any surface can read it;
    /// the actor-based service handles its own concurrency.
    nonisolated(unsafe) private static var liveService: LiveAbilitiesService?
    private static let mockService: MockAbilitiesService = MockAbilitiesService()

    static var shared: any AbilitiesServiceProtocol {
        guard let liveService else { return mockService }
        return useLiveBackend ? liveService : mockService
    }

    /// The browser-session authorizer paired with `shared`. Nil while the
    /// mock service is active -- the stub authorization sheet stands in --
    /// so a mock connect never opens a real browser.
    static var oauthAuthorizer: (any AbilityAuthorizing)? {
        guard liveService != nil, useLiveBackend else { return nil }
        return AbilityOAuthAuthorizer(callbackURLScheme: ConfigManager.shared.appUrlScheme)
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
        liveService = LiveAbilitiesService(
            apiClient: ConvosAPIClientFactory.client(environment: environment),
            callbackURLScheme: ConfigManager.shared.appUrlScheme,
            cache: AbilitiesCatalogDiskCache(environmentName: environment.name),
            myInboxIdProvider: {
                try? await messaging.sessionStateManager.waitForInboxReadyResult().client.inboxId
            },
            shimWriter: shimWriter,
            isShimEnabled: { isV1AwarenessShimEnabled }
        )
    }

    /// Launch/foreground refresh hook: updates the live service's
    /// last-known catalog so screen-appear fetches merge against fresh
    /// state. No-op in mock mode or before `configure`.
    static func refreshCatalogInBackground() async {
        guard useLiveBackend, let liveService else { return }
        await liveService.refreshCatalog()
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
