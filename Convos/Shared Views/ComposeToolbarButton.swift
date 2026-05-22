import SwiftUI

/// Top-trailing compose button shared between the Chats and Stuff tabs.
/// Triggers `conversationsViewModel.onStartConvo()` which sets the
/// `newConversationViewModel` binding observed by `MainTabView`'s
/// `NewConversationView` sheet. The button applies
/// `.matchedTransitionSource(id: "composer-transition-source", in: namespace)`
/// where `namespace` is the shared `MainTabView` namespace, so the
/// sheet's `.navigationTransition(.zoom(...))` morphs from this button
/// regardless of which tab the user is on.
///
/// `fallbackNamespace` is only used when the caller couldn't pass a
/// shared namespace (e.g. previews); in production every callsite
/// threads in the `MainTabView` namespace.
struct ComposeToolbarButton: View {
    let viewModel: ConversationsViewModel
    let transitionNamespace: Namespace.ID?
    let fallbackNamespace: Namespace.ID

    var body: some View {
        Button("Compose", systemImage: "square.and.pencil") {
            viewModel.onStartConvo()
        }
        .accessibilityLabel("Start a new conversation")
        .accessibilityIdentifier("compose-button")
        .matchedTransitionSource(
            id: "composer-transition-source",
            in: transitionNamespace ?? fallbackNamespace
        )
    }
}

@ViewBuilder
func composeToolbarButton(
    viewModel: ConversationsViewModel,
    transitionNamespace: Namespace.ID?,
    fallbackNamespace: Namespace.ID
) -> some View {
    ComposeToolbarButton(
        viewModel: viewModel,
        transitionNamespace: transitionNamespace,
        fallbackNamespace: fallbackNamespace
    )
}
