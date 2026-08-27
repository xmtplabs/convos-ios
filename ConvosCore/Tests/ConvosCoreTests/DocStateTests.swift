@testable import ConvosCore
import Foundation
import Testing

@Suite("Doc state messages")
struct DocStateTests {
    @Test("parses a version-one state snapshot")
    func parsesStateSnapshot() throws {
        let message = #"⟦doc⟧{"v":1,"t":"state","line":"+16285550999","docs":[{"id":"tahoe","name":"Tahoe Trip","url":"https://docs.google.com/document/d/1","updatedAt":1787600000,"lastChange":{"who":"Sara","what":"added flight times","at":1787599000},"binding":{"state":"live","number":"+16285550123","group":"Tahoe"},"dates":"Dec 12–15","people":7,"shared":false}],"future":true}"#

        let state = try #require(DocStateMessage.parse(message))

        #expect(state.version == 1)
        #expect(state.line == "+16285550999")
        #expect(state.docs.count == 1)
        #expect(state.docs[0].name == "Tahoe Trip")
        #expect(state.docs[0].binding.state == .live)
        #expect(state.docs[0].people == 7)
        #expect(state.docs[0].shared == false)
    }

    @Test("parses the current publisher's pending snapshot beside a verification item")
    func parsesCurrentPublisherPendingSnapshot() throws {
        let stateMessage = #"⟦doc⟧{"v":1,"t":"state","line":"+16283095734","docs":[{"id":"tahoe-trip","name":"Tahoe Trip","url":"https://docs.google.com/document/d/doc-123/edit","updatedAt":1787720400,"lastChange":{"who":"Sara","what":"created the doc","at":1787720340},"binding":{"state":"pending","number":"+16283095734","group":null},"shared":false,"dates":"Dec 12–15","people":4}]}"#
        let itemMessage = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"523e4567-e89b-42d3-a456-426614174004","register":"waiting","kind":"verify_number","headline":"Verify your phone number","context":"Send the prefilled message from your phone number.","code":"ABCD-EFGH-2345","lineNumber":"+16283095734","smsBody":"VERIFY ABCD-EFGH-2345","docId":null,"createdAt":1787720400}}"#

        let state = try #require(DocStateMessage.parse(stateMessage))
        let itemEvent = try #require(DocStateMessage.parseEvent(itemMessage))

        #expect(state.line == "+16283095734")
        #expect(state.docs.count == 1)
        let doc = try #require(state.docs.first)
        #expect(doc.binding.state == .pending)
        #expect(doc.binding.number == "+16283095734")
        guard case .item(let item) = itemEvent else {
            Issue.record("Expected the verification item published beside the snapshot")
            return
        }
        #expect(item.kind == .verifyNumber)
    }

    @Test("parses the publisher's unbound document shape")
    func parsesCurrentPublisherUnboundSnapshot() throws {
        let message = #"⟦doc⟧{"v":1,"t":"state","line":"+16283095734","docs":[{"id":"tahoe-trip","name":"Tahoe Trip","url":"https://docs.google.com/document/d/doc-123/edit","updatedAt":1787720400,"lastChange":{"who":"Sara","what":"created the doc","at":1787720340},"binding":{"state":"none","number":null,"group":null},"shared":false,"dates":"Dec 12–15","people":4}]}"#

        let state = try #require(DocStateMessage.parse(message))
        let doc = try #require(state.docs.first)

        #expect(doc.binding.state == .none)
        #expect(doc.binding.number.isEmpty)
    }

    @Test("accepts absent and null contribution lines")
    func parsesOptionalContributionLine() throws {
        let absent = try #require(DocStateMessage.parse(#"⟦doc⟧{"v":1,"t":"state","docs":[]}"#))
        let null = try #require(DocStateMessage.parse(#"⟦doc⟧{"v":1,"t":"state","line":null,"docs":[]}"#))

        #expect(absent.line == nil)
        #expect(null.line == nil)
    }

    @Test("ignores unsupported envelopes and malformed docs")
    func ignoresUnsupportedContent() throws {
        #expect(DocStateMessage.parse("⟦doc⟧{\"v\":2,\"t\":\"state\",\"docs\":[]}") == nil)
        #expect(DocStateMessage.parse("⟦doc⟧{\"v\":1,\"t\":\"event\",\"docs\":[]}") == nil)

        let mixed = #"⟦doc⟧{"v":1,"t":"state","docs":[{"id":"broken"},{"id":"valid","name":"Packing","url":"https://docs.google.com/document/d/2","updatedAt":1787600000,"lastChange":{"who":"Mina","what":"added a list","at":1787600000},"binding":{"state":"none","number":"+16285550123"}}]}"#
        let state = try #require(DocStateMessage.parse(mixed))
        #expect(state.docs.map(\.id) == ["valid"])
    }

    @Test("a wrong optional field type does not drop the snapshot")
    func toleratesWrongOptionalDocumentFieldType() throws {
        let mixed = #"⟦doc⟧{"v":1,"t":"state","docs":[{"id":"broken","name":"Broken","url":"https://docs.google.com/document/d/1","updatedAt":1787600000,"lastChange":{"who":"Mina","what":"updated it","at":1787600000},"binding":{"state":"none","number":"+16285550123"},"people":"unknown"},{"id":"valid","name":"Packing","url":"https://docs.google.com/document/d/2","updatedAt":1787600000,"lastChange":{"who":"Mina","what":"added a list","at":1787600000},"binding":{"state":"none","number":"+16285550123"}}]}"#

        let state = try #require(DocStateMessage.parse(mixed))

        #expect(state.docs.map(\.id) == ["broken", "valid"])
        #expect(state.docs[0].people == nil)
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
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"item-resolved","id":""}"#) == nil)
    }

    @Test("parses and round-trips phone verification items")
    func parsesVerifyNumberItem() throws {
        let message = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"verify-1","register":"waiting","kind":"verify_number","headline":"Verify your number","context":"Text this code from the phone you use with Doc.","code":"ABCD-2345-WXYZ","lineNumber":"+16283095734","smsBody":"VERIFY ABCD-2345-WXYZ","createdAt":1787600000}}"#
        let event = try #require(DocStateMessage.parseEvent(message))
        guard case .item(let item) = event else {
            Issue.record("Expected a verification item")
            return
        }

        #expect(item.kind == .verifyNumber)
        #expect(item.code == "ABCD-2345-WXYZ")
        #expect(item.lineNumber == "+16283095734")
        #expect(item.smsBody == "VERIFY ABCD-2345-WXYZ")
        #expect(item.chips.isEmpty)

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DocWaitingItem.self, from: encoded)
        #expect(decoded == item)
    }

    @Test("requires the complete phone verification payload")
    func rejectsIncompleteVerifyNumberItem() {
        let missingBody = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"verify-1","register":"waiting","kind":"verify_number","headline":"Verify","context":"Text the code.","code":"ABCD-2345-WXYZ","lineNumber":"+16283095734","createdAt":1}}"#
        let mismatchedBody = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"verify-2","register":"waiting","kind":"verify_number","headline":"Verify","context":"Text the code.","code":"ABCD-2345-WXYZ","lineNumber":"+16283095734","smsBody":"VERIFY WRONG-CODE-HERE","createdAt":1}}"#

        #expect(DocStateMessage.parseEvent(missingBody) == nil)
        #expect(DocStateMessage.parseEvent(mismatchedBody) == nil)
    }

    @Test("continues to drop genuinely unknown item kinds")
    func dropsUnknownWaitingItemKind() {
        let message = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"1","register":"waiting","kind":"future_kind","headline":"H","context":"C","createdAt":1}}"#
        #expect(DocStateMessage.parseEvent(message) == nil)
    }

    @Test("parses draft and ask registers defensively")
    func parsesDraftAndAskRegisters() throws {
        let draftMessage = ###"⟦doc⟧{"v":1,"t":"item","item":{"id":"draft-1","register":"draft","kind":"structure","headline":"Drafted a Decisions section","context":"Three choices are ready to add.","draft":{"text":"## Decisions\n- Stay in Tahoe","anchor":"Plan"},"docId":"tahoe","createdAt":1787600000}}"###
        let draftEvent = try #require(DocStateMessage.parseEvent(draftMessage))
        guard case .item(let draft) = draftEvent else {
            Issue.record("Expected a draft item")
            return
        }
        #expect(draft.register == .draft)
        #expect(draft.kind == .structure)
        #expect(draft.draft?.text == "## Decisions\n- Stay in Tahoe")
        #expect(draft.draft?.anchor == "Plan")

        let askMessage = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"ask-2","register":"ask","kind":"stale_check","headline":"Is this trip still active?","context":"There have been no updates this month.","chips":["Keep active","Pause","Archive"],"docId":null,"createdAt":1787600001}}"#
        let askEvent = try #require(DocStateMessage.parseEvent(askMessage))
        guard case .item(let ask) = askEvent else {
            Issue.record("Expected an ask item")
            return
        }
        #expect(ask.register == .ask)
        #expect(ask.kind == .staleCheck)
        #expect(ask.chips == ["Keep active", "Pause", "Archive"])
        #expect(ask.docId == nil)

        let missingDraft = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"draft-2","register":"draft","kind":"cleanup","headline":"Clean up","context":"Tighten the plan.","createdAt":1}}"#
        let mismatchedKind = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"ask-3","register":"ask","kind":"question","headline":"Question","context":"Context","createdAt":1}}"#
        #expect(DocStateMessage.parseEvent(missingDraft) == nil)
        #expect(DocStateMessage.parseEvent(mismatchedKind) == nil)
    }

    @Test("parses document content with a defensive changes ledger")
    func parsesDocumentContent() throws {
        let message = ##"⟦doc⟧{"v":1,"t":"doc-content","docId":"tahoe","markdown":"# Tahoe\nBring boots.","changes":[{"who":"Noah","what":"added the cabin","at":1787590000},{"who":"Sara","what":"added flight times","at":1787600000},{"who":"","what":"broken","at":1}],"updatedAt":1787600100,"future":true}"##

        let event = try #require(DocStateMessage.parseEvent(message))
        guard case .docContent(let content) = event else {
            Issue.record("Expected document content")
            return
        }

        #expect(content.docId == "tahoe")
        #expect(content.markdown == "# Tahoe\nBring boots.")
        #expect(content.changes.count == 2)
        #expect(content.changes[0].who == "Sara")
        #expect(content.changes[1].who == "Noah")
        #expect(content.updatedAt == Date(timeIntervalSince1970: 1_787_600_100))
    }

    @Test("ignores malformed document content")
    func ignoresMalformedDocumentContent() {
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"doc-content","docId":"","markdown":"Body","updatedAt":1}"#) == nil)
        #expect(DocStateMessage.parseEvent(#"⟦doc⟧{"v":1,"t":"doc-content","docId":"tahoe","updatedAt":1}"#) == nil)
    }

    @Test("encodes document content requests")
    func encodesDocumentContentRequest() throws {
        let request = try #require(DocContentRequestMessage.encode(docId: "tahoe"))
        let payload = String(request.dropFirst(DocContentRequestMessage.prefix.count))
        let data = try #require(payload.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(json == ["t": "doc-content", "docId": "tahoe"])
        #expect(DocContentRequestMessage.encode(docId: "") == nil)
    }

    @Test("encodes and hides per-document lane announcements")
    func encodesDocLaneAnnouncement() throws {
        let message = try #require(DocLaneMessage.encode(docId: "tahoe"))
        #expect(message == #"⟦lane⟧{"docId":"tahoe"}"#)
        #expect(DocLaneMessage.encode(docId: "  ") == nil)
        #expect(DocWireMessage.isHiddenText(message))
    }

    @Test("bootstrap request matches the agent contract and stays hidden")
    func bootstrapRequestMatchesContract() {
        #expect(DocBootstrapMessage.text == #"⟦req⟧{"v":1,"t":"bootstrap"}"#)
        #expect(DocWireMessage.isHiddenText(DocBootstrapMessage.text))
    }

    @Test("chooses agent or native document sharing by binding")
    func choosesDocumentSharePath() {
        let live = docStatus(binding: .live, shared: false)
        let unbound = docStatus(binding: .none, shared: false)
        let alreadyShared = docStatus(binding: .live, shared: true)
        let text = "here's a doc for us (https://docs.google.com/document/d/1)"

        #expect(DocShareAction.disposition(for: live) == .askAgent(text))
        #expect(DocShareAction.disposition(for: unbound) == .nativeShare(text))
        #expect(DocShareAction.disposition(for: alreadyShared) == .hidden)
    }

    @Test("encodes compact choice, text, and action answers")
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

        let approved = try #require(
            DocAnswerMessage.encode(
                itemId: "draft-1",
                answer: .action(.approve, edited: nil)
            )
        )
        let approvedJSON = try decodedAnswer(approved)
        #expect(approvedJSON["id"] as? String == "draft-1")
        #expect(approvedJSON["action"] as? String == "approve")
        #expect(approvedJSON["edited"] == nil)

        let edited = try #require(
            DocAnswerMessage.encode(
                itemId: "draft-2",
                answer: .action(.approve, edited: "## Decisions")
            )
        )
        let editedJSON = try decodedAnswer(edited)
        #expect(editedJSON["action"] as? String == "approve")
        #expect(editedJSON["edited"] as? String == "## Decisions")

        let discarded = try #require(
            DocAnswerMessage.encode(
                itemId: "draft-3",
                answer: .action(.discard, edited: "ignored")
            )
        )
        let discardedJSON = try decodedAnswer(discarded)
        #expect(discardedJSON["action"] as? String == "discard")
        #expect(discardedJSON["edited"] == nil)
    }

    @Test("hides every Doc-prefixed text message from transcripts")
    func hidesDataPlaneMessages() {
        #expect(!MessageContent.text("⟦doc⟧not-json").showsInMessagesList)
        #expect(!MessageContent.text("⟦ans⟧not-json").showsInMessagesList)
        #expect(!MessageContent.text("⟦req⟧not-json").showsInMessagesList)
        #expect(!MessageContent.text("⟦lane⟧not-json").showsInMessagesList)
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

        let requestRow = DBLastMessageWithSource(
            id: "doc-request",
            clientMessageId: "doc-request",
            conversationId: "agent-dm",
            senderId: "user",
            dateNs: 3,
            date: Date(timeIntervalSince1970: 3),
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "⟦req⟧not-json",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            sourceMessageText: nil
        )
        let requestPreview = requestRow.hydrateMessagePreview(
            conversationKind: .dm,
            currentInboxId: "user",
            members: []
        )
        #expect(requestPreview.text.isEmpty)
    }

    private func decodedAnswer(_ message: String) throws -> [String: Any] {
        let payload = String(message.dropFirst(DocAnswerMessage.prefix.count))
        let data = try #require(payload.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func docStatus(binding: DocBinding.State, shared: Bool) -> DocStatus {
        DocStatus(
            id: "tahoe",
            name: "Tahoe Trip",
            url: "https://docs.google.com/document/d/1",
            updatedAt: Date(timeIntervalSince1970: 1),
            lastChange: DocLastChange(
                who: "Sara",
                what: "updated the plan",
                at: Date(timeIntervalSince1970: 1)
            ),
            binding: DocBinding(state: binding, number: "+16285550123"),
            shared: shared
        )
    }
}
