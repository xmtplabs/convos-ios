@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AgentShareURL parsing")
struct AgentShareURLTests {
    private let templateId: String = "11111111-1111-4111-8111-111111111111"

    @Test("parses the prod custom scheme template link")
    func parsesProdScheme() throws {
        let url = "convos://template/\(templateId)"
        let parsed = try #require(AgentShareURL.from(text: url))
        #expect(parsed.identifier == templateId)
        #expect(parsed.url == url)
    }

    @Test("parses the env-suffixed custom scheme template link")
    func parsesEnvScheme() throws {
        let parsed = try #require(AgentShareURL.from(text: "convos-dev://template/\(templateId)"))
        #expect(parsed.identifier == templateId)
    }

    @Test("parses the dev web share link (agents-dev.convos.org/a/<slug>)")
    func parsesDevWebLink() throws {
        let parsed = try #require(AgentShareURL.from(text: "https://agents-dev.convos.org/a/gandalf.felpl"))
        #expect(parsed.identifier == "gandalf.felpl")
    }

    @Test("parses the prod web share link (convos.org/a/<slug>)")
    func parsesProdWebLink() throws {
        let parsed = try #require(AgentShareURL.from(text: "https://convos.org/a/tifoso.pnw1o"))
        #expect(parsed.identifier == "tifoso.pnw1o")
    }

    @Test("rejects a non-template custom-scheme link")
    func rejectsOtherSchemeHost() {
        #expect(AgentShareURL.from(text: "convos://pair/\(templateId)") == nil)
    }

    @Test("rejects a custom-scheme template link with a non-UUID id")
    func rejectsNonUUIDTemplateId() {
        #expect(AgentShareURL.from(text: "convos://template/not-a-uuid") == nil)
    }

    @Test("rejects a non-convos.org https host even with an /a/ path")
    func rejectsUnrelatedHost() {
        #expect(AgentShareURL.from(text: "https://example.com/a/tifoso.pnw1o") == nil)
        // A look-alike suffix must not match (notconvos.org is not convos.org).
        #expect(AgentShareURL.from(text: "https://notconvos.org/a/tifoso.pnw1o") == nil)
    }

    @Test("rejects convos.org paths that aren't /a/<slug>")
    func rejectsNonAgentPaths() {
        // Bare slug / marketing pages must not be swallowed.
        #expect(AgentShareURL.from(text: "https://convos.org/about") == nil)
        #expect(AgentShareURL.from(text: "https://convos.org/tifoso.pnw1o") == nil)
        #expect(AgentShareURL.from(text: "https://dev.convos.org/i/somecode") == nil)
    }

    @Test("rejects a web link with no slug or too many path segments")
    func rejectsBadWebPath() {
        #expect(AgentShareURL.from(text: "https://agents-dev.convos.org/") == nil)
        #expect(AgentShareURL.from(text: "https://convos.org/a/slug/extra") == nil)
        #expect(AgentShareURL.from(text: "https://convos.org/a/") == nil)
    }

    @Test("rejects plain text")
    func rejectsPlainText() {
        #expect(AgentShareURL.from(text: "hey check this out") == nil)
        #expect(AgentShareURL.from(text: "") == nil)
    }

    @Test("MessageAgentShare.from mirrors AgentShareURL parsing")
    func messageAgentShareFrom() throws {
        let url = "convos://template/\(templateId)"
        let share = try #require(MessageAgentShare.from(text: url))
        #expect(share.identifier == templateId)
        #expect(share.url == url)
        #expect(MessageAgentShare.from(text: "not a link") == nil)
    }
}

@Suite("MockAgentShareResolver")
struct MockAgentShareResolverTests {
    @Test("resolves to a stable persona per identifier")
    func stablePerIdentifier() async {
        let resolver = MockAgentShareResolver()
        let first = await resolver.resolve(identifier: "abc")
        let again = await resolver.resolve(identifier: "abc")
        #expect(first != nil)
        #expect(first == again)
        #expect(first?.displayName?.isEmpty == false)
    }
}

@Suite("ApiAgentShareResolver")
struct ApiAgentShareResolverTests {
    private let templateId: String = "17555bf3-f66c-4706-8c35-f2fe6fbe0ef7"

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func gandalf(slug: String?) -> ConvosAPI.AgentTemplate {
        ConvosAPI.AgentTemplate(
            id: templateId,
            status: "published",
            publishedUrl: "https://agents-dev.convos.org/a/gandalf.felpl",
            slug: slug,
            agentName: "Gandalf",
            description: "The Grey Wizard.",
            emoji: "🧙",
            avatarUrl: nil
        )
    }

