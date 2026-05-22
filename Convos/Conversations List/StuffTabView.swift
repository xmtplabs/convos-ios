import SwiftUI

/// Placeholder for the cross-conversation "Stuff" tab. Today this tab will
/// eventually mirror what `StuffListView` renders inside a single
/// conversation, but aggregated across every conversation the user is in.
/// Until that aggregation UI is designed we ship a centered text stand-in
/// so the tab bar shell can ship without blocking on the real screen.
///
/// Mirrors the Chats tab by surfacing the app-info pill at the top-leading
/// edge and a compose button at top-trailing. Both share the namespace
/// passed in via `appIndicatorContext`, so taps zoom into the shared
/// sheets owned by `MainTabView`. Positioning uses a ZStack overlay
/// (instead of a `.toolbar` ToolbarItem for the pill) so the visual
/// alignment with `ConversationPresenter`'s pill in the Chats tab is
/// pixel-identical.
struct StuffTabView: View {
    let appIndicatorContext: AppIndicatorContext
    @Bindable var conversationsViewModel: ConversationsViewModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets
    @Namespace private var localNamespace: Namespace.ID

    var body: some View {
        ZStack {
            NavigationStack {
                placeholderContent
                    .toolbar { trailingToolbar }
            }

            VStack {
                HStack {
                    appIndicatorPill
                        .hoverEffect(.lift)
                    Spacer(minLength: 0)
                }
                .padding(.top, horizontalSizeClass == .compact ? safeAreaInsets.top : DesignConstants.Spacing.step3x)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(true)
            .zIndex(1000)
        }
    }

    private var placeholderContent: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.colorTextSecondary)
            Text("Stuff")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Photos, files, and more from across every convo will show up here.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step8x)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundSurfaceless)
    }

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ComposeToolbarButton(
                viewModel: conversationsViewModel,
                transitionNamespace: appIndicatorContext.transitionNamespace,
                fallbackNamespace: localNamespace
            )
        }
    }

    @ViewBuilder
    private var appIndicatorPill: some View {
        let pill = AppIndicatorPill(
            profileImage: appIndicatorContext.profileImage,
            title: appIndicatorContext.title,
            subtitle: appIndicatorContext.subtitle,
            action: appIndicatorContext.onTap
        )
        if let namespace = appIndicatorContext.transitionNamespace,
           let id = appIndicatorContext.transitionId {
            pill.matchedTransitionSource(id: id, in: namespace)
        } else {
            pill
        }
    }
}
