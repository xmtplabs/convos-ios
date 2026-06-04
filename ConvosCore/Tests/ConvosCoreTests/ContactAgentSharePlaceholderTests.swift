@testable import ConvosCore
import Foundation
import Testing

@Suite("Agent-share placeholder contact")
struct ContactAgentSharePlaceholderTests {
    private let templateId: String = "11111111-1111-4111-8111-111111111111"
    private let shareURL: String = "https://convos.org/a/tifoso.pnw1o"

    private var resolvedInfo: AgentShareInfo {
        AgentShareInfo(
            templateId: templateId,
            displayName: "Tifoso",
            emoji: "🚴",
            descriptionText: "Pro cycling expert.",
            avatarURL: "https://example.com/avatar.png"
        )
    }

    @Test("maps the resolved profile onto the placeholder contact")
    func mapsResolvedProfile() {
        let contact = Contact.agentSharePlaceholder(
            templateId: templateId,
            shareURL: shareURL,
            info: resolvedInfo
        )
        #expect(contact.inboxId == "agent-share:\(templateId)")
        #expect(contact.displayName == "Tifoso")
        #expect(contact.profileEmoji == "🚴")
        #expect(contact.agentDescription == "Pro cycling expert.")
        #expect(contact.avatarURL == "https://example.com/avatar.png")
        #expect(contact.agentTemplateId == templateId)
        #expect(contact.agentTemplatePublishedURL == shareURL)
        #expect(contact.isVerifiedAgent)
    }

    @Test("placeholder gating distinguishes share placeholders from suggested and saved contacts")
    func placeholderGating() {
        let sharePlaceholder = Contact.agentSharePlaceholder(
            templateId: templateId,
            shareURL: shareURL,
            info: resolvedInfo
        )
        #expect(sharePlaceholder.isAgentSharePlaceholder)
        #expect(sharePlaceholder.isUnsavedAgentPlaceholder)
        #expect(!sharePlaceholder.isSuggestedAgentPlaceholder)

        let suggested = Contact.suggestedAgent(
            SuggestedAgent(
                templateId: templateId,
                name: "Tifoso",
                description: nil,
                emoji: nil,
                avatarURL: nil
            )
        )
        #expect(suggested.isUnsavedAgentPlaceholder)
        #expect(!suggested.isAgentSharePlaceholder)

        let saved = Contact(
            inboxId: "a-real-inbox-id",
            displayName: "Pat",
            avatarURL: nil,
            addedAt: Date(),
            addedViaConversationId: nil
        )
        #expect(!saved.isUnsavedAgentPlaceholder)
    }

    @Test("a failed resolve still yields a chat-capable agent placeholder")
    func failedResolveFallback() {
        let contact = Contact.agentSharePlaceholder(
            templateId: templateId,
            shareURL: shareURL,
            info: nil
        )
        #expect(contact.agentTemplateId == templateId)
        #expect(contact.agentTemplatePublishedURL == shareURL)
        #expect(contact.isAgent)
        #expect(contact.resolvedDisplayName == "Agent")
    }
}
