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

    @Test("Authoritative response decodes: entitlement object and explicit null")
    func decodesAuthoritativeResponse() throws {
        let data = try #require(authoritativeJSON.data(using: .utf8))
        let response = try decoder().decode(AbilitiesAPI.CatalogResponse.self, from: data)

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
        #expect(spotify.entitlement == nil)
        #expect(spotify.icon == nil)
    }

    @Test("Unavailable response decodes: flag true, no entitlement keys")
    func decodesUnavailableResponse() throws {
        let data = try #require(unavailableJSON.data(using: .utf8))
        let response = try decoder().decode(AbilitiesAPI.CatalogResponse.self, from: data)

        #expect(response.entitlementsUnavailable)
        #expect(response.abilities.count == 1)
        #expect(response.abilities.first?.entitlement == nil)
    }

    @Test("Absent flag decodes as false")
    func absentFlagDecodesFalse() throws {
        let data = try #require(authoritativeJSON.data(using: .utf8))
        let response = try decoder().decode(AbilitiesAPI.CatalogResponse.self, from: data)
        #expect(!response.entitlementsUnavailable)
    }

    @Test("Encoding omits the flag when false and writes it when true")
    func encodingMatchesWireShape() throws {
        let authoritative = AbilitiesAPI.CatalogResponse(catalogVersion: 1, abilities: [])
        let authoritativeData = try JSONEncoder().encode(authoritative)
        let authoritativeObject = try #require(try JSONSerialization.jsonObject(with: authoritativeData) as? [String: Any])
        #expect(authoritativeObject["entitlementsUnavailable"] == nil)

        let unavailable = AbilitiesAPI.CatalogResponse(catalogVersion: 1, entitlementsUnavailable: true, abilities: [])
        let unavailableData = try JSONEncoder().encode(unavailable)
        let unavailableObject = try #require(try JSONSerialization.jsonObject(with: unavailableData) as? [String: Any])
        #expect(unavailableObject["entitlementsUnavailable"] as? Bool == true)
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
    func localizedTextFallback() {
        let text = AbilitiesAPI.LocalizedText(values: ["en": "Events", "fr": "Evenements"])
        #expect(text.resolved(for: Locale(identifier: "fr_FR")) == "Evenements")
        #expect(text.resolved(for: Locale(identifier: "de_DE")) == "Events")
        let empty = AbilitiesAPI.LocalizedText(values: [:])
        #expect(empty.resolved(for: Locale(identifier: "en_US")).isEmpty)
    }

    @Test("Merging under the flag carries last-known entitlements forward")
    func mergeKeepsLastKnownState() throws {
        let entitled = AbilitiesAPI.Ability(
            id: "googlecalendar",
            version: 2,
            displayName: AbilitiesAPI.LocalizedText(en: "Google Calendar"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Read and edit events"),
            auth: AbilitiesAPI.AbilityAuth(type: .oauth),
            bundles: [],
            entitlement: AbilitiesAPI.Entitlement(status: .active, extensionCount: 2)
        )
        let lastKnown = AbilitiesAPI.CatalogResponse(catalogVersion: 3, abilities: [entitled])

        let outage = AbilitiesAPI.CatalogResponse(
            catalogVersion: 4,
            entitlementsUnavailable: true,
            abilities: [entitled.withEntitlement(nil)]
        )
        let merged = outage.keepingLastKnownEntitlements(from: lastKnown)

        #expect(merged.entitlementsUnavailable)
        #expect(merged.abilities.first?.entitlement?.status == .active)
        #expect(merged.abilities.first?.entitlement?.extensionCount == 2)

        // A merged result used as last-known keeps carrying state through
        // back-to-back outages.
        let secondOutage = outage.keepingLastKnownEntitlements(from: merged)
        #expect(secondOutage.abilities.first?.entitlement?.status == .active)
    }

    @Test("Merging does not touch authoritative responses")
    func mergeLeavesAuthoritativeAlone() {
        let ability = AbilitiesAPI.Ability(
            id: "spotify",
            version: 1,
            displayName: AbilitiesAPI.LocalizedText(en: "Spotify"),
            subtitle: AbilitiesAPI.LocalizedText(en: "Control playback"),
            auth: AbilitiesAPI.AbilityAuth(type: .oauth),
            bundles: [],
            entitlement: nil
        )
        let stale = AbilitiesAPI.CatalogResponse(
            catalogVersion: 1,
            abilities: [ability.withEntitlement(AbilitiesAPI.Entitlement(status: .active))]
        )
        let authoritative = AbilitiesAPI.CatalogResponse(catalogVersion: 2, abilities: [ability])

        let result = authoritative.keepingLastKnownEntitlements(from: stale)
        // The authoritative null is the truth: the user is no longer
        // entitled, and stale state must not resurrect it.
        #expect(result.abilities.first?.entitlement == nil)
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
        #expect(catalog.abilities.first { $0.id == "coinbase" }?.entitlement == nil)
    }

    @Test("Unavailable scenario serves the flag and keeps last-known state")
    func unavailableScenarioKeepsState() async throws {
        let service = makeService(scenario: .entitlementsUnavailable)
        let catalog = try await service.fetchCatalog()

        #expect(catalog.entitlementsUnavailable)
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement?.status == .active)
    }

    @Test("Device-only scenario serves the catalog with no entitlements")
    func deviceOnlyScenario() async throws {
        let service = makeService(scenario: .deviceOnly)
        let catalog = try await service.fetchCatalog()

        #expect(catalog.abilities.count == 6)
        #expect(catalog.abilities.allSatisfy { $0.entitlement == nil })
    }

    @Test("OAuth connect goes pending with a redirect, then completes to active")
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
        #expect(catalog.abilities.first { $0.id == "googlecalendar" }?.entitlement == nil)

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
