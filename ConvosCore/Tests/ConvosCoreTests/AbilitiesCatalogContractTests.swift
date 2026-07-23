@testable import ConvosCore
import Foundation
import Testing

@Suite("AbilitiesAPI catalog wire contract")
struct AbilitiesCatalogContractTests {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decodeCatalog(_ json: String) throws -> AbilitiesAPI.CatalogResponse {
        let data = try #require(json.data(using: .utf8))
        return try decoder().decode(AbilitiesAPI.CatalogResponse.self, from: data)
    }

    private let authoritativeJSON = """
    {
      "catalogVersion": 3,
      "abilities": [
        {
          "id": "googlecalendar",
          "version": 2,
          "displayName": { "en": "Google Calendar" },
          "subtitle": { "en": "Read and edit events" },
          "icon": { "iosUrl": "https://cdn.convos.org/gcal-ios.png", "androidUrl": "https://cdn.convos.org/gcal-android.png" },
          "auth": { "type": "oauth" },
          "bundles": [
            {
              "id": "calendar.events",
              "title": { "en": "Events" },
              "description": { "en": "View and edit events on all calendars" },
              "defaultEnabled": true
            }
          ],
          "entitlement": {
            "status": "active",
            "expiresAt": "2026-09-01T00:00:00Z",
            "extensionCount": 2
          }
        },
        {
          "id": "spotify",
          "version": 1,
          "displayName": { "en": "Spotify" },
          "subtitle": { "en": "Control playback" },
          "auth": { "type": "oauth" },
          "bundles": [],
          "entitlement": null
        }
      ]
    }
    """

    private let unavailableJSON = """
    {
      "catalogVersion": 3,
      "entitlementsUnavailable": true,
      "abilities": [
        {
          "id": "googlecalendar",
          "version": 2,
          "displayName": { "en": "Google Calendar" },
          "subtitle": { "en": "Read and edit events" },
          "auth": { "type": "oauth" },
          "bundles": []
        }
      ]
    }
    """

    private func makeAbility(
        id: String = "spotify",
        version: Int = 1,
        entitlementState: AbilitiesAPI.EntitlementState = .notEntitled
    ) throws -> AbilitiesAPI.Ability {
        try AbilitiesAPI.Ability(
            id: id,
            version: version,
            displayName: AbilitiesAPI.LocalizedText(en: "Spotify"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Control playback"),
            auth: AbilitiesAPI.AbilityAuth(type: .oauth),
            bundles: [],
            entitlementState: entitlementState
        )
    }

    // MARK: - Decoding

    @Test("Authoritative response decodes: entitlement object and explicit null stay distinct")
    func decodesAuthoritativeResponse() throws {
        let response = try decodeCatalog(authoritativeJSON)

        #expect(response.catalogVersion == 3)
        #expect(!response.entitlementsUnavailable)
        #expect(response.abilities.count == 2)

        let gcal = try #require(response.abilities.first { $0.id == "googlecalendar" })
        let entitlement = try #require(gcal.entitlement)
        #expect(entitlement.status == .active)
        #expect(entitlement.extensionCount == 2)
        #expect(entitlement.expiresAt != nil)
        #expect(gcal.icon?.iosUrl == "https://cdn.convos.org/gcal-ios.png")
        #expect(gcal.auth.type == .oauth)
        #expect(gcal.bundles.first?.defaultEnabled == true)

        let spotify = try #require(response.abilities.first { $0.id == "spotify" })
        #expect(spotify.entitlementState == .notEntitled)
        #expect(spotify.entitlement == nil)
        #expect(spotify.icon == nil)
    }

    @Test("Unavailable response decodes: flag true, omitted keys become unknown, never notEntitled")
    func decodesUnavailableResponse() throws {
        let response = try decodeCatalog(unavailableJSON)

        #expect(response.entitlementsUnavailable)
        #expect(response.abilities.count == 1)
        #expect(response.abilities.first?.entitlementState == .unknown)
        #expect(response.abilities.first?.entitlement == nil)
    }

    @Test("Localized map without an en key is rejected")
    func rejectsMissingEnglish() throws {
        let json = """
        {
          "catalogVersion": 1,
          "abilities": [
            {
              "id": "spotify",
              "version": 1,
              "displayName": { "fr": "Spotify" },
              "subtitle": { "en": "Control playback" },
              "auth": { "type": "oauth" },
              "bundles": [],
              "entitlement": null
            }
          ]
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(json)
        }
    }

    @Test("Icon with a missing platform URL is rejected")
    func rejectsPartialIcon() throws {
        let json = """
        {
          "catalogVersion": 1,
          "abilities": [
            {
              "id": "spotify",
              "version": 1,
              "displayName": { "en": "Spotify" },
              "subtitle": { "en": "Control playback" },
              "icon": { "iosUrl": "https://cdn.convos.org/spotify-ios.png" },
              "auth": { "type": "oauth" },
              "bundles": [],
              "entitlement": null
            }
          ]
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(json)
        }
    }

    @Test("Negative catalogVersion, ability version, and extensionCount are rejected")
    func rejectsNegativeIntegers() throws {
        let negativeCatalogVersion = authoritativeJSON.replacingOccurrences(of: "\"catalogVersion\": 3", with: "\"catalogVersion\": -1")
        #expect(throws: DecodingError.self) {
            try decodeCatalog(negativeCatalogVersion)
        }

        let negativeAbilityVersion = authoritativeJSON.replacingOccurrences(of: "\"version\": 2", with: "\"version\": -2")
        #expect(throws: DecodingError.self) {
            try decodeCatalog(negativeAbilityVersion)
        }

