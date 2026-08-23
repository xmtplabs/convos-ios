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

    @Test("Initiation rejects omitted required-nullable auth fields")
    func initiationRejectsOmittedAuthFields() {
        #expect(throws: (any Error).self) {
            _ = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
            { "status": "pending_auth", "connectionRequestId": "creq_123" }
            """)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
            { "status": "active", "redirectUrl": null }
            """)
        }
    }

    @Test("Initiation rejects statuses outside the contract's two values")
    func initiationRejectsOtherStatuses() {
        for status in ["expired", "needs_reauth", "revoked", "something_new"] {
            #expect(throws: (any Error).self) {
                _ = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
                { "status": "\(status)", "redirectUrl": null, "connectionRequestId": null }
                """)
            }
        }
    }

    @Test("Initiation rejects a pending_auth with nothing to authorize")
    func initiationRejectsIncoherentShapes() {
        #expect(throws: (any Error).self) {
            _ = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
            { "status": "pending_auth", "redirectUrl": null, "connectionRequestId": null }
            """)
        }
        #expect(throws: AbilitiesAPI.WireValidationError.incoherentEntitlementState) {
            _ = try AbilitiesAPI.EntitlementInitiationResponse(status: .expired)
        }
        #expect(throws: AbilitiesAPI.WireValidationError.incoherentEntitlementState) {
            _ = try AbilitiesAPI.EntitlementInitiationResponse(status: .pendingAuth)
        }
    }

    /// `active` has two legal shapes, both from the same endpoint: the
    /// auth-less short-circuit carries null auth fields, and an OAuth
    /// ability whose row is already active carries the fields of the request
    /// the endpoint minted before it consulted the row. Rejecting the second
    /// makes the client throw on a connection that works.
    @Test("Initiation accepts an active carrying the auth fields of an unused request")
    func initiationAcceptsActiveWithAuthFields() throws {
        let decoded = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
        { "status": "active", "redirectUrl": "https://x.example", "connectionRequestId": "creq_1" }
        """)
        #expect(decoded.status == .active)
        #expect(decoded.redirectUrl == "https://x.example")
        #expect(decoded.connectionRequestId == "creq_1")

        let authLess = try decode(AbilitiesAPI.EntitlementInitiationResponse.self, """
        { "status": "active", "redirectUrl": null, "connectionRequestId": null }
        """)
        #expect(authLess.redirectUrl == nil)
    }

    @Test("Complete response rejects every non-active status (const)")
    func completeRejectsNonActive() {
        for status in ["pending_auth", "expired", "needs_reauth", "revoked", "done"] {
            #expect(throws: (any Error).self) {
                _ = try decode(AbilitiesAPI.EntitlementCompleteResponse.self, """
                { "status": "\(status)" }
                """)
            }
        }
    }

    @Test("Conversation entries reject an omitted required-nullable extender key")
    func entryRejectsOmittedExtender() {
        #expect(throws: (any Error).self) {
            _ = try decode(AbilitiesAPI.ConversationAbilitiesResponse.self, """
            {
              "abilities": [
                {
                  "abilityId": "x",
                  "conversationId": "c",
                  "agentInboxId": "a",
                  "bundleIds": [],
                  "extendedByMe": true,
                  "status": "active",
                  "createdAt": "2026-07-26T09:00:00Z",
                  "updatedAt": "2026-07-26T09:00:00Z"
                }
              ]
            }
            """)
        }
    }

    @Test("Strict responses round-trip with explicit nulls preserved")
    func strictRoundTrip() throws {
        let initiation = try AbilitiesAPI.EntitlementInitiationResponse(status: .active)
        let data = try JSONEncoder().encode(initiation)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.contains("redirectUrl"))
        #expect(object.keys.contains("connectionRequestId"))
        #expect(object["redirectUrl"] is NSNull)
        let decoded = try AbilitiesAPI.wireResponseDecoder().decode(AbilitiesAPI.EntitlementInitiationResponse.self, from: data)
        #expect(decoded == initiation)
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

@Suite("Abilities endpoint URL construction")
struct AbilitiesURLConstructionTests {
    @Test("Path components encode reserved characters with the unreserved-only set")
    func strictComponentEncoding() {
        #expect(ConvosAPIClient.strictPathComponentEncoded("plain-id_1.2~x") == "plain-id_1.2~x")
        #expect(ConvosAPIClient.strictPathComponentEncoded("a/b") == "a%2Fb")
        #expect(ConvosAPIClient.strictPathComponentEncoded("50%off") == "50%25off")
        #expect(ConvosAPIClient.strictPathComponentEncoded("q?x=1") == "q%3Fx%3D1")
        #expect(ConvosAPIClient.strictPathComponentEncoded("frag#ment") == "frag%23ment")
        #expect(ConvosAPIClient.strictPathComponentEncoded("émoji✨") == "%C3%A9moji%E2%9C%A8")
    }

    @Test("Opaque ids stay one path segment, never double-encoded")
    func urlBuildingSingleEncoding() throws {
        let baseURL = try #require(URL(string: "https://api.example.com"))
        let url = try ConvosAPIClient.endpointURL(
            baseURL: baseURL,
            pathSegments: ["v2", "conversations", "ab/c%d e?f#g", "abilities", "toolkit"],
            queryParameters: nil
        )
        #expect(url.absoluteString == "https://api.example.com/v2/conversations/ab%2Fc%25d%20e%3Ff%23g/abilities/toolkit")
    }

    @Test("A base URL carrying a path keeps it, and query items attach")
    func urlBuildingWithBasePathAndQuery() throws {
        let baseURL = try #require(URL(string: "https://api.example.com/api/"))
        let url = try ConvosAPIClient.endpointURL(
            baseURL: baseURL,
            pathSegments: ["v2", "abilities", "spotify", "entitlement"],
            queryParameters: ["agentInboxId": "agent-1"]
        )
        #expect(url.absoluteString == "https://api.example.com/api/v2/abilities/spotify/entitlement?agentInboxId=agent-1")
    }
}
