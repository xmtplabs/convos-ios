@testable import ConvosCore
import Foundation
import Testing

@Suite("CloudConnectionsMetadataPayload Tests")
struct ConnectionsMetadataPayloadTests {
    private func entry(
        id: String = "grant_conn_123",
        senderId: String = "sender_abc",
        service: String = "google_calendar",
        provider: String = "composio",
        scope: String = "conversation",
        composioEntityId: String = "entity_device",
        composioConnectionId: String = "ca_abc",
        grantedAt: String = "2026-04-21T15:00:00Z"
    ) -> CloudConnectionGrantEntry {
        CloudConnectionGrantEntry(
            id: id,
            senderId: senderId,
            service: service,
            provider: provider,
            scope: scope,
            composioEntityId: composioEntityId,
            composioConnectionId: composioConnectionId,
            grantedAt: grantedAt
        )
    }

    @Test("Round-trips an empty payload")
    func roundTripEmpty() throws {
        let payload = CloudConnectionsMetadataPayload()
        #expect(payload.isEmpty)

        let json = try payload.toJsonString()
        let decoded = try CloudConnectionsMetadataPayload.fromJsonString(json)
        #expect(decoded.isEmpty)
        #expect(decoded.version == 1)
    }

    @Test("Round-trips a single grant preserving all fields")
    func roundTripSingleGrant() throws {
        let original = CloudConnectionsMetadataPayload(grants: [entry()])

        let json = try original.toJsonString()
        let decoded = try CloudConnectionsMetadataPayload.fromJsonString(json)

        #expect(decoded.version == 1)
        #expect(decoded.grants.count == 1)
        #expect(decoded.grants.first == entry())
    }

    @Test("Serialises keys in sorted order for deterministic output")
    func sortedKeys() throws {
        let payload = CloudConnectionsMetadataPayload(grants: [entry()])
        let json = try payload.toJsonString()

        // The version field comes after grants alphabetically.
        let grantsIndex = try #require(json.range(of: "\"grants\""))
        let versionIndex = try #require(json.range(of: "\"version\""))
        #expect(grantsIndex.lowerBound < versionIndex.lowerBound)

        // Within a grant entry, composioConnectionId should precede service.
        let composioIdx = try #require(json.range(of: "\"composioConnectionId\""))
        let serviceIdx = try #require(json.range(of: "\"service\""))
        #expect(composioIdx.lowerBound < serviceIdx.lowerBound)
    }

    @Test("Decodes agent-facing shape verbatim")
    func decodesAgentFacingShape() throws {
        // Matches the exact JSON shape the runtime's connections.mjs writes.
        let json = """
        {
          "version": 1,
          "grants": [
            {
              "id": "grant_ca_foo_conv1",
              "senderId": "19af6d15",
              "service": "google_calendar",
              "provider": "composio",
              "scope": "conversation",
              "composioEntityId": "B8813E83",
              "composioConnectionId": "ca_foo",
              "grantedAt": "2026-04-21T15:33:01Z"
            }
          ]
        }
        """

        let decoded = try CloudConnectionsMetadataPayload.fromJsonString(json)
        #expect(decoded.version == 1)
        #expect(decoded.grants.count == 1)
        let grant = try #require(decoded.grants.first)
        #expect(grant.id == "grant_ca_foo_conv1")
        #expect(grant.senderId == "19af6d15")
        #expect(grant.service == "google_calendar")
        #expect(grant.provider == "composio")
        #expect(grant.scope == "conversation")
        #expect(grant.composioEntityId == "B8813E83")
        #expect(grant.composioConnectionId == "ca_foo")
        #expect(grant.grantedAt == "2026-04-21T15:33:01Z")
    }

    @Test("Malformed JSON throws")
    func malformedJsonThrows() {
        #expect(throws: (any Error).self) {
            try CloudConnectionsMetadataPayload.fromJsonString("not json")
        }
    }

    @Test("Preserves multiple grants in order")
    func multipleGrants() throws {
        let a = entry(id: "grant_a", service: "google_calendar")
        let b = entry(id: "grant_b", service: "google_drive")
        let payload = CloudConnectionsMetadataPayload(grants: [a, b])

        let decoded = try CloudConnectionsMetadataPayload.fromJsonString(payload.toJsonString())
        #expect(decoded.grants == [a, b])
    }
}
