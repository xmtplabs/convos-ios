@testable import ConvosCore
import Foundation
import Testing

/// Backward-compatible decoding of `DBMessage.Update.isReconnection`.
///
/// Message rows written before the inactive-conversation feature shipped
/// do not have the `isReconnection` key. Decoding must default to `false`
/// rather than throw `keyNotFound`, so existing installs continue to
/// deserialize cleanly.
@Suite("DBMessage.Update decoding")
struct DBMessageUpdateDecodingTests {
    @Test("Legacy JSON without isReconnection defaults to false")
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

    @Test("JSON with isReconnection=true preserves value")
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

    @Test("Encode/decode round-trip preserves isReconnection")
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