    private func resolver(api: AgentShareStubAPIClient, db: DatabaseQueue) -> ApiAgentShareResolver {
        ApiAgentShareResolver(
            apiClient: api,
            databaseReader: db,
            cacheWriter: AgentTemplateCacheWriter(databaseWriter: db)
        )
    }

    @Test("maps the template detail response into AgentShareInfo")
    func mapsTemplateResponse() async throws {
        let db = try makeDatabase()
        let api = AgentShareStubAPIClient(template: gandalf(slug: "gandalf"))
        let info = await resolver(api: api, db: db).resolve(identifier: "gandalf.felpl")
        #expect(info?.templateId == templateId)
        #expect(info?.displayName == "Gandalf")
        #expect(info?.emoji == "🧙")
        #expect(info?.descriptionText == "The Grey Wizard.")
    }

    @Test("returns nil when the fetch throws")
    func nilOnError() async throws {
        let db = try makeDatabase()
        let resolver = resolver(api: AgentShareStubAPIClient(template: nil), db: db)
        let info = await resolver.resolve(identifier: "missing.slug")
        #expect(info == nil)
    }

    @Test("caches the fetched template so a second resolve skips the network")
    func cachesAfterFetch() async throws {
        let db = try makeDatabase()
        let api = AgentShareStubAPIClient(template: gandalf(slug: "gandalf"))
        let resolver = resolver(api: api, db: db)

        let first = await resolver.resolve(identifier: templateId)
        #expect(first?.displayName == "Gandalf")
        #expect(api.fetchCount == 1)

        let second = await resolver.resolve(identifier: templateId)
        #expect(second?.displayName == "Gandalf")
        #expect(second?.descriptionText == "The Grey Wizard.")
        // Served from the DBAgentTemplate cache, not a second round-trip.
        #expect(api.fetchCount == 1)
    }

    @Test("resolves from cache by slug, not just by template id")
    func cacheHitBySlug() async throws {
        let db = try makeDatabase()
        let api = AgentShareStubAPIClient(template: gandalf(slug: "gandalf.felpl"))
        let resolver = resolver(api: api, db: db)

        // First resolve by slug populates the cache (keyed by the resolved id,
        // with the slug column stored).
        _ = await resolver.resolve(identifier: "gandalf.felpl")
        #expect(api.fetchCount == 1)

        let again = await resolver.resolve(identifier: "gandalf.felpl")
        #expect(again?.displayName == "Gandalf")
        #expect(api.fetchCount == 1)
    }

    @Test("a sparse cached row falls through to the detail fetch")
    func sparseRowFallsThrough() async throws {
        let db = try makeDatabase()
        // Seed a row with no name/description (e.g. from a publish response).
        try await db.write { database in
            try DBAgentTemplate(
                templateId: self.templateId,
                agentName: nil,
                emoji: nil,
                avatarURL: nil,
                publishedURL: "https://agents-dev.convos.org/a/gandalf.felpl",
                templateDescription: nil,
                slug: nil,
                fetchedAt: Date()
            ).save(database)
        }
        let api = AgentShareStubAPIClient(template: gandalf(slug: "gandalf"))
        let resolver = resolver(api: api, db: db)

        let info = await resolver.resolve(identifier: templateId)
        #expect(info?.displayName == "Gandalf")
        // The sparse row didn't satisfy the read, so the detail endpoint ran.
        #expect(api.fetchCount == 1)
    }
}

/// Returns a fixed template (or throws `notFound` when nil) for the
/// agent-share detail fetch, counting calls so cache hits can be asserted.
/// Every other `ConvosAPIClientProtocol` requirement is satisfied by the
/// shared `TestStubAPIClientDefaults` no-op extension.
private final class AgentShareStubAPIClient: TestStubAPIClient, @unchecked Sendable {
    private let template: ConvosAPI.AgentTemplate?
    private let fetchCountLock: NSLock = NSLock()
    private var _fetchCount: Int = 0

    var fetchCount: Int {
        fetchCountLock.withLock { _fetchCount }
    }

    init(template: ConvosAPI.AgentTemplate?) { self.template = template }

    override func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
        fetchCountLock.withLock { _fetchCount += 1 }
        guard let template else { throw APIError.notFound }
        return template
    }
}
