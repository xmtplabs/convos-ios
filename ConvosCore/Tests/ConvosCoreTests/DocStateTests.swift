@testable import ConvosCore
import Foundation
import Testing

@Suite("Doc state messages")
struct DocStateTests {
    @Test("parses a version-one state snapshot")
    func parsesStateSnapshot() throws {
        let message = #"⟦doc⟧{"v":1,"t":"state","docs":[{"id":"tahoe","name":"Tahoe Trip","url":"https://docs.google.com/document/d/1","updatedAt":1787600000,"lastChange":{"who":"Sara","what":"added flight times","at":1787599000},"binding":{"state":"live","number":"+16285550123","group":"Tahoe"},"dates":"Dec 12–15","people":7}],"future":true}"#

        let state = try #require(DocStateMessage.parse(message))

        #expect(state.version == 1)
        #expect(state.docs.count == 1)
        #expect(state.docs[0].name == "Tahoe Trip")
        #expect(state.docs[0].binding.state == .live)
        #expect(state.docs[0].people == 7)
    }

    @Test("ignores unsupported envelopes and malformed docs")
    func ignoresUnsupportedContent() throws {
        #expect(DocStateMessage.parse("⟦doc⟧{\"v\":2,\"t\":\"state\",\"docs\":[]}") == nil)
        #expect(DocStateMessage.parse("⟦doc⟧{\"v\":1,\"t\":\"event\",\"docs\":[]}") == nil)

        let mixed = #"⟦doc⟧{"v":1,"t":"state","docs":[{"id":"broken"},{"id":"valid","name":"Packing","url":"https://docs.google.com/document/d/2","updatedAt":1787600000,"lastChange":{"who":"Mina","what":"added a list","at":1787600000},"binding":{"state":"none","number":"+16285550123"}}]}"#
        let state = try #require(DocStateMessage.parse(mixed))
        #expect(state.docs.map(\.id) == ["valid"])
    }

    @Test("hides every Doc-prefixed text message from transcripts")
    func hidesDataPlaneMessages() {
        #expect(!MessageContent.text("⟦doc⟧not-json").showsInMessagesList)
        #expect(MessageContent.text("A normal message").showsInMessagesList)
    }

    @Test("hides Doc state from conversation previews")
    func hidesDataPlaneMessagePreviews() {
        let row = DBLastMessageWithSource(
            id: "doc-state",
            clientMessageId: "doc-state",
            conversationId: "agent-dm",
            senderId: "agent",
            dateNs: 1,
            date: Date(timeIntervalSince1970: 1),
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "⟦doc⟧not-json",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            sourceMessageText: nil
        )

        let preview = row.hydrateMessagePreview(
            conversationKind: .dm,
            currentInboxId: "user",
            members: []
        )

        #expect(preview.text.isEmpty)
    }
}
