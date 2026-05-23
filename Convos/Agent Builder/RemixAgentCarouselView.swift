import ConvosCore
import SwiftUI

/// Horizontal paged carousel of "random agents" the user can remix.
/// Replaces the composer in the Agent Builder while
/// `AgentBuilderViewModel.isShowingRemixCarousel` is true. Tapping a
/// card hands the picked agent up to the view model
/// (`pickRemixAgent`); the X button below the carousel exits Remix
/// mode entirely.
struct RemixAgentCarouselView: View {
    @Bindable var viewModel: AgentBuilderViewModel
    let agents: [RandomAgent]

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            cardCarousel
            exitButton
        }
    }

    private var cardCarousel: some View {
        // Native paging via `.scrollTargetBehavior(.viewAligned)` +
        // `containerRelativeFrame`. iOS handles the snap, paging dots, and
        // momentum — we just feed it a row of fixed-width pages.
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Constant.interCardSpacing) {
                ForEach(agents) { agent in
                    card(for: agent)
                        .containerRelativeFrame(.horizontal)
                        .scrollTargetLayout()
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .frame(height: Constant.carouselHeight)
        .accessibilityIdentifier("remix-agent-carousel")
    }

    private func card(for agent: RandomAgent) -> some View {
        Button {
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.1)) {
                viewModel.pickRemixAgent(agent)
            }
        } label: {
            AgentContactCardView(
                profile: agent.syntheticProfile(),
                agentDescription: agent.jobSummary
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remix-agent-card-\(agent.id)")
    }

    private var exitButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                viewModel.exitRemixMode()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.exitButtonSize, height: Constant.exitButtonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Exit remix mode")
        .accessibilityIdentifier("remix-exit-button")
    }

    private enum Constant {
        static let interCardSpacing: CGFloat = 16
        static let carouselHeight: CGFloat = 320
        static let exitButtonSize: CGFloat = 56
    }
}

// No #Preview — `AgentBuilderViewModel` requires a real `SessionManager`
// (no mock factory), and the carousel is best validated inside the
// running builder anyway.
