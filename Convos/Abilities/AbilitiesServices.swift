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
    /// Announces landed per-chat opt-ins to the agent runtime's grant
    /// ledger (profile metadata + backend consent record + transcript
    /// event), so a toggled-on ability is usable without the agent
    /// carding for consent the member already gave. Nil in mock mode and
    /// before `configure`; a nil announcer keeps the backend-only
    /// behavior (the agent cards once).
    let announcer: (any AbilityGrantAnnouncing)?

    init(
        service: any AbilitiesServiceProtocol,
        authorizer: (any AbilityAuthorizing)? = nil,
        announcer: (any AbilityGrantAnnouncing)? = nil
    ) {
        self.service = service
        self.authorizer = authorizer
        self.announcer = announcer
    }
}

/// Process-wide accessor for the active abilities configuration backing
/// the abilities surfaces (the App Settings abilities list and the
/// per-conversation abilities section). One service instance app-wide so
/// state changes carry across surfaces (connecting an ability in settings
/// is immediately visible in conversation info).
///
/// `configure(...)` wires the live transport at app start. Previews and tests
/// never call `configure`, so they fall back to the mock, mirroring
/// `CreditsServices`.
enum AbilitiesServices {
    /// Set once during `ConvosApp.init` before any surface can read them;
    /// the actor-based service handles its own concurrency.
    nonisolated(unsafe) private static var liveService: LiveAbilitiesService?
    nonisolated(unsafe) private static var catalogCache: AbilitiesCatalogDiskCache?
    /// The session's conversations, read fresh on every call. Captured as a
    /// closure rather than a retained repository so the read happens off the
    /// main actor at the moment the detail screen asks for it.
    nonisolated(unsafe) private static var conversationsProvider: (@Sendable () async throws -> [Conversation])?
    nonisolated(unsafe) private static var liveGrantAnnouncer: (any AbilityGrantAnnouncing)?
    private static let mockService: MockAbilitiesService = MockAbilitiesService()

    /// The atomic (service, authorizer) pair for the current mode. Resolve
    /// once per screen/view-model lifetime and pass the whole value down;
    /// never read the halves at different times.
    @MainActor
    static var selection: AbilitiesSelection {
        guard let liveService else {
            return AbilitiesSelection(service: mockService)
        }
        return AbilitiesSelection(
            service: liveService,
            authorizer: AbilityOAuthAuthorizer(callbackURLScheme: ConfigManager.shared.appUrlScheme),
            announcer: liveGrantAnnouncer
        )
    }

    /// Where the connection detail screen's Agents and Convos sections come
    /// from. Live mode fans out over the session's conversations (the
    /// backend serves no inverse of the per-conversation opt-in read); mock
    /// mode and any surface reached before `configure` use the fixture
    /// source, so the screen never renders another account's rows.
    @MainActor
    static var connectionUsageSource: any ConnectionUsageSourcing {
        guard let liveService else {
            return PreviewConnectionUsageSource(service: mockService)
        }
        guard let conversationsProvider else { return EmptyConnectionUsageSource() }
        return ConversationConnectionUsageSource(service: liveService, conversations: conversationsProvider)
    }

    /// Wires the live service to the backend and the session's messaging
    /// stack. Called once from `ConvosApp.init`; built eagerly so flipping
    /// the mock/live toggle later picks it up without a relaunch.
    static func configure(session: any SessionManagerProtocol, environment: AppEnvironment) {
        let messaging: AnyMessagingService = session.messagingService()
        let cache = AbilitiesCatalogDiskCache(environmentName: environment.name)
        catalogCache = cache
        conversationsProvider = {
            let repository = session.conversationsRepository(for: [.allowed, .unknown])
            return try await repository.fetchAll()
        }
        liveService = LiveAbilitiesService(
            apiClient: ConvosAPIClientFactory.client(environment: environment),
            callbackURLScheme: ConfigManager.shared.appUrlScheme,
            cache: cache,
            myInboxIdProvider: {
                try? await messaging.sessionStateManager.waitForInboxReadyResult().client.inboxId
            }
        )
        // Successor to the deleted v1 awareness shim (#1442), production-on
        // by design: landed toggles route through the same grant writer the
        // capability-card path uses, so the agent stops carding for consent
        // already given. See `CloudAbilityGrantAnnouncer`.
        let connectionManager = session.cloudConnectionManager(
            callbackURLScheme: ConfigManager.shared.appUrlScheme
        )
        liveGrantAnnouncer = CloudAbilityGrantAnnouncer(
            repository: session.cloudConnectionRepository(),
            grantWriter: { messaging.connectionGrantWriter() },
            eventWriter: { messaging.connectionEventWriter() },
            refreshConnections: { _ = try await connectionManager.refreshConnections() }
        )
    }

    /// Launch/foreground refresh hook: updates the live service's
    /// last-known catalog so screen-appear fetches merge against fresh
    /// state. The service resolves its account scope (inbox readiness)
    /// before touching the network or the cache, so a cold-launch call
    /// simply waits for identity instead of writing an accountless
    /// catalog. No-op before `configure`.
    @MainActor
    static func refreshCatalogInBackground() async {
        guard let liveService else { return }
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
}
