import ConvosCore
import SwiftUI

struct AssistantBuilderView: View {
    @Bindable var viewModel: AssistantBuilderViewModel

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var sidebarWidth: CGFloat = 0

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.newConversationViewModel.conversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: false,
            sidebarColumnWidth: $sidebarWidth,
            indicatorPlaceholderOverride: "New assistant",
            indicatorSubtitleOverride: "Draft",
            isIndicatorEnabled: viewModel.hasCommitted
        ) { focusState, coordinator in
            NavigationStack {
                VStack(spacing: 0) {
                    AssistantDraftComposer(
                        viewModel: viewModel,
                        focusState: focusState,
                        onMakeTap: {}
                    )
                    .frame(height: Constant.composerHeight)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.top, DesignConstants.Spacing.step4x)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.colorBackgroundRaisedSecondary.ignoresSafeArea())
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) {
                            dismiss()
                        }
                        .accessibilityIdentifier("close-assistant-builder")
                    }
                }
                .onAppear {
                    coordinator.moveFocus(to: .message)
                }
            }
        }
        .onAppear {
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
    }

    private enum Constant {
        static let composerHeight: CGFloat = 375.0
    }
}

#Preview {
    @Previewable @State var viewModel: AssistantBuilderViewModel = .init(
        session: ConvosClient.mock().session
    )
    @Previewable @State var presented: Bool = true
    VStack {}
        .sheet(isPresented: $presented) {
            AssistantBuilderView(viewModel: viewModel)
        }
}
