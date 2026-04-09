@testable import ConvosCore
import Foundation
import Testing

/// Tests for DBMessage.Update Codable conformance.
///
/// Verifies the backward-compatible decoding of the `isReconnection` field
/// added for post-restore "Reconnected" message rendering. Existing messages
/// in the database were stored before the field existed and decoders must
/// default to `false` instead of throwing keyNotFound.
@Suite("DBMessage.Update decoding")
struct DBMessageUpdateDecodingTests {
    @Test("Decode legacy JSON without isReconnection defaults to false")
    func testLegacyDecodeDefaultsToFalse() throws {
        let legacyJSON = """
        {
          "initiatedByInboxId": "inbox-1",
          "addedInboxIds": ["inbox-2"],
          "removedInboxIds": [],
          "metadataChanges": []
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let update = try JSONDecoder().decode(DBMessage.Update.self, from: data)

        #expect(update.initiatedByInboxId == "inbox-1")
        #expect(update.addedInboxIds == ["inbox-2"])
        #expect(update.removedInboxIds.isEmpty)
        #expect(update.metadataChanges.isEmpty)
        #expect(update.expiresAt == nil)
        #expect(update.isReconnection == false)
    }

    @Test("Decode JSON with isReconnection=true preserves value")
    func testDecodeWithReconnectionTrue() throws {
        let json = """
        {
          "initiatedByInboxId": "inbox-1",
          "addedInboxIds": ["inbox-2"],
          "removedInboxIds": [],
          "metadataChanges": [],
          "isReconnection": true
        }
        """
        let data = try #require(json.data(using: .utf8))
        let update = try JSONDecoder().decode(DBMessage.Update.self, from: data)

        #expect(update.isReconnection == true)
    }

    @Test("Encode and round-trip preserves isReconnection")
    func testEncodeRoundTrip() throws {
        let original = DBMessage.Update(
            initiatedByInboxId: "inbox-1",
            addedInboxIds: ["inbox-2"],
            removedInboxIds: [],
            metadataChanges: [],
            expiresAt: nil,
            isReconnection: true
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DBMessage.Update.self, from: encoded)

        #expect(decoded.initiatedByInboxId == original.initiatedByInboxId)
        #expect(decoded.addedInboxIds == original.addedInboxIds)
        #expect(decoded.isReconnection == true)
    }

    @Test("Memberwise init defaults isReconnection to false")
    func testMemberwiseInitDefault() {
        let update = DBMessage.Update(
            initiatedByInboxId: "inbox-1",
            addedInboxIds: [],
            removedInboxIds: [],
            metadataChanges: [],
            expiresAt: nil
        )

        #expect(update.isReconnection == false)
    }
}
