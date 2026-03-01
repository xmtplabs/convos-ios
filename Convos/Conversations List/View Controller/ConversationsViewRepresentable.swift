import ConvosCore
import SwiftUI
import UIKit

struct ConversationsViewRepresentable: UIViewControllerRepresentable {
    let pinnedConversations: [Conversation]
    let unpinnedConversations: [Conversation]
    let selectedConversationId: String?
    let isFilteredResultEmpty: Bool
    let filterEmptyMessage: String
    let hasCreatedMoreThanOneConvo: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    // Callbacks
    var onSelectConversation: ((Conversation) -> Void)?
    var onDeleteConversation: ((Conversation) -> Void)?
    var onConfirmedDeleteConversation: ((Conversation) -> Void)?
    var onExplodeConversation: ((Conversation) -> Void)?
    var onToggleMute: ((Conversation) -> Void)?
    var onToggleReadState: ((Conversation) -> Void)?
    var onTogglePin: ((Conversation) -> Void)?
    var onStartConvo: (() -> Void)?
    var onJoinConvo: (() -> Void)?
    var onShowAllFilter: (() -> Void)?

    func makeUIViewController(context: Context) -> ConversationsViewController {
        let viewController = ConversationsViewController()
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
            hasCreatedMoreThanOneConvo: hasCreatedMoreThanOneConvo,
            horizontalSizeClass: horizontalSizeClass
        )
        viewController.updateState(state)

        // Update callbacks in case they changed
        configureCallbacks(viewController)
    }

    private func configureCallbacks(_ viewController: ConversationsViewController) {
        viewController.onSelectConversation = onSelectConversation
        viewController.onDeleteConversation = onDeleteConversation
        viewController.onConfirmedDeleteConversation = onConfirmedDeleteConversation
        viewController.onExplodeConversation = onExplodeConversation
        viewController.onToggleMute = onToggleMute
        viewController.onToggleReadState = onToggleReadState
        viewController.onTogglePin = onTogglePin
        viewController.onStartConvo = onStartConvo
        viewController.onJoinConvo = onJoinConvo
        viewController.onShowAllFilter = onShowAllFilter
    }
}
