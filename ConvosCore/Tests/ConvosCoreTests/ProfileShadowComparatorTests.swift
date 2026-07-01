@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ProfileShadowComparator")
struct ProfileShadowComparatorTests {
    private let time = Date(timeIntervalSince1970: 1)

    private func makeContactQueue(_ rows: [(inboxId: String, displayName: String?, avatarURL: String?)]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "contact") { t in
                t.column("inboxId", .text).notNull().primaryKey()
                t.column("displayName", .text)
                t.column("avatarURL", .text)
            }
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO contact (inboxId, displayName, avatarURL) VALUES (?, ?, ?)",
                    arguments: [row.inboxId, row.displayName, row.avatarURL]
                )
            }
        }
        return queue
    }

    private func saveProfile(_ store: InMemoryProfileStore, inboxId: String, name: String?) async throws {
        try await store.saveIdentity(DBProfile(inboxId: inboxId, name: name, profileSource: .profileUpdate, updatedAt: time))
    }

    @Test("counts name and avatar-presence mismatches over the intersection only")
    func detectsMismatches() async throws {
        let profileStore = InMemoryProfileStore()
        try await saveProfile(profileStore, inboxId: "a", name: "Alice")
        try await saveProfile(profileStore, inboxId: "b", name: "Bob")
        try await saveProfile(profileStore, inboxId: "c", name: "Carol")
        // "a" has an avatar in the new store; the others do not.
        try await profileStore.saveAvatar(
            DBProfileAvatar(inboxId: "a", conversationId: "x", url: "u", profileSource: .profileUpdate, updatedAt: time)
        )

        let queue = try makeContactQueue([
            ("a", "Alice", nil),   // name match; avatar mismatch (new has one, contact doesn't)
            ("b", "Bobby", nil),   // name mismatch
            // "c" is not a contact -> not compared
            ("d", "Dave", "url"),  // not a profile -> not compared
        ])
        let comparator = ProfileShadowComparator(databaseReader: queue, profileStore: profileStore)

        let result = try await comparator.compare()

        #expect(result.comparedCount == 2)
        #expect(result.nameMismatches == 1)
        #expect(result.avatarMismatches == 1)
        #expect(result.hasDiscrepancies)
    }

    @Test("reports no discrepancies when the systems agree")
    func agreementIsClean() async throws {
        let profileStore = InMemoryProfileStore()
        try await saveProfile(profileStore, inboxId: "a", name: "Alice")
        let queue = try makeContactQueue([("a", "Alice ", nil)])

        let result = try await ProfileShadowComparator(databaseReader: queue, profileStore: profileStore).compare()

        #expect(result.comparedCount == 1)
        #expect(!result.hasDiscrepancies)
    }
}
