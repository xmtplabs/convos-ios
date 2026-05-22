import Testing
@testable import ConvosCore

struct AgentTemplateMetadataTests {
    private func makeProfile(
        memberKind: DBMemberKind?,
        metadata: ProfileMetadata?
    ) -> DBMemberProfile {
        DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Tifoso",
            avatar: nil,
            memberKind: memberKind,
            metadata: metadata
        )
    }

    @Test("A template-backed agent exposes every template metadata field")
    func templateBackedAgentExposesFields() {
        let profile = makeProfile(
            memberKind: .verifiedConvos,
            metadata: [
                "templateId": .string("200e27dc-badc-429f-a431-b01b0281ec95"),
                "publishedUrl": .string("https://agents-dev.convos.org/tifoso.pnw1o"),
                "emoji": .string("🚴"),
                "description": .string("Pro cycling expert")
            ]
        )
        #expect(profile.agentTemplateId == "200e27dc-badc-429f-a431-b01b0281ec95")
        #expect(profile.agentTemplatePublishedURL == "https://agents-dev.convos.org/tifoso.pnw1o")
        #expect(profile.agentTemplateEmoji == "🚴")
        #expect(profile.agentTemplateDescription == "Pro cycling expert")
        #expect(profile.isAgentTemplate)
    }

    @Test("A human member exposes no agent-template metadata")
    func humanMemberHasNoTemplateMetadata() {
        let profile = makeProfile(memberKind: nil, metadata: nil)
        #expect(profile.agentTemplateId == nil)
        #expect(profile.agentTemplatePublishedURL == nil)
        #expect(profile.agentTemplateEmoji == nil)
        #expect(profile.agentTemplateDescription == nil)
        #expect(profile.isAgentTemplate == false)
    }

    @Test("A legacy agent without a templateId is not a template agent")
    func legacyAgentWithoutTemplateId() {
        let profile = makeProfile(memberKind: .agent, metadata: nil)
        #expect(profile.agentTemplateId == nil)
        #expect(profile.isAgent)
        #expect(profile.isAgentTemplate == false)
    }

    @Test("templateId alone is enough for isAgentTemplate; other fields are optional")
    func partialMetadataStillResolvesTemplate() {
        let profile = makeProfile(
            memberKind: .agent,
            metadata: ["templateId": .string("abc")]
        )
        #expect(profile.agentTemplateId == "abc")
        #expect(profile.agentTemplatePublishedURL == nil)
        #expect(profile.isAgentTemplate)
    }

    @Test("A non-string metadata value does not resolve as a template field")
    func nonStringMetadataValueIgnored() {
        let profile = makeProfile(
            memberKind: .agent,
            metadata: ["templateId": .number(42)]
        )
        #expect(profile.agentTemplateId == nil)
        #expect(profile.isAgentTemplate == false)
    }
}

struct ProfileAgentTemplateMetadataTests {
    private func makeProfile(
        isAgent: Bool,
        metadata: ProfileMetadata?
    ) -> Profile {
        Profile(
            inboxId: "inbox-1",
            conversationId: "convo-1",
            name: "Tifoso",
            avatar: nil,
            isAgent: isAgent,
            metadata: metadata
        )
    }

    @Test("A template-backed agent profile exposes the template id and published URL")
    func templateBackedAgentExposesFields() {
        let profile = makeProfile(
            isAgent: true,
            metadata: [
                "templateId": .string("200e27dc-badc-429f-a431-b01b0281ec95"),
                "publishedUrl": .string("https://agents-dev.convos.org/tifoso.pnw1o")
            ]
        )
        #expect(profile.agentTemplateId == "200e27dc-badc-429f-a431-b01b0281ec95")
        #expect(profile.agentTemplatePublishedURL == "https://agents-dev.convos.org/tifoso.pnw1o")
    }

    @Test("A human profile exposes no agent-template fields")
    func humanProfileHasNoTemplateFields() {
        let profile = makeProfile(isAgent: false, metadata: nil)
        #expect(profile.agentTemplateId == nil)
        #expect(profile.agentTemplatePublishedURL == nil)
    }

    @Test("A non-string metadata value does not resolve")
    func nonStringMetadataValueIgnored() {
        let profile = makeProfile(
            isAgent: true,
            metadata: ["templateId": .number(42), "publishedUrl": .number(42)]
        )
        #expect(profile.agentTemplateId == nil)
        #expect(profile.agentTemplatePublishedURL == nil)
    }
}

struct ContactAgentTemplateTests {
    @Test("with(agentTemplateId:) overlays the id onto a copy")
    func withOverlaysTemplateId() {
        let base = Contact.mock(displayName: "Tifoso")
        #expect(base.agentTemplateId == nil)

        let overlaid = base.with(agentTemplateId: "200e27dc-badc-429f-a431-b01b0281ec95")
        #expect(overlaid.agentTemplateId == "200e27dc-badc-429f-a431-b01b0281ec95")
        #expect(overlaid.inboxId == base.inboxId)
        #expect(overlaid.displayName == base.displayName)
        #expect(overlaid.isBlocked == base.isBlocked)
    }

    @Test("with(agentTemplateId:) preserves an existing published URL")
    func withTemplateIdPreservesPublishedURL() {
        let base = Contact.mock(
            displayName: "Tifoso",
            agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o"
        )
        let overlaid = base.with(agentTemplateId: "200e27dc-badc-429f-a431-b01b0281ec95")
        #expect(overlaid.agentTemplateId == "200e27dc-badc-429f-a431-b01b0281ec95")
        #expect(overlaid.agentTemplatePublishedURL == "https://agents-dev.convos.org/tifoso.pnw1o")
    }

    @Test("with(agentTemplatePublishedURL:) overlays the URL onto a copy")
    func withOverlaysPublishedURL() {
        let base = Contact.mock(displayName: "Tifoso")
        #expect(base.agentTemplatePublishedURL == nil)

        let overlaid = base.with(
            agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o"
        )
        #expect(overlaid.agentTemplatePublishedURL == "https://agents-dev.convos.org/tifoso.pnw1o")
        #expect(overlaid.inboxId == base.inboxId)
        #expect(overlaid.displayName == base.displayName)
        #expect(overlaid.isBlocked == base.isBlocked)
    }

    @Test("with(agentTemplatePublishedURL:) can clear the URL")
    func withCanClearPublishedURL() {
        let base = Contact.mock(
            displayName: "Tifoso",
            agentTemplatePublishedURL: "https://agents-dev.convos.org/tifoso.pnw1o"
        )
        let cleared = base.with(agentTemplatePublishedURL: nil)
        #expect(cleared.agentTemplatePublishedURL == nil)
    }
}
