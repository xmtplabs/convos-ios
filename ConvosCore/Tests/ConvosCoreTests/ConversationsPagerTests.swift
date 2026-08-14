@testable import ConvosCore
import Combine
import Foundation
import GRDB
import Testing

/// Covers the windowed conversations page: pinned rows never consume the
/// LIMIT budget, the window grows on loadMore, filters run in SQL with the
/// same semantics as the view model's in-memory filters, and the by-id
/// fallback applies the list's eligibility rules.
@Suite("ConversationsPager", .serialized)
struct ConversationsPagerTests {
    private func seedConversation(
        _ db: Database,
        id: String,
        createdAt: Date,
        isPinned: Bool = false,
        pinnedOrder: Int? = nil,
        isUnread: Bool = false,
        expiresAt: Date? = nil,
        wasRemoved: Bool = false
    ) throws {
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: "me",
            kind: .group,
            consent: .allowed,
            createdAt: createdAt,
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: expiresAt,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: id,
            isPinned: isPinned,
            isUnread: isUnread,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: wasRemoved,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        try DBConversationMember(
            conversationId: id,
            inboxId: "me",
            role: .superAdmin,
            consent: .allowed,
            createdAt: createdAt,
            invitedByInboxId: nil
        ).insert(db)
    }

    private func seedBase(_ db: Database) throws {
        try DBMember(inboxId: "me").save(db, onConflict: .ignore)
        try DBInbox(inboxId: "me", clientId: "client-me", createdAt: Date()).save(db, onConflict: .ignore)
    }

    @Test("Pinned rows are unlimited and excluded from the unpinned LIMIT")
    func pinnedExcludedFromWindow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            for i in 0..<9 {
                try self.seedConversation(
                    db,
                    id: "pin-\(i)",
                    createdAt: Date(timeIntervalSince1970: 5_000 + Double(i)),
                    isPinned: true,
                    pinnedOrder: i
                )
            }
            for i in 0..<100 {
                try self.seedConversation(
                    db,
                    id: "conv-\(i)",
                    createdAt: Date(timeIntervalSince1970: 10_000 + Double(i))
                )
            }
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        let page = try pager.fetchInitialPage()

