@testable import ConvosCore
import ConvosConnections
import Foundation
import GRDB
import Testing

@Suite("GRDBCapabilityResolver")
struct GRDBCapabilityResolverTests {
    private let strava: ProviderID = ProviderID(rawValue: "composio.strava")
    private let fitbit: ProviderID = ProviderID(rawValue: "composio.fitbit")
    private let appleCalendar: ProviderID = ProviderID(rawValue: "device.calendar")

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(configuration: {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return config
        }())
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        // Seed a conversation row so the FK on capabilityResolution.conversationId can be
        // satisfied by inserts in the tests below.
        try dbQueue.write { db in
            for id in ["conv-1", "conv-2"] {
                try db.execute(
                    sql: """
                        INSERT INTO conversation
                            (id, clientConversationId, inviteTag, creatorId, kind, consent, createdAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [id, id, "tag-\(id)", "inbox-\(id)", "group", "allowed", Date()]
                )
            }
        }
        return dbQueue
    }

    private func makeResolver(_ db: DatabaseQueue) -> GRDBCapabilityResolver {
        GRDBCapabilityResolver(
            database: db,
            registry: InMemoryCapabilityProviderRegistry()
        )
    }

    @Test("empty resolution by default")
    func emptyByDefault() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        let result = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(result.isEmpty)
    }

    @Test("set then read round-trips a single-provider resolution")
    func singleProviderRoundTrip() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1"
        )
        let result = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(result == [appleCalendar])
    }

    @Test("set then read round-trips a federated resolution")
    func federatedRoundTrip() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        try await resolver.setResolution(
            [strava, fitbit],
            subject: .fitness,
            capability: .read,
            conversationId: "conv-1"
        )
        let result = await resolver.resolution(subject: .fitness, capability: .read, conversationId: "conv-1")
        #expect(result == [strava, fitbit])
    }

    @Test("setResolution validates federation rules at the persistence boundary")
    func validatesOnSet() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        await #expect(throws: CapabilityResolutionError.self) {
            try await resolver.setResolution(
                [appleCalendar, ProviderID(rawValue: "composio.google_calendar")],
                subject: .calendar,
                capability: .read,
                conversationId: "conv-1"
            )
        }
        // And the row was never persisted.
        let result = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(result.isEmpty)
    }

    @Test("setResolution updates an existing row in place (createdAt preserved)")
    func updatePreservesCreatedAt() async throws {
        let db = try makeDatabase()
        // Round to whole seconds because GRDB's `.datetime` column persists with sub-
        // second precision that doesn't always survive the round-trip.
        let baseSeconds = floor(Date().timeIntervalSince1970)
        let now = Date(timeIntervalSince1970: baseSeconds)
        let later = Date(timeIntervalSince1970: baseSeconds + 60)
        let clock = TestClock(times: [now, later])
        let resolver = GRDBCapabilityResolver(
            database: db,
            registry: InMemoryCapabilityProviderRegistry(),
            now: clock.tick
        )

        try await resolver.setResolution(
            [strava],
            subject: .fitness,
            capability: .read,
            conversationId: "conv-1"
        )
        try await resolver.setResolution(
            [strava, fitbit],
            subject: .fitness,
            capability: .read,
            conversationId: "conv-1"
        )

        let row = try await db.read { db in
            try DBCapabilityResolution.fetchOne(db)
        }
        let unwrapped = try #require(row)
        #expect(
            abs(unwrapped.createdAt.timeIntervalSince(now)) < 1,
            "createdAt should be preserved on update"
        )
        #expect(
            abs(unwrapped.updatedAt.timeIntervalSince(later)) < 1,
            "updatedAt should advance on update"
        )
        #expect(unwrapped.updatedAt > unwrapped.createdAt, "updatedAt is strictly after createdAt")
    }

    @Test("clearResolution removes only the targeted verb")
    func clearOneVerb() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .read, conversationId: "conv-1")
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .writeCreate, conversationId: "conv-1")

        try await resolver.clearResolution(subject: .calendar, capability: .read, conversationId: "conv-1")

        let read = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        let write = await resolver.resolution(subject: .calendar, capability: .writeCreate, conversationId: "conv-1")
        #expect(read.isEmpty)
        #expect(write == [appleCalendar])
    }

    @Test("clearAllResolutions scoped to one (subject, conversation)")
    func clearAllScoped() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .read, conversationId: "conv-1")
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .writeCreate, conversationId: "conv-1")
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .read, conversationId: "conv-2")

        try await resolver.clearAllResolutions(subject: .calendar, conversationId: "conv-1")

        let conv1Read = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        let conv1Write = await resolver.resolution(subject: .calendar, capability: .writeCreate, conversationId: "conv-1")
        let conv2Read = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-2")
        #expect(conv1Read.isEmpty)
        #expect(conv1Write.isEmpty)
        #expect(conv2Read == [appleCalendar], "other conversation untouched")
    }

    @Test("removeProviderFromAllResolutions shrinks federated sets and clears singletons")
    func removeProvider() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        try await resolver.setResolution([strava, fitbit], subject: .fitness, capability: .read, conversationId: "conv-1")
        try await resolver.setResolution([strava], subject: .fitness, capability: .writeCreate, conversationId: "conv-1")
        try await resolver.setResolution([appleCalendar], subject: .calendar, capability: .read, conversationId: "conv-1")

        try await resolver.removeProviderFromAllResolutions(strava)

        let read = await resolver.resolution(subject: .fitness, capability: .read, conversationId: "conv-1")
        let write = await resolver.resolution(subject: .fitness, capability: .writeCreate, conversationId: "conv-1")
        let calendar = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(read == [fitbit], "federated set should shrink to remaining providers")
        #expect(write.isEmpty, "singleton resolution referencing removed provider should be cleared")
        #expect(calendar == [appleCalendar], "unrelated row untouched")
    }

    @Test("conversation deletion cascades to capability resolutions")
    func cascadeOnConversationDelete() async throws {
        let db = try makeDatabase()
        let resolver = makeResolver(db)
        try await resolver.setResolution(
            [appleCalendar],
            subject: .calendar,
            capability: .read,
            conversationId: "conv-1"
        )

        try await db.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: ["conv-1"])
        }

        let result = await resolver.resolution(subject: .calendar, capability: .read, conversationId: "conv-1")
        #expect(result.isEmpty)
    }
}

private final class TestClock: @unchecked Sendable {
    private var times: [Date]
    private let lock: NSLock = NSLock()

    init(times: [Date]) {
        self.times = times
    }

    func tick() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if times.isEmpty {
            return Date()
        }
        return times.removeFirst()
    }
}
