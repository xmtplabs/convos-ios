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

    @Test("parses waiting items and resolve events")
    func parsesWaitingItemEvents() throws {
        let itemMessage = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"ask-1","register":"waiting","kind":"question","headline":"Which weekend works?","context":"Tahoe Trip needs a date.","chips":["Dec 14","Dec 21"],"docId":"tahoe","createdAt":1787600000,"future":true}}"#
        let itemEvent = try #require(DocStateMessage.parseEvent(itemMessage))
        guard case .item(let item) = itemEvent else {
            Issue.record("Expected a waiting item")
            return
        }
        #expect(item.id == "ask-1")
        #expect(item.kind == .question)
        #expect(item.chips == ["Dec 14", "Dec 21"])
        #expect(item.docId == "tahoe")

        let resolvedEvent = try #require(
            DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"item-resolved","id":"ask-1"}"#)
        )
        #expect(resolvedEvent == .itemResolved(id: "ask-1"))
    }

    @Test("ignores invalid waiting item envelopes")
    func ignoresInvalidWaitingItems() {
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"item","item":{"id":"1","register":"done","kind":"question","headline":"H","context":"C","createdAt":1}}"#) == nil)
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"item","item":{"id":"1","register":"waiting","kind":"future_kind","headline":"H","context":"C","createdAt":1}}"#) == nil)
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"item-resolved","id":""}"#) == nil)
    }

    @Test("encodes compact choice and text answers")
    func encodesAnswers() throws {
        let choice = try #require(DocAnswerMessage.encode(itemId: "ask-1", answer: .choice("Dec 14")))
        let choiceJSON = try decodedAnswer(choice)
        #expect(choiceJSON["id"] as? String == "ask-1")
        #expect(choiceJSON["choice"] as? String == "Dec 14")
        #expect(choiceJSON["text"] == nil)

        let text = try #require(DocAnswerMessage.encode(itemId: "ask-2", answer: .text("Sara")))
        let textJSON = try decodedAnswer(text)
        #expect(textJSON["id"] as? String == "ask-2")
        #expect(textJSON["text"] as? String == "Sara")
        #expect(textJSON["choice"] == nil)
    }

    @Test("hides every Doc-prefixed text message from transcripts")
    func hidesDataPlaneMessages() {
        #expect(!MessageContent.text("⟦doc⟧not-json").showsInMessagesList)
        #expect(!MessageContent.text("⟦ans⟧not-json").showsInMessagesList)
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

        let answerRow = DBLastMessageWithSource(
            id: "doc-answer",
            clientMessageId: "doc-answer",
            conversationId: "agent-dm",
            senderId: "user",
            dateNs: 2,
            date: Date(timeIntervalSince1970: 2),
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "⟦ans⟧not-json",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            sourceMessageText: nil
        )
        let answerPreview = answerRow.hydrateMessagePreview(
            conversationKind: .dm,
            currentInboxId: "user",
            members: []
        )
        #expect(answerPreview.text.isEmpty)
    }

    private func decodedAnswer(_ message: String) throws -> [String: Any] {
        let payload = String(message.dropFirst(DocAnswerMessage.prefix.count))
        let data = try #require(payload.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
