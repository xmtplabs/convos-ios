@testable import ConvosCore
import Foundation
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
    @Test("maps the template detail response into AgentShareInfo")
    func mapsTemplateResponse() async {
        let api = AgentShareStubAPIClient(
            template: ConvosAPI.AgentTemplate(
                id: "17555bf3-f66c-4706-8c35-f2fe6fbe0ef7",
                status: "published",
                publishedUrl: "https://agents-dev.convos.org/a/gandalf.felpl",
                slug: "gandalf",
                agentName: "Gandalf",
                description: "The Grey Wizard.",
                emoji: "🧙",
                avatarUrl: nil
            )
        )
        let resolver = ApiAgentShareResolver(apiClient: api)
        let info = await resolver.resolve(identifier: "gandalf.felpl")
        #expect(info?.templateId == "17555bf3-f66c-4706-8c35-f2fe6fbe0ef7")
        #expect(info?.displayName == "Gandalf")
        #expect(info?.emoji == "🧙")
        #expect(info?.descriptionText == "The Grey Wizard.")
    }

    @Test("returns nil when the fetch throws")
    func nilOnError() async {
        let resolver = ApiAgentShareResolver(apiClient: AgentShareStubAPIClient(template: nil))
        let info = await resolver.resolve(identifier: "missing.slug")
        #expect(info == nil)
    }
}

/// Returns a fixed template (or throws `notFound` when nil) for the
/// agent-share detail fetch. Every other `ConvosAPIClientProtocol` requirement
/// is satisfied by the shared `TestStubAPIClientDefaults` no-op extension.
private final class AgentShareStubAPIClient: TestStubAPIClient, @unchecked Sendable {
    private let template: ConvosAPI.AgentTemplate?
    init(template: ConvosAPI.AgentTemplate?) { self.template = template }

    override func getAgentTemplate(idOrUrlSlug: String) async throws -> ConvosAPI.AgentTemplate {
        guard let template else { throw APIError.notFound }
        return template
    }
}
