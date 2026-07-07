@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards that the `profileAvatarLatest` view returns exactly one deterministic
/// row per inbox, even when several slots share the same `updatedAt` (which
/// `ProfileBackfill` produces by writing every legacy avatar at the epoch floor).
@Suite("profileAvatarLatest view determinism")
struct ProfileAvatarLatestViewTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    private func avatar(_ conversationId: String, url: String, updatedAt: Date) -> DBProfileAvatar {
        DBProfileAvatar(
            inboxId: "me", conversationId: conversationId, url: url, salt: salt, nonce: nonce,
            encryptionKey: key, profileSource: .contact, updatedAt: updatedAt
        )
    }

    @Test("one deterministic row per inbox when updatedAt ties")
    func deterministicOnTies() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1", "c2"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try avatar("c1", url: "u1", updatedAt: time).save(db)
            try avatar("c2", url: "u2", updatedAt: time).save(db)
        }

        // Repeated reads must return the same single row (conversationId DESC
        // tie-breaker -> "c2").
        for _ in 0..<3 {
            let rows = try await queue.read { db in
                try DBProfileAvatarLatest
                    .filter(DBProfileAvatarLatest.Columns.inboxId == "me")
                    .fetchAll(db)
            }
            #expect(rows.count == 1)
            #expect(rows.first?.conversationId == "c2")
            #expect(rows.first?.url == "u2")
        }
    }

    @Test("newest updatedAt wins regardless of conversationId")
    func newestWins() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1", "c2"])
        try await queue.write { db in
            try avatar("c2", url: "old", updatedAt: Date(timeIntervalSince1970: 1)).save(db)
            try avatar("c1", url: "new", updatedAt: Date(timeIntervalSince1970: 5)).save(db)
        }

        let row = try await queue.read { db in
            try DBProfileAvatarLatest
                .filter(DBProfileAvatarLatest.Columns.inboxId == "me")
                .fetchOne(db)
        }
        #expect(row?.url == "new")
        #expect(row?.conversationId == "c1")
    }
}
