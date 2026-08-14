import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

struct ConversationsViewRepresentable: UIViewControllerRepresentable {
    let pinnedConversations: [Conversation]
    let unpinnedConversations: [Conversation]
    let selectedConversationId: String?
    let isFilteredResultEmpty: Bool
    let filterEmptyMessage: String
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.memberContactOverride) private var memberContactOverride: @Sendable (String) -> Contact?

    // Callbacks
    var onSelectConversation: ((Conversation) -> Void)?
    var onConfirmedDeleteConversation: ((Conversation) -> Void)?
    var onExplodeConversation: ((Conversation) -> Void)?
    var onToggleMute: ((Conversation) -> Void)?
    var onToggleReadState: ((Conversation) -> Void)?
    var onTogglePin: ((Conversation) -> Void)?
    var onShowAllFilter: (() -> Void)?

    func makeUIViewController(context: Context) -> ConversationsViewController {
        let viewController = ConversationsViewController()
        viewController.memberContactOverride = memberContactOverride
        configureCallbacks(viewController)
        return viewController
    }

    func updateUIViewController(_ viewController: ConversationsViewController, context: Context) {
        let state = ConversationsViewController.State(
            pinnedConversations: pinnedConversations,
            unpinnedConversations: unpinnedConversations,
            selectedConversationId: selectedConversationId,
            isFilteredResultEmpty: isFilteredResultEmpty,
            filterEmptyMessage: filterEmptyMessage,
            horizontalSizeClass: horizontalSizeClass
        )
        viewController.memberContactOverride = memberContactOverride
        viewController.updateState(state)

        // Update callbacks in case they changed
        configureCallbacks(viewController)
    }

    private func configureCallbacks(_ viewController: ConversationsViewController) {
        viewController.onSelectConversation = onSelectConversation
        viewController.onConfirmedDeleteConversation = onConfirmedDeleteConversation
        viewController.onExplodeConversation = onExplodeConversation
        viewController.onToggleMute = onToggleMute
        viewController.onToggleReadState = onToggleReadState
        viewController.onTogglePin = onTogglePin
        viewController.onShowAllFilter = onShowAllFilter
    }
}