        let negativeExtensionCount = authoritativeJSON.replacingOccurrences(of: "\"extensionCount\": 2", with: "\"extensionCount\": -2")
        #expect(throws: DecodingError.self) {
            try decodeCatalog(negativeExtensionCount)
        }
    }

    @Test("Explicit entitlementsUnavailable false is rejected (wire is present-true or absent)")
    func rejectsExplicitFalseFlag() throws {
        let json = """
        {
          "catalogVersion": 1,
          "entitlementsUnavailable": false,
          "abilities": []
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(json)
        }
    }

    @Test("Explicit entitlementsUnavailable null is rejected, never read as absent")
    func rejectsExplicitNullFlag() throws {
        let json = """
        {
          "catalogVersion": 1,
          "entitlementsUnavailable": null,
          "abilities": []
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(json)
        }
    }

    @Test("Icon with an invalid URL string is rejected")
    func rejectsInvalidIconUrl() throws {
        let json = """
        {
          "catalogVersion": 1,
          "abilities": [
            {
              "id": "spotify",
              "version": 1,
              "displayName": { "en": "Spotify" },
              "subtitle": { "en": "Control playback" },
              "icon": { "iosUrl": "not a url", "androidUrl": "https://cdn.convos.org/spotify-android.png" },
              "auth": { "type": "oauth" },
              "bundles": [],
              "entitlement": null
            }
          ]
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(json)
        }
    }

    @Test("Flag/key coherence is enforced both ways")
    func rejectsIncoherentResponses() throws {
        // Authoritative response with a missing entitlement key.
        let missingKey = """
        {
          "catalogVersion": 1,
          "abilities": [
            {
              "id": "spotify",
              "version": 1,
              "displayName": { "en": "Spotify" },
              "subtitle": { "en": "Control playback" },
              "auth": { "type": "oauth" },
              "bundles": []
            }
          ]
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(missingKey)
        }

        // Unavailable response carrying an entitlement key.
        let forbiddenKey = """
        {
          "catalogVersion": 1,
          "entitlementsUnavailable": true,
          "abilities": [
            {
              "id": "spotify",
              "version": 1,
              "displayName": { "en": "Spotify" },
              "subtitle": { "en": "Control playback" },
              "auth": { "type": "oauth" },
              "bundles": [],
              "entitlement": null
            }
          ]
        }
        """
        #expect(throws: DecodingError.self) {
            try decodeCatalog(forbiddenKey)
        }
    }

    @Test("All five contract statuses decode; unknown collapses to expired")
    func statusDecoding() throws {
        func decodeStatus(_ raw: String) throws -> AbilitiesAPI.EntitlementStatus {
            let data = try #require("\"\(raw)\"".data(using: .utf8))
            return try JSONDecoder().decode(AbilitiesAPI.EntitlementStatus.self, from: data)
        }

        #expect(try decodeStatus("pending_auth") == .pendingAuth)
        #expect(try decodeStatus("active") == .active)
        #expect(try decodeStatus("needs_reauth") == .needsReauth)
        #expect(try decodeStatus("expired") == .expired)
        #expect(try decodeStatus("revoked") == .revoked)
        #expect(try decodeStatus("SOMETHING_NEW") == .expired)
        #expect(try decodeStatus("") == .expired)
    }

    @Test("LocalizedText resolves with the en fallback chain")
    func localizedTextFallback() throws {
        let text = try AbilitiesAPI.LocalizedText(values: ["en": "Events", "fr": "Evenements"])
        #expect(text.resolved(for: Locale(identifier: "fr_FR")) == "Evenements")
        #expect(text.resolved(for: Locale(identifier: "de_DE")) == "Events")
    }

    // MARK: - Programmatic construction

    @Test("Initializers enforce decode's invariants, so invalid shapes can never reach encode")
    func constructionValidatesWireInvariants() throws {
        #expect(throws: AbilitiesAPI.WireValidationError.missingEnglishText) {
            _ = try AbilitiesAPI.LocalizedText(values: ["fr": "Spotify"])
        }
        #expect(throws: AbilitiesAPI.WireValidationError.invalidIconUrl("not a url")) {
            _ = try AbilitiesAPI.AbilityIcon(iosUrl: "not a url", androidUrl: "https://cdn.convos.org/spotify-android.png")
        }
        #expect(throws: AbilitiesAPI.WireValidationError.invalidIconUrl("")) {
            _ = try AbilitiesAPI.AbilityIcon(iosUrl: "https://cdn.convos.org/spotify-ios.png", androidUrl: "")
        }
        #expect(throws: AbilitiesAPI.WireValidationError.negativeExtensionCount(-1)) {
            _ = try AbilitiesAPI.Entitlement(status: .active, extensionCount: -1)
        }
        #expect(throws: AbilitiesAPI.WireValidationError.negativeVersion(-2)) {
            _ = try self.makeAbility(version: -2)
        }
        #expect(throws: AbilitiesAPI.WireValidationError.negativeCatalogVersion(-1)) {
            _ = try AbilitiesAPI.CatalogResponse(catalogVersion: -1, abilities: [])
        }
    }

    @Test("Incoherent flag/state combinations cannot be constructed, in either direction")
    func constructionRejectsIncoherentResponses() throws {
        let notEntitled = try makeAbility(entitlementState: .notEntitled)
        #expect(throws: AbilitiesAPI.WireValidationError.incoherentEntitlementState) {
            _ = try AbilitiesAPI.CatalogResponse(catalogVersion: 1, entitlementsUnavailable: true, abilities: [notEntitled])
        }

        let unknown = try makeAbility(entitlementState: .unknown)
        #expect(throws: AbilitiesAPI.WireValidationError.incoherentEntitlementState) {
            _ = try AbilitiesAPI.CatalogResponse(catalogVersion: 1, abilities: [unknown])
        }
    }

    // MARK: - Encoding

    @Test("Authoritative not-entitled encodes an explicit null, unknown omits the key")
    func encodingPreservesNullVersusAbsent() throws {
        let authoritative = try AbilitiesAPI.CatalogResponse(
            catalogVersion: 1,
            abilities: [makeAbility(entitlementState: .notEntitled)]
        )
        let authoritativeData = try JSONEncoder().encode(authoritative)
        let authoritativeObject = try #require(try JSONSerialization.jsonObject(with: authoritativeData) as? [String: Any])
        let authoritativeAbility = try #require((authoritativeObject["abilities"] as? [[String: Any]])?.first)
        #expect(authoritativeAbility.keys.contains("entitlement"))
        #expect(authoritativeAbility["entitlement"] is NSNull)
        #expect(authoritativeObject["entitlementsUnavailable"] == nil)

        let unavailable = try AbilitiesAPI.CatalogResponse(
            catalogVersion: 1,
            entitlementsUnavailable: true,
            abilities: [makeAbility(entitlementState: .unknown)]
        )
        let unavailableData = try JSONEncoder().encode(unavailable)
        let unavailableObject = try #require(try JSONSerialization.jsonObject(with: unavailableData) as? [String: Any])
        let unavailableAbility = try #require((unavailableObject["abilities"] as? [[String: Any]])?.first)
        #expect(!unavailableAbility.keys.contains("entitlement"))
        #expect(unavailableObject["entitlementsUnavailable"] as? Bool == true)
    }

    @Test("Both wire shapes round-trip through encode and decode")
    func roundTrips() throws {
        let authoritative = try decodeCatalog(authoritativeJSON)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let redecodedAuthoritative = try decoder().decode(AbilitiesAPI.CatalogResponse.self, from: encoder.encode(authoritative))
        #expect(redecodedAuthoritative == authoritative)

        let unavailable = try decodeCatalog(unavailableJSON)
        let redecodedUnavailable = try decoder().decode(AbilitiesAPI.CatalogResponse.self, from: encoder.encode(unavailable))
        #expect(redecodedUnavailable == unavailable)
    }

    // MARK: - Resolution against last-known state

    @Test("Resolving under the flag carries last-known entitlements forward")
    func resolvingKeepsLastKnownState() throws {
        let entitled = try makeAbility(
            id: "googlecalendar",
            entitlementState: .entitled(AbilitiesAPI.Entitlement(status: .active, extensionCount: 2))
        )
        let lastKnown = AbilitiesCatalog(catalogVersion: 3, abilities: [entitled])

        let outage = try AbilitiesAPI.CatalogResponse(
            catalogVersion: 4,
            entitlementsUnavailable: true,
            abilities: [entitled.withEntitlementState(.unknown)]
        )
        let merged = AbilitiesCatalog.resolving(response: outage, lastKnown: lastKnown)

        #expect(merged.entitlementsUnavailable)
        #expect(merged.abilities.first?.entitlement?.status == .active)
        #expect(merged.abilities.first?.entitlement?.extensionCount == 2)

        // A merged result used as last-known keeps carrying state through
        // back-to-back outages.
        let secondMerge = AbilitiesCatalog.resolving(response: outage, lastKnown: merged)
        #expect(secondMerge.abilities.first?.entitlement?.status == .active)
    }

    @Test("Resolving a cold-start outage leaves states unknown")
    func resolvingColdStartStaysUnknown() throws {
        let outage = try AbilitiesAPI.CatalogResponse(
            catalogVersion: 1,
            entitlementsUnavailable: true,
            abilities: [makeAbility(entitlementState: .unknown)]
        )
        let resolved = AbilitiesCatalog.resolving(response: outage, lastKnown: nil)

        #expect(resolved.entitlementsUnavailable)
        #expect(resolved.abilities.first?.entitlementState == .unknown)
    }

    @Test("Resolving does not touch authoritative responses")
    func resolvingLeavesAuthoritativeAlone() throws {
        let stale = try AbilitiesCatalog(
            catalogVersion: 1,
            abilities: [makeAbility(entitlementState: .entitled(AbilitiesAPI.Entitlement(status: .active)))]
        )
        let authoritative = try AbilitiesAPI.CatalogResponse(catalogVersion: 2, abilities: [makeAbility(entitlementState: .notEntitled)])

        let resolved = AbilitiesCatalog.resolving(response: authoritative, lastKnown: stale)
        // The authoritative null is the truth: the user is no longer
        // entitled, and stale state must not resurrect it.
        #expect(resolved.abilities.first?.entitlementState == .notEntitled)
        #expect(!resolved.entitlementsUnavailable)
    }
}

