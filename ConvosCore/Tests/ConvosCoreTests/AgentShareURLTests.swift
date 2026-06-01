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

    @Test("parses the dev web share link")
    func parsesWebLink() throws {
        let parsed = try #require(AgentShareURL.from(text: "https://agents-dev.convos.org/tifoso.pnw1o"))
        #expect(parsed.identifier == "tifoso.pnw1o")
    }

    @Test("parses a bare agents.convos.org host")
    func parsesBareAgentsHost() throws {
        let parsed = try #require(AgentShareURL.from(text: "https://agents.convos.org/sous.ab12c"))
        #expect(parsed.identifier == "sous.ab12c")
    }

    @Test("rejects a non-template custom-scheme link")
    func rejectsOtherSchemeHost() {
        #expect(AgentShareURL.from(text: "convos://pair/\(templateId)") == nil)
    }

    @Test("rejects a custom-scheme template link with a non-UUID id")
    func rejectsNonUUIDTemplateId() {
        #expect(AgentShareURL.from(text: "convos://template/not-a-uuid") == nil)
    }

    @Test("rejects an unrelated https host")
    func rejectsUnrelatedHost() {
        #expect(AgentShareURL.from(text: "https://example.com/tifoso.pnw1o") == nil)
        #expect(AgentShareURL.from(text: "https://dev.convos.org/i/somecode") == nil)
    }

    @Test("rejects a web link with no slug or extra path segments")
    func rejectsBadWebPath() {
        #expect(AgentShareURL.from(text: "https://agents-dev.convos.org/") == nil)
        #expect(AgentShareURL.from(text: "https://agents-dev.convos.org/a/b") == nil)
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
