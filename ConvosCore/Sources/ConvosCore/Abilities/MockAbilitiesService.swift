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
        /// Entitled active Google Calendar extended to two conversations,
        /// an expired Spotify, a pending Gmail, and catalog-only abilities.
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
            let response = AbilitiesAPI.CatalogResponse(
                catalogVersion: Constant.catalogVersion,
                entitlementsUnavailable: true,
                abilities: stripped
            )
            return AbilitiesCatalog.resolving(response: response, lastKnown: lastKnownCatalog)
        }
        let response = AbilitiesAPI.CatalogResponse(catalogVersion: Constant.catalogVersion, abilities: abilities)
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
            let entitlement = AbilitiesAPI.Entitlement(status: .active, expiresAt: nil, extensionCount: extensionCount(for: abilityId))
            setEntitlementState(.entitled(entitlement), at: index)
            return AbilityEntitlementInitiation(status: .active)
        case .oauth:
            let entitlement = AbilitiesAPI.Entitlement(status: .pendingAuth, expiresAt: nil, extensionCount: extensionCount(for: abilityId))
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
        let entitlement = AbilitiesAPI.Entitlement(
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
        refreshExtensionCount(for: abilityId, at: index)
    }

    public func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {
        try await simulateLatency()
        try requireAccount()
        let key = ConversationAbilityKey(abilityId: abilityId, agentInboxId: agentInboxId)
        var rows: [ConversationAbility] = extensionsByConversation[conversationId] ?? []
        rows.removeAll { $0.key == key }
        extensionsByConversation[conversationId] = rows
        if let index = abilities.firstIndex(where: { $0.id == abilityId }) {
            refreshExtensionCount(for: abilityId, at: index)
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
    }

    /// Distinct conversations holding at least one live extension for the
    /// ability, the same predicate the backend's `extensionCount` uses.
    private func extensionCount(for abilityId: String) -> Int {
        extensionsByConversation
            .filter { _, rows in rows.contains { $0.abilityId == abilityId } }
            .count
    }

    private func refreshExtensionCount(for abilityId: String, at index: Int) {
        guard let current = abilities[index].entitlement else { return }
        let entitlement = AbilitiesAPI.Entitlement(
            status: current.status,
            expiresAt: current.expiresAt,
            extensionCount: extensionCount(for: abilityId)
        )
        setEntitlementState(.entitled(entitlement), at: index)
    }

    // MARK: - Fixtures

    /// The six launch abilities, with the standard scenario's entitlement
    /// states baked in: Google Calendar active, Spotify expired, Gmail
    /// pending auth, the rest catalog-only.
    public static func standardCatalog() -> [AbilitiesAPI.Ability] {
        [
            AbilitiesAPI.Ability(
                id: "googlecalendar",
                version: 2,
                displayName: AbilitiesAPI.LocalizedText(en: "Google Calendar"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Read and edit events"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    AbilitiesAPI.AbilityBundle(
                        id: "calendar.events",
                        title: AbilitiesAPI.LocalizedText(en: "Events"),
                        description: AbilitiesAPI.LocalizedText(en: "View and edit events on all calendars"),
                        defaultEnabled: true
                    ),
                    AbilitiesAPI.AbilityBundle(
                        id: "calendar.availability",
                        title: AbilitiesAPI.LocalizedText(en: "Availability"),
                        description: AbilitiesAPI.LocalizedText(en: "Share when you are free or busy"),
                        defaultEnabled: false
                    ),
                ],
                entitlementState: .entitled(AbilitiesAPI.Entitlement(
                    status: .active,
                    expiresAt: Date().addingTimeInterval(Constant.mockCredentialLifetime),
                    extensionCount: 2
                ))
            ),
            AbilitiesAPI.Ability(
                id: "gmail",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Gmail"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Read mail and draft replies"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    AbilitiesAPI.AbilityBundle(
                        id: "gmail.read",
                        title: AbilitiesAPI.LocalizedText(en: "Read mail"),
                        description: AbilitiesAPI.LocalizedText(en: "Search and read your messages"),
                        defaultEnabled: true
                    ),
                    AbilitiesAPI.AbilityBundle(
                        id: "gmail.compose",
                        title: AbilitiesAPI.LocalizedText(en: "Compose drafts"),
                        description: AbilitiesAPI.LocalizedText(en: "Create drafts for you to review"),
                        defaultEnabled: false
                    ),
                ],
                entitlementState: .entitled(AbilitiesAPI.Entitlement(status: .pendingAuth, expiresAt: nil, extensionCount: 0))
            ),
            AbilitiesAPI.Ability(
                id: "spotify",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Spotify"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Control playback and playlists"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    AbilitiesAPI.AbilityBundle(
                        id: "spotify.playback",
                        title: AbilitiesAPI.LocalizedText(en: "Playback"),
                        description: AbilitiesAPI.LocalizedText(en: "Play music and manage the queue"),
                        defaultEnabled: true
                    ),
                ],
                entitlementState: .entitled(AbilitiesAPI.Entitlement(
                    status: .expired,
                    expiresAt: Date().addingTimeInterval(-Constant.mockExpiredAge),
                    extensionCount: 1
                ))
            ),
            AbilitiesAPI.Ability(
                id: "coinbase",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Coinbase"),
                subtitle: AbilitiesAPI.LocalizedText(en: "View balances and prices"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    AbilitiesAPI.AbilityBundle(
                        id: "coinbase.portfolio",
                        title: AbilitiesAPI.LocalizedText(en: "Portfolio"),
                        description: AbilitiesAPI.LocalizedText(en: "View balances and positions, read-only"),
                        defaultEnabled: true
                    ),
                ]
            ),
            AbilitiesAPI.Ability(
                id: "shopify",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "Shopify"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Check orders and inventory"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    AbilitiesAPI.AbilityBundle(
                        id: "shopify.orders",
                        title: AbilitiesAPI.LocalizedText(en: "Orders"),
                        description: AbilitiesAPI.LocalizedText(en: "View and update store orders"),
                        defaultEnabled: true
                    ),
                ]
            ),
            AbilitiesAPI.Ability(
                id: "youtube",
                version: 1,
                displayName: AbilitiesAPI.LocalizedText(en: "YouTube"),
                subtitle: AbilitiesAPI.LocalizedText(en: "Search videos and playlists"),
                auth: AbilitiesAPI.AbilityAuth(type: .oauth),
                bundles: [
                    AbilitiesAPI.AbilityBundle(
                        id: "youtube.library",
                        title: AbilitiesAPI.LocalizedText(en: "Library"),
                        description: AbilitiesAPI.LocalizedText(en: "Browse playlists and subscriptions"),
                        defaultEnabled: true
                    ),
                ]
            ),
        ]
    }

    /// Per-conversation opt-ins consistent with `standardCatalog()`'s
    /// extension counts: Google Calendar in two conversations, Spotify in
    /// one (extended while it was still active).
    public static func standardExtensions() -> [String: [ConversationAbility]] {
        [
            Constant.mockConversationOneId: [
                ConversationAbility(
                    abilityId: "googlecalendar",
                    agentInboxId: Constant.mockAgentInboxId,
                    bundleIds: ["calendar.events"]
                ),
                ConversationAbility(
                    abilityId: "spotify",
                    agentInboxId: Constant.mockAgentInboxId,
                    bundleIds: ["spotify.playback"]
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