@Suite("MockAbilitiesService lifecycle")
struct MockAbilitiesServiceTests {
    private func makeService(scenario: MockAbilitiesService.Scenario = .standard) -> MockAbilitiesService {
        MockAbilitiesService(scenario: scenario, artificialDelay: .zero)
    }

    @Test("Standard scenario serves the seeded entitlement states")
    func standardScenarioFixtures() async throws {
        let service = makeService()
        let catalog = try await service.fetchCatalog()

        #expect(!catalog.entitlementsUnavailable)
        #expect(catalog.abilities.count == 6)
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.extensionCount == 2)
        #expect(catalog.abilities.first { $0.id == "spotify" }?.entitlement?.status == .expired)
        #expect(catalog.abilities.first { $0.id == "gmail" }?.entitlement?.status == .pendingAuth)
        #expect(catalog.abilities.first { $0.id == "coinbase" }?.entitlementState == .notEntitled)
    }

    @Test("Unavailable scenario serves the flag and keeps last-known state")
    func unavailableScenarioKeepsState() async throws {
        let service = makeService(scenario: .entitlementsUnavailable)
        let catalog = try await service.fetchCatalog()

        #expect(catalog.entitlementsUnavailable)
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
    }

    @Test("Cold-start outage serves the flag with every state unknown")
    func coldStartOutageServesUnknown() async throws {
        let service = makeService(scenario: .entitlementsUnavailableColdStart)
        let catalog = try await service.fetchCatalog()

        #expect(catalog.entitlementsUnavailable)
        #expect(catalog.abilities.count == 6)
        #expect(catalog.abilities.allSatisfy { $0.entitlementState == .unknown })
    }

    @Test("Device-only scenario serves the catalog with explicit null entitlements")
    func deviceOnlyScenario() async throws {
        let service = makeService(scenario: .deviceOnly)
        let catalog = try await service.fetchCatalog()

        #expect(catalog.abilities.count == 6)
        #expect(catalog.abilities.allSatisfy { $0.entitlementState == .notEntitled })
    }

    @Test("Device-only callers cannot begin or extend entitlements")
    func deviceOnlyRejectsMutations() async throws {
        let service = makeService(scenario: .deviceOnly)

        await #expect(throws: AbilitiesServiceError.accountRequired) {
            _ = try await service.beginEntitlement(abilityId: "coinbase")
        }
        await #expect(throws: AbilitiesServiceError.accountRequired) {
            try await service.extendAbility(
                conversationId: "conversation-a",
                abilityId: "coinbase",
                agentInboxId: "agent-1",
                bundleIds: ["coinbase.portfolio"]
            )
        }
    }

    @Test("OAuth connect goes pending with a redirect; completion is a separate step")
    func oauthLifecycle() async throws {
        let service = makeService()

        let initiation = try await service.beginEntitlement(abilityId: "coinbase")
        #expect(initiation.status == .pendingAuth)
        #expect(initiation.redirectUrl != nil)

        var catalog = try await service.fetchCatalog()
        #expect(catalog.abilities.first { $0.id == "coinbase" }?.entitlement?.status == .pendingAuth)

        try await service.completeEntitlement(abilityId: "coinbase")
        catalog = try await service.fetchCatalog()
        #expect(catalog.abilities.first { $0.id == "coinbase" }?.entitlement?.status == .active)
    }

    @Test("Extending requires an active entitlement")
    func extendRequiresActiveEntitlement() async throws {
        let service = makeService()

        await #expect(throws: AbilitiesServiceError.needsEntitlement(abilityId: "coinbase")) {
            try await service.extendAbility(
                conversationId: "conversation-a",
                abilityId: "coinbase",
                agentInboxId: "agent-1",
                bundleIds: ["coinbase.portfolio"]
            )
        }
    }

    @Test("Extending counts distinct conversations, not rows")
    func extensionCountCountsConversations() async throws {
        let service = makeService()

        try await service.extendAbility(
            conversationId: "conversation-a",
            abilityId: "googlecalendar",
            agentInboxId: "agent-1",
            bundleIds: ["calendar.events"]
        )
        try await service.extendAbility(
            conversationId: "conversation-a",
            abilityId: "googlecalendar",
            agentInboxId: "agent-2",
            bundleIds: ["calendar.events"]
        )

        let catalog = try await service.fetchCatalog()
        // Two seeded conversations plus conversation-a; two agents in the
        // same conversation still count once.
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.extensionCount == 3)

        let rows = try await service.conversationAbilities(conversationId: "conversation-a")
        #expect(rows.count == 2)
    }

    @Test("Revoking cascades conversation extensions")
    func revokeCascades() async throws {
        let service = makeService()

        try await service.revokeEntitlement(abilityId: "googlecalendar")

        let catalog = try await service.fetchCatalog()
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlementState == .notEntitled)

        let conversationOne = try await service.conversationAbilities(conversationId: "mock-conversation-1")
        #expect(conversationOne.allSatisfy { $0.abilityId != "googlecalendar" })
        let conversationTwo = try await service.conversationAbilities(conversationId: "mock-conversation-2")
        #expect(conversationTwo.isEmpty)
    }

    @Test("Withdrawing an agent opt-in updates the count when the last row goes")
    func withdrawUpdatesCount() async throws {
        let service = makeService()

        try await service.withdrawAbility(
            conversationId: "mock-conversation-2",
            abilityId: "googlecalendar",
            agentInboxId: "mock-agent-inbox-1"
        )

        let catalog = try await service.fetchCatalog()
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.extensionCount == 1)
    }
}
