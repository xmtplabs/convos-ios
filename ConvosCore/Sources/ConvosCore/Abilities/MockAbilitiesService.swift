import Foundation

/// In-memory `AbilitiesServiceProtocol` backing previews, tests, and the
/// flag-gated V2 surfaces until the live transport lands. State mutates the
/// way the real service would: connecting walks the entitlement lifecycle,
/// extending adds per-agent opt-ins and bumps the entitlement's
/// distinct-conversation `extensionCount`, revoking cascades extensions,
/// and device-only callers are rejected with `accountRequired`.
public actor MockAbilitiesService: AbilitiesServiceProtocol {
    /// Seed states for previews and tests.
    public enum Scenario: Sendable {
        /// The full first-round catalog: an entitled active Google Calendar
        /// extended to two conversations, a pending-auth Spotify, an
        /// expired Coinbase, and catalog-only Gmail, Shopify, and YouTube.
        case standard
        /// The standard catalog served under `entitlementsUnavailable`
        /// after the caller has seen an authoritative response: last-known
        /// entitlement state is carried forward.
        case entitlementsUnavailable
        /// An outage on the very first fetch: `entitlementsUnavailable`
        /// with no last-known state to carry forward, so every ability
        /// resolves `.unknown` and the UI must withhold connect controls.
        case entitlementsUnavailableColdStart
        /// Device-only caller (no account yet): full catalog, every
        /// entitlement `null`. Browsable, not entitleable -- mutations
        /// throw `AbilitiesServiceError.accountRequired`.
        case deviceOnly
    }

    private let scenario: Scenario
    private var abilities: [AbilitiesAPI.Ability]
    private var extensionsByConversation: [String: [ConversationAbility]]
    private var servesEntitlementsUnavailable: Bool
    private var lastKnownCatalog: AbilitiesCatalog?
    private let artificialDelay: Duration

    public init(scenario: Scenario = .standard, artificialDelay: Duration = .milliseconds(150)) {
        self.scenario = scenario
        self.artificialDelay = artificialDelay
        switch scenario {
        case .standard:
            self.abilities = Self.standardCatalog()
            self.extensionsByConversation = Self.standardExtensions()
            self.servesEntitlementsUnavailable = false
        case .entitlementsUnavailable:
            self.abilities = Self.standardCatalog()
            self.extensionsByConversation = Self.standardExtensions()
            self.servesEntitlementsUnavailable = true
            // The outage started after the caller last saw an authoritative
            // response, so fetches keep carrying that state forward.
            self.lastKnownCatalog = AbilitiesCatalog(
                catalogVersion: Constant.catalogVersion,
                abilities: abilities
            )
        case .entitlementsUnavailableColdStart:
            self.abilities = Self.standardCatalog()
            self.extensionsByConversation = Self.standardExtensions()
            self.servesEntitlementsUnavailable = true
        case .deviceOnly:
            self.abilities = Self.standardCatalog().map { $0.withEntitlementState(.notEntitled) }
            self.extensionsByConversation = [:]
            self.servesEntitlementsUnavailable = false
        }
    }

    // MARK: - AbilitiesServiceProtocol

    public func fetchCatalog() async throws -> AbilitiesCatalog {
        try await simulateLatency()
        if servesEntitlementsUnavailable {
            let stripped: [AbilitiesAPI.Ability] = abilities.map { $0.withEntitlementState(.unknown) }
            let response = try AbilitiesAPI.CatalogResponse(
                catalogVersion: Constant.catalogVersion,
                entitlementsUnavailable: true,
                abilities: stripped
            )
            return AbilitiesCatalog.resolving(response: response, lastKnown: lastKnownCatalog)
        }
        let response = try AbilitiesAPI.CatalogResponse(catalogVersion: Constant.catalogVersion, abilities: abilities)
        let catalog = AbilitiesCatalog.resolving(response: response, lastKnown: lastKnownCatalog)
        lastKnownCatalog = catalog
        return catalog
    }

    public func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation {
        try await simulateLatency()
        try requireAccount()
        guard let index = abilities.firstIndex(where: { $0.id == abilityId }) else {
            throw AbilitiesServiceError.unknownAbility(abilityId: abilityId)
        }
        switch abilities[index].auth.type {
        case .none:
            let entitlement = try AbilitiesAPI.Entitlement(status: .active, expiresAt: nil, extensionCount: extensionCount(for: abilityId))
            setEntitlementState(.entitled(entitlement), at: index)
            return AbilityEntitlementInitiation(status: .active)
        case .oauth:
            let entitlement = try AbilitiesAPI.Entitlement(status: .pendingAuth, expiresAt: nil, extensionCount: extensionCount(for: abilityId))
            setEntitlementState(.entitled(entitlement), at: index)
            return AbilityEntitlementInitiation(status: .pendingAuth, redirectUrl: "https://mock.convos.org/oauth/\(abilityId)")
        }
    }

    public func completeEntitlement(abilityId: String) async throws {
        try await simulateLatency()
        try requireAccount()
        guard let index = abilities.firstIndex(where: { $0.id == abilityId }) else {
            throw AbilitiesServiceError.unknownAbility(abilityId: abilityId)
        }
        let entitlement = try AbilitiesAPI.Entitlement(
            status: .active,
            expiresAt: Date().addingTimeInterval(Constant.mockCredentialLifetime),
            extensionCount: extensionCount(for: abilityId)
        )
        setEntitlementState(.entitled(entitlement), at: index)
    }

    public func revokeEntitlement(abilityId: String) async throws {
        try await simulateLatency()
        try requireAccount()
        guard let index = abilities.firstIndex(where: { $0.id == abilityId }) else {
            throw AbilitiesServiceError.unknownAbility(abilityId: abilityId)
        }
        // Cascade: revoking the entitlement withdraws every conversation
        // extension backed by it.
        for (conversationId, rows) in extensionsByConversation {
            extensionsByConversation[conversationId] = rows.filter { $0.abilityId != abilityId }
        }
        setEntitlementState(.notEntitled, at: index)
    }

    public func conversationAbilities(conversationId: String) async throws -> [ConversationAbility] {
        try await simulateLatency()
        return extensionsByConversation[conversationId] ?? []
    }

    public func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws {
        try await simulateLatency()
        try requireAccount()
        guard let index = abilities.firstIndex(where: { $0.id == abilityId }) else {
            throw AbilitiesServiceError.unknownAbility(abilityId: abilityId)
        }
        guard abilities[index].entitlement?.status == .active else {
            throw AbilitiesServiceError.needsEntitlement(abilityId: abilityId)
        }
        let key = ConversationAbilityKey(abilityId: abilityId, agentInboxId: agentInboxId)
        var rows: [ConversationAbility] = extensionsByConversation[conversationId] ?? []
        rows.removeAll { $0.key == key }
        rows.append(ConversationAbility(abilityId: abilityId, agentInboxId: agentInboxId, bundleIds: bundleIds))
        extensionsByConversation[conversationId] = rows
        try refreshExtensionCount(for: abilityId, at: index)
    }

    public func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        try await simulateLatency()
        try requireAccount()
        let key = ConversationAbilityKey(abilityId: abilityId, agentInboxId: agentInboxId)
        var rows: [ConversationAbility] = extensionsByConversation[conversationId] ?? []
        rows.removeAll { $0.key == key }
        extensionsByConversation[conversationId] = rows
        if let index = abilities.firstIndex(where: { $0.id == abilityId }) {
            try refreshExtensionCount(for: abilityId, at: index)
        }
    }

    // MARK: - State helpers

    private func simulateLatency() async throws {
        guard artificialDelay > .zero else { return }
        try await Task.sleep(for: artificialDelay)
    }

    /// Device-only callers can browse the catalog but never mutate
    /// entitlement state.
    private func requireAccount() throws {
        guard scenario != .deviceOnly else { throw AbilitiesServiceError.accountRequired }
    }

    private func setEntitlementState(_ state: AbilitiesAPI.EntitlementState, at index: Int) {
        abilities[index] = abilities[index].withEntitlementState(state)
        updateLastKnownState(state, forAbilityId: abilities[index].id)
    }

    /// A successful mutation is authoritative knowledge for that ability
    /// even while fetches serve `entitlementsUnavailable`: fold it into
    /// the last-known catalog so the next fetch's merge does not visually
    /// revert a connect, completion, revoke, or extension-count change.
    /// With no cache yet the mutated ability becomes the only known state
    /// (only reachable mid-outage; authoritative fetches rebuild the cache
    /// from live state anyway).
    private func updateLastKnownState(_ state: AbilitiesAPI.EntitlementState, forAbilityId abilityId: String) {
        let baseline: AbilitiesCatalog
        if let lastKnownCatalog {
            baseline = lastKnownCatalog
        } else if servesEntitlementsUnavailable {
            baseline = AbilitiesCatalog(
                catalogVersion: Constant.catalogVersion,
                entitlementsUnavailable: true,
                abilities: abilities.map { $0.withEntitlementState(.unknown) }
            )
        } else {
            return
        }
        let updated: [AbilitiesAPI.Ability] = baseline.abilities.map { (ability: AbilitiesAPI.Ability) -> AbilitiesAPI.Ability in
            guard ability.id == abilityId else { return ability }
            return ability.withEntitlementState(state)
        }
        lastKnownCatalog = AbilitiesCatalog(
            catalogVersion: baseline.catalogVersion,
            entitlementsUnavailable: baseline.entitlementsUnavailable,
            abilities: updated
        )
    }

    /// Distinct conversations holding at least one live extension for the
    /// ability, the same predicate the backend's `extensionCount` uses.
    private func extensionCount(for abilityId: String) -> Int {
        extensionsByConversation
            .filter { _, rows in rows.contains { $0.abilityId == abilityId } }
            .count
    }

    private func refreshExtensionCount(for abilityId: String, at index: Int) throws {
        guard let current = abilities[index].entitlement else { return }
        let entitlement = try AbilitiesAPI.Entitlement(
            status: current.status,
            expiresAt: current.expiresAt,
            extensionCount: extensionCount(for: abilityId)
        )
        setEntitlementState(.entitled(entitlement), at: index)
    }

    // MARK: - Fixtures

    /// The six first-round abilities with the standard scenario's
    /// entitlement states baked in: Google Calendar active, Spotify
    /// pending auth, Coinbase expired, the rest catalog-only. Display
    /// copy mirrors the backend manifests; bundles are mock-only fixtures
    /// in the style the service catalog will serve. Non-throwing for previews: the
    /// fixture is known-valid, and a wire-validation failure here is a
    /// programmer error surfaced by the fixture tests, not a recoverable
    /// condition.
    public static func standardCatalog() -> [AbilitiesAPI.Ability] {
        do {
            return try makeStandardCatalog()
        } catch {
            Log.error("Invalid mock abilities fixture: \(error)")
            return []
        }
    }

    private static func makeStandardCatalog() throws -> [AbilitiesAPI.Ability] {
        return try [
            AbilitiesAPI.Ability(
                id: "googlecalendar",
                version: 2,
                displayName: AbilitiesAPI.LocalizedText(en: "Google Calendar"),
                subtitle: AbilitiesAPI.LocalizedText(en: "View and edit events"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    bundle("calendar.events", title: "Events", description: "View and edit events on all calendars", defaultEnabled: true),
                    bundle("calendar.availability", title: "Availability", description: "Share when you are free or busy", defaultEnabled: false),
                ],
                entitlementState: .entitled(AbilitiesAPI.Entitlement(
                    status: .active,
                    expiresAt: Date().addingTimeInterval(Constant.mockCredentialLifetime),
                    extensionCount: 2
                ))
            ),
            AbilitiesAPI.Ability(
                id: "spotify",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Spotify"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Playlists, artists, and concerts"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    bundle("spotify.playback", title: "Playback", description: "Play music and manage the queue", defaultEnabled: true),
                    bundle("spotify.playlists", title: "Playlists", description: "Create and edit your playlists", defaultEnabled: false),
                ],
                entitlementState: .entitled(AbilitiesAPI.Entitlement(status: .pendingAuth, expiresAt: nil, extensionCount: 0))
            ),
            AbilitiesAPI.Ability(
                id: "coinbase",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Coinbase"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Check prices and balances"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    bundle("coinbase.prices", title: "Prices", description: "Check live market prices", defaultEnabled: true),
                    bundle("coinbase.portfolio", title: "Portfolio", description: "View balances and positions, read-only", defaultEnabled: false),
                ],
                entitlementState: .entitled(AbilitiesAPI.Entitlement(
                    status: .expired,
                    expiresAt: Date().addingTimeInterval(-Constant.mockExpiredAge),
                    extensionCount: 1
                ))
            ),
            AbilitiesAPI.Ability(
                id: "youtube",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "YouTube"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Search and share videos"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    bundle("youtube.search", title: "Search", description: "Find videos to share in the convo", defaultEnabled: true),
                    bundle("youtube.library", title: "Library", description: "Browse playlists and subscriptions", defaultEnabled: false),
                ]
            ),
            AbilitiesAPI.Ability(
                id: "shopify",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Shopify"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Manage your shop"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    bundle("shopify.orders", title: "Orders", description: "View and update store orders", defaultEnabled: true),
                    bundle("shopify.products", title: "Products", description: "Manage listings and inventory", defaultEnabled: false),
                ]
            ),
            AbilitiesAPI.Ability(
                id: "gmail",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Gmail"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Read and send email"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    bundle("gmail.read", title: "Read mail", description: "Search and read your messages", defaultEnabled: true),
                    bundle("gmail.compose", title: "Compose drafts", description: "Create drafts for you to review", defaultEnabled: false),
                ]
            ),
        ]
    }

    /// One-line bundle factory keeping the fixture readable: mock bundles
    /// carry English-only copy by construction.
    private static func bundle(_ id: String, title: String, description: String, defaultEnabled: Bool) -> AbilitiesAPI.AbilityBundle {
        AbilitiesAPI.AbilityBundle(
            id: id,
            title: AbilitiesAPI.LocalizedText(en: title),
            description: AbilitiesAPI.LocalizedText(en: description),
            defaultEnabled: defaultEnabled
        )
    }

    /// Per-conversation opt-ins consistent with `standardCatalog()`'s
    /// extension counts: Google Calendar in two conversations, Coinbase in
    /// one (extended while its entitlement was still active). Pending-auth
    /// Spotify holds none: extending requires an active entitlement.
    public static func standardExtensions() -> [String: [ConversationAbility]] {
        [
            Constant.mockConversationOneId: [
                ConversationAbility(
                    abilityId: "googlecalendar",
                    agentInboxId: Constant.mockAgentInboxId,
                    bundleIds: ["calendar.events"]
                ),
                ConversationAbility(
                    abilityId: "coinbase",
                    agentInboxId: Constant.mockAgentInboxId,
                    bundleIds: ["coinbase.prices"]
                ),
            ],
            Constant.mockConversationTwoId: [
                ConversationAbility(
                    abilityId: "googlecalendar",
                    agentInboxId: Constant.mockAgentInboxId,
                    bundleIds: ["calendar.events", "calendar.availability"]
                ),
            ],
        ]
    }

    private enum Constant {
        static let catalogVersion: Int = 7
        static let mockCredentialLifetime: TimeInterval = 60 * 60 * 24 * 40
        static let mockExpiredAge: TimeInterval = 60 * 60 * 24 * 10
        static let mockConversationOneId: String = "mock-conversation-1"
        static let mockConversationTwoId: String = "mock-conversation-2"
        static let mockAgentInboxId: String = "mock-agent-inbox-1"
    }
}
