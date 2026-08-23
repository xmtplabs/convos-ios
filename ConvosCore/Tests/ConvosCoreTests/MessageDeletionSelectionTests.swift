#if canImport(UIKit)
@testable import ConvosComposer
@testable import ConvosCore
import Foundation
import Testing

@MainActor
@Suite("Message deletion selection")
struct MessageDeletionSelectionTests {
    @Test("selection starts, toggles multiple messages, and cancels")
    func selectionLifecycle() {
        let first = makeMessage(id: "first", isCurrentUser: true)
        let second = makeMessage(id: "second", isCurrentUser: false)
        let state = MessageContextMenuState()

        state.beginMessageSelection(with: first)
        #expect(state.isSelectingMessages)
        #expect(state.isMessageSelected(first))

        state.toggleMessageSelection(second)
        #expect(state.selectedMessages.count == 2)
        #expect(state.isMessageSelected(second))

        state.toggleMessageSelection(first)
        #expect(state.selectedMessages == [second])

        state.cancelMessageSelection()
        #expect(!state.isSelectingMessages)
        #expect(state.selectedMessages.isEmpty)
    }

    @Test("delete for everyone requires published messages authored by the user")
    func deleteForEveryoneEligibility() {
        let mine = makeMessage(id: "mine", isCurrentUser: true)
        let incoming = makeMessage(id: "incoming", isCurrentUser: false)
        let unpublished = makeMessage(id: "pending", isCurrentUser: true, status: .unpublished)
        let state = MessageContextMenuState()

        state.beginMessageSelection(with: mine)
        #expect(state.canDeleteSelectionForEveryone)

        state.toggleMessageSelection(incoming)
        #expect(!state.canDeleteSelectionForEveryone)

        state.beginMessageSelection(with: unpublished)
        #expect(!state.canDeleteSelectionForEveryone)
    }

    private func makeMessage(
        id: String,
        isCurrentUser: Bool,
        status: MessageStatus = .published
    ) -> AnyMessage {
        let sender = ConversationMember.mock(isCurrentUser: isCurrentUser)
        return .message(
            Message(
                id: "local-\(id)",
                xmtpId: status == .published ? "aabb\(id.utf8.count)" : nil,
                sender: sender,
                source: isCurrentUser ? .outgoing : .incoming,
                status: status,
                content: .text(id),
                date: Date(),
                reactions: []
            ),
            .existing
        )
    }
}
#endif
