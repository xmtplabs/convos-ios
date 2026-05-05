import ConvosCore
import SwiftUI

struct AssistantBuilderView: View {
    @Bindable var viewModel: AssistantBuilderViewModel

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            canvas
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) {
                            dismiss()
                        }
                        .accessibilityIdentifier("close-assistant-builder")
                    }
                }
                .background(.colorBackgroundSurfaceless)
                .selfSizingSheet(isPresented: bootstrapSheetBinding) {
                    CLIBootstrapSheet(viewModel: viewModel)
                }
        }
        .interactiveDismissDisabled()
        .onAppear {
            viewModel.setDismissAction(dismiss)
        }
    }

    private var bootstrapSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.phase == .bootstrap },
            set: { _ in }
        )
    }

    @ViewBuilder
    private var canvas: some View {
        Group {
            switch viewModel.phase {
            case .bootstrap:
                placeholderCanvas
                    .transition(.opacity)
            case .focus:
                FocusModeView(viewModel: viewModel)
                    .transition(.opacity)
            case .stopped:
                if viewModel.didTransitionToConversation {
                    fullConversationCanvas
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                } else {
                    sessionEndedCanvas
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.didTransitionToConversation)
    }

    @ViewBuilder
    private var placeholderCanvas: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("New Assistant")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            Text("Setting up your conversation…")
                .font(.system(.subheadline))
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sessionEndedCanvas: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            // Top region keeps the focused member's final phrase frozen so the
            // user has context for what they're about to chat about.
            LiveBubble(
                text: viewModel.focusedMemberLiveText.isEmpty
                    ? "Your assistant is ready."
                    : viewModel.focusedMemberLiveText,
                style: .focusedMember,
                tailCorner: .topTrailing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            let startChattingAction = { viewModel.startChattingTapped() }
            Button(action: startChattingAction) {
                Text("Start chatting")
                    .frame(maxWidth: .infinity)
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .frame(maxHeight: 80)
            .accessibilityIdentifier("start-chatting-button")
        }
        .padding(DesignConstants.Spacing.step3x)
    }

    @ViewBuilder
    private var fullConversationCanvas: some View {
        // Real ConversationView wiring lands separately. For the prototype
        // we show a confirmation state that the transition fired.
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Conversation started")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            Text("(ConversationView would render here)")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var presented: Bool = true
    let viewModel = AssistantBuilderViewModel(session: ConvosClient.mock().session)
    VStack {}
        .sheet(isPresented: $presented) {
            AssistantBuilderView(viewModel: viewModel)
        }
}
