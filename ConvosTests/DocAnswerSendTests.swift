@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class DocAnswerSendTests: XCTestCase {
    func testItemObservedOutsideDmSendsAnswerToAgentDm() async throws {
        let sent = expectation(description: "answer sent")
        var sends: [(conversationId: String, text: String, clientMessageId: String)] = []
        let dmConversationId = "agent-dm-conversation-b"
        let target = DocAnswerSendTarget(conversationId: dmConversationId) { conversationId, text, clientMessageId in
            sends.append((conversationId, text, clientMessageId))
            sent.fulfill()
        }
        let viewModel = makeViewModel(answerSendTarget: target)
        let item = try ingestItem(in: viewModel, docId: "origin-conversation-a")
        XCTAssertEqual(item.docId, "origin-conversation-a")

        viewModel.sendAnswer(.choice("Yes, bind it"), for: item)

        await fulfillment(of: [sent], timeout: 1)
        XCTAssertEqual(sends.map(\.conversationId), [dmConversationId])
        let sentText = try XCTUnwrap(sends.first?.text)
        let payload = try XCTUnwrap(sentText.dropFirst(DocAnswerMessage.prefix.count).data(using: .utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
        XCTAssertEqual(envelope, ["id": item.id, "choice": "Yes, bind it"])
        XCTAssertEqual(sends.first?.clientMessageId.isEmpty, false)
    }

    func testDeliveryTimeoutRestoresItemWithFailureState() async throws {
        let target = DocAnswerSendTarget(conversationId: "agent-dm-conversation-b") { _, _, _ in }
        let viewModel = makeViewModel(
            answerSendTarget: target,
            answerDeliveryPolicy: .init(
                awaitingDelay: .zero,
                deadline: .milliseconds(200)
            )
        )
        let item = try ingestItem(in: viewModel, docId: "origin-conversation-a")

        viewModel.sendAnswer(.choice("Yes, bind it"), for: item)

        let didHide = await waitUntil { viewModel.visiblePendingItems.isEmpty }
        XCTAssertTrue(didHide)
        let didRestore = await waitUntil {
            viewModel.sendState(for: item) == .failed(answer: .choice("Yes, bind it"))
        }
        XCTAssertTrue(didRestore)
        XCTAssertEqual(viewModel.visiblePendingItems.map(\.id), [item.id])
    }

    private func makeViewModel(
        answerSendTarget: DocAnswerSendTarget,
        answerDeliveryPolicy: DocAnswerDeliveryPolicy = .live
    ) -> DocExperienceViewModel {
        let suiteName = "DocAnswerSendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults,
            answerSendTarget: answerSendTarget,
            answerDeliveryPolicy: answerDeliveryPolicy
        )
    }

    private func ingestItem(
        in viewModel: DocExperienceViewModel,
        docId: String
    ) throws -> DocWaitingItem {
        let sender = ConversationMember(
            profile: .mock(inboxId: "doc-agent", name: "Doc"),
            role: .member,
            isCurrentUser: false,
            isAgent: true
        )
        let text = #"⟦doc⟧{"v":1,"t":"item","item":{"id":"question","register":"waiting","kind":"question","headline":"Bind this doc?","context":"Doc needs a decision.","chips":["Yes, bind it"],"docId":"\#(docId)","createdAt":1787600000}}"#
        let message = AnyMessage.message(
            Message(
                id: "item-message",
                sender: sender,
                source: .incoming,
                status: .published,
                content: .text(text),
                date: Date(timeIntervalSince1970: 1_787_600_000),
                reactions: []
            ),
            .existing
        )
        viewModel.ingestAggregatedMessages([message], agentInboxId: sender.profile.inboxId)
        return try XCTUnwrap(viewModel.pendingItems.first)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
