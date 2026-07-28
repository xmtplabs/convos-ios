@testable import ConvosCore
import Foundation
import Testing

@Suite("AbilitiesAPI endpoint wire contract")
struct AbilitiesEndpointsContractTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let data = try #require(json.data(using: .utf8))
        return try AbilitiesAPI.wireResponseDecoder().decode(T.self, from: data)
    }

    // MARK: - Entitlement initiation

    @Test("OAuth initiation decodes pending_auth with both auth fields")
    func initiationPendingAuth() throws {
        let response = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
        {
          "status": "pending_auth",
          "redirectUrl": "https://composio.example/consent?x=1",
          "connectionRequestId": "creq_123"
        }
        """)
        #expect(response.status == .pendingAuth)
        #expect(response.redirectUrl == "https://composio.example/consent?x=1")
        #expect(response.connectionRequestId == "creq_123")
    }

    @Test("Auth-less initiation decodes active with null auth fields")
    func initiationActiveNulls() throws {
        let response = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
        { "status": "active", "redirectUrl": null, "connectionRequestId": null }
        """)
        #expect(response.status == .active)
        #expect(response.redirectUrl == nil)
        #expect(response.connectionRequestId == nil)
    }

    @Test("Complete response decodes active")
    func completeResponse() throws {
        let response = try decode(AbilitiesAPI.EntitlementCompleteResponse.self, """
        { "status": "active" }
        """)
        #expect(response.status == .active)
    }

    // MARK: - Conversation abilities

    @Test("Conversation entries decode, including null extender and fractional-second dates")
    func conversationEntries() throws {
        let response = try decode(AbilitiesAPI.ConversationAbilitiesResponse.self, """
        {
          "abilities": [
            {
              "abilityId": "googlecalendar",
              "conversationId": "conv-1",
              "agentInboxId": "agent-1",
              "bundleIds": ["calendar.events"],
              "extendedByInboxId": "member-1",
              "extendedByMe": true,
              "status": "active",
              "createdAt": "2026-07-27T10:00:00.123Z",
              "updatedAt": "2026-07-27T10:00:00Z"
            },
            {
              "abilityId": "legacytoolkit",
              "conversationId": "conv-1",
              "agentInboxId": "agent-2",
              "bundleIds": [],
              "extendedByInboxId": null,
              "extendedByMe": false,
              "status": "active",
              "createdAt": "2026-07-26T09:00:00Z",
              "updatedAt": "2026-07-26T09:00:00Z"
            }
          ]
        }
        """)
        #expect(response.abilities.count == 2)
        let first = try #require(response.abilities.first)
        #expect(first.extendedByMe)
        #expect(first.extendedByInboxId == "member-1")
        #expect(first.bundleIds == ["calendar.events"])
        let second = try #require(response.abilities.last)
        #expect(!second.extendedByMe)
        #expect(second.extendedByInboxId == nil)
        #expect(second.bundleIds.isEmpty)
    }

    @Test("Unrecognized date-time strings fail decoding instead of defaulting")
    func badDateFails() throws {
        #expect(throws: (any Error).self) {
            _ = try decode(AbilitiesAPI.ConversationAbilitiesResponse.self, """
            {
              "abilities": [
                {
                  "abilityId": "x",
                  "conversationId": "c",
                  "agentInboxId": "a",
                  "bundleIds": [],
                  "extendedByInboxId": null,
                  "extendedByMe": true,
                  "status": "active",
                  "createdAt": "yesterday",
                  "updatedAt": "2026-07-26T09:00:00Z"
                }
              ]
            }
            """)
        }
    }

    // MARK: - Typed error mapping

    private func endpointError(_ json: String) -> AbilitiesAPI.EndpointError? {
        guard let data = json.data(using: .utf8) else { return nil }
        return AbilitiesAPI.EndpointError(body: data)
    }

    @Test("auth_incomplete maps with the connection status carried through")
    func authIncomplete() {
        let error = endpointError(#"{"code": "auth_incomplete", "status": "INITIALIZING"}"#)
        #expect(error == .authIncomplete(connectionStatus: "INITIALIZING"))
    }

    @Test("entitlements_unavailable maps")
    func entitlementsUnavailable() {
        #expect(endpointError(#"{"code": "entitlements_unavailable"}"#) == .entitlementsUnavailable)
    }

    @Test("needs_entitlement maps")
    func needsEntitlement() {
        #expect(endpointError(#"{"code": "needs_entitlement"}"#) == .needsEntitlement)
    }

    @Test("unknown_ability maps")
    func unknownAbility() {
        #expect(endpointError(#"{"code": "unknown_ability"}"#) == .unknownAbility)
    }

    @Test("unknown_bundle maps with the offending bundle id")
    func unknownBundle() {
        let error = endpointError(#"{"code": "unknown_bundle", "bundleId": "calendar.gone"}"#)
        #expect(error == .unknownBundle(bundleId: "calendar.gone"))
    }

    @Test("connection_not_owned and ability_mismatch map")
    func completeConflicts() {
        #expect(endpointError(#"{"code": "connection_not_owned"}"#) == .connectionNotOwned)
        #expect(endpointError(#"{"code": "ability_mismatch"}"#) == .abilityMismatch)
    }

    @Test("Unhandled codes and non-JSON bodies fall through to nil")
    func fallthroughCases() {
        #expect(endpointError(#"{"code": "invalid_request"}"#) == nil)
        #expect(endpointError(#"{"code": "not_found"}"#) == nil)
        #expect(endpointError("plain text error") == nil)
    }
}