        #expect(page.pinned.count == 9)
        #expect(page.unpinned.count == 60)
        #expect(page.hasMore)
        #expect(page.hasAnyUnpinned)
        #expect(page.unpinned.allSatisfy { !$0.isPinned })
        // Newest-first ordering by createdAt when no messages exist.
        #expect(page.unpinned.first?.id == "conv-99")
    }

    @Test("loadMore grows the window until exhaustion")
    func loadMoreGrowsWindow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            for i in 0..<100 {
                try self.seedConversation(
                    db,
                    id: "conv-\(i)",
                    createdAt: Date(timeIntervalSince1970: 10_000 + Double(i))
                )
            }
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        let first = try pager.fetchInitialPage()
        #expect(first.unpinned.count == 60)
        #expect(first.hasMore)

        pager.loadMore()
        let second = try pager.fetchInitialPage()
        #expect(second.unpinned.count == 100)
        #expect(!second.hasMore)
    }

    @Test("Changing the filter resets the window to the first page")
    func filterChangeResetsWindow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            for i in 0..<80 {
                try self.seedConversation(
                    db,
                    id: "conv-\(i)",
                    createdAt: Date(timeIntervalSince1970: 10_000 + Double(i)),
                    isUnread: true
                )
            }
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        pager.loadMore()
        #expect(try pager.fetchInitialPage().unpinned.count == 80)

        pager.filter = .unread
        let filtered = try pager.fetchInitialPage()
        #expect(filtered.unpinned.count == 60, "Filter change should reset the window to one page")
        #expect(filtered.hasMore)
    }

    @Test("Unread filter matches the localState flag only")
    func unreadFilterSemantics() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            try self.seedConversation(db, id: "unread-1", createdAt: Date(timeIntervalSince1970: 10_000), isUnread: true)
            try self.seedConversation(db, id: "read-1", createdAt: Date(timeIntervalSince1970: 10_001))
            try self.seedConversation(db, id: "unread-2", createdAt: Date(timeIntervalSince1970: 10_002), isUnread: true)
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        pager.filter = .unread
        let page = try pager.fetchInitialPage()

        #expect(Set(page.unpinned.map(\.id)) == ["unread-1", "unread-2"])
        #expect(page.hasAnyUnpinned, "hasAnyUnpinned ignores the filter")
    }

    @Test("Exploding filter honors the one-year cap")
    func explodingFilterSemantics() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        let soon = Date().addingTimeInterval(3_600)
        let beyondOneYear = Date().addingTimeInterval(2 * 365 * 24 * 60 * 60)
        try await writer.write { db in
            try self.seedBase(db)
            try self.seedConversation(db, id: "exploding", createdAt: Date(timeIntervalSince1970: 10_000), expiresAt: soon)
            try self.seedConversation(db, id: "far-future", createdAt: Date(timeIntervalSince1970: 10_001), expiresAt: beyondOneYear)
            try self.seedConversation(db, id: "forever", createdAt: Date(timeIntervalSince1970: 10_002))
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        let all = try pager.fetchInitialPage()
        #expect(all.unpinned.count == 3, "All three are list-eligible under .all")

        pager.filter = .exploding
        let exploding = try pager.fetchInitialPage()
        #expect(
            exploding.unpinned.map(\.id) == ["exploding"],
            "Only the within-one-year expiry matches scheduledExplosionDate's contract"
        )
    }

    @Test("Filtered-empty window still reports hasAnyUnpinned")
    func filteredEmptyWindowKeepsHasAnyUnpinned() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            try self.seedConversation(db, id: "read-only", createdAt: Date(timeIntervalSince1970: 10_000))
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        pager.filter = .unread
        let page = try pager.fetchInitialPage()

        #expect(page.unpinned.isEmpty)
        #expect(page.hasAnyUnpinned, "Conversations exist; only the filter excludes them")
    }

    @Test("fetchConversation applies the list's eligibility filters")
    func fetchConversationByIdFilters() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            try self.seedConversation(db, id: "eligible", createdAt: Date(timeIntervalSince1970: 10_000))
            try self.seedConversation(db, id: "removed", createdAt: Date(timeIntervalSince1970: 10_001), wasRemoved: true)
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)

        #expect(try pager.fetchConversation(id: "eligible")?.id == "eligible")
        #expect(try pager.fetchConversation(id: "removed") == nil, "A removed conversation is gone from the list's perspective")
        #expect(try pager.fetchConversation(id: "missing") == nil)
    }

    @Test("Page publisher emits the grown window after loadMore")
    func pagePublisherEmitsGrownWindow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = dbManager.dbWriter
        try await writer.write { db in
            try self.seedBase(db)
            for i in 0..<70 {
                try self.seedConversation(
                    db,
                    id: "conv-\(i)",
                    createdAt: Date(timeIntervalSince1970: 10_000 + Double(i))
                )
            }
        }

        let pager = ConversationsPager(dbReader: writer, consent: [.allowed], pageSize: 60, throttleInterval: 0)
        let collector = PageCollector()
        let cancellable = pager.pagePublisher.sink { page in collector.append(page) }
        defer { cancellable.cancel() }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(collector.latest?.unpinned.count == 60)
        #expect(collector.latest?.hasMore == true)

        pager.loadMore()
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(collector.latest?.unpinned.count == 70)
        #expect(collector.latest?.hasMore == false)
    }

    @Test("An observation error never blanks the list and the pager recovers")
    func observationErrorRecovers() async throws {
        // A bare queue without the schema: every page fetch throws until
        // the migrations run, standing in for a transient read failure.
        let queue = try DatabaseQueue()
        let pager = ConversationsPager(
            dbReader: queue,
            consent: [.allowed],
            pageSize: 60,
            throttleInterval: 0,
            observationRetryDelay: 0.1
        )
        let collector = PageCollector()
        let cancellable = pager.pagePublisher.sink { page in collector.append(page) }
        defer { cancellable.cancel() }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(collector.latest == nil, "An errored observation must not substitute an empty page")

        try SharedDatabaseMigrator.shared.migrate(database: queue)
        try await queue.write { db in
            try self.seedBase(db)
            try self.seedConversation(db, id: "conv-1", createdAt: Date(timeIntervalSince1970: 10_000))
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(
            collector.latest?.unpinned.map(\.id) == ["conv-1"],
            "A scheduled retry should resubscribe once the database heals"
        )
    }
}

private final class PageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [ConversationsPage] = []
    func append(_ page: ConversationsPage) {
        lock.lock()
        pages.append(page)
        lock.unlock()
    }
    var latest: ConversationsPage? {
        lock.lock()
        defer { lock.unlock() }
        return pages.last
    }
}
