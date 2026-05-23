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

    @State private var focusedAgentId: String?
    /// Flipped true once the contact cards have had a moment to
    /// settle in. Drives the staggered fade of the about
    /// sub-sections so the about content doesn't appear at the same
    /// moment the cards are still animating in.
    @State private var aboutSectionVisible: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            cardCarousel
                .padding(.top, DesignConstants.Spacing.step10x)
            if let focusedAgent {
                aboutSection(for: focusedAgent)
                    .padding(.top, DesignConstants.Spacing.step6x)
                    // The contact card carousel already has
                    // `peekInset` of horizontal padding via
                    // `.contentMargins`. The about section sits
                    // `step8x` deeper than that — visually aligning
                    // its leading edge with the card's *content*
                    // (avatar / name), not the card's outer edge.
                    .padding(.horizontal, Constant.peekInset + DesignConstants.Spacing.step8x)
            }
            Spacer(minLength: 0)
            exitButton
                .padding(.top, DesignConstants.Spacing.step4x)
        }
        .task {
            // Let the contact cards settle in before staggering in
            // the about section. The carousel cards have their own
            // ~350ms appearance fade inside `AgentContactCardView`;
            // this delay matches roughly so the about content
            // arrives after the cards have stopped fading.
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation {
                aboutSectionVisible = true
            }
        }
    }

    /// The card whose about section we should be showing — derived
    /// from `focusedAgentId` (set by `.scrollPosition(id:)` as the
    /// user scrolls between cards).
    private var focusedAgent: RandomAgent? {
        guard let focusedAgentId else { return nil }
        return agents.first(where: { $0.id == focusedAgentId })
    }

    @ViewBuilder
    private func aboutSection(for agent: RandomAgent) -> some View {
        // Each sub-section gets its own `.id(...-\(agent.id))` so
        // SwiftUI tears it down and re-inserts it when the focused
        // agent changes — that re-insertion drives the
        // `.blurReplace` transition. The `.delay(...)` on each
        // transition's animation staggers the cascade top → bottom
        // (Ideas → Connections → What I can do), so the new agent's
        // content washes in section-by-section instead of all at
        // once. The same transitions also fire on the initial
        // appearance when `aboutSectionVisible` flips, giving the
        // sub-sections their staggered entry after the cards have
        // settled in.
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            if aboutSectionVisible {
                aboutGroup(title: "Ideas for stuff") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(agent.ideasForStuff, id: \.self) { item in
                            sectionItemText(item)
                        }
                    }
                }
                .id("ideas-\(agent.id)")
                .transition(.blurReplace.animation(.easeInOut(duration: 0.3)))

                aboutGroup(title: "Connections") {
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        ForEach(agent.connections, id: \.self) { item in
                            sectionItemText(item)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .id("connections-\(agent.id)")
                .transition(.blurReplace.animation(.easeInOut(duration: 0.3).delay(0.08)))

                aboutGroup(title: "What I can do") {
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        ForEach(agent.whatICanDo, id: \.self) { item in
                            sectionItemText(item)
                        }
                        Image(systemName: "plus")
                            .font(.footnote)
                            .foregroundStyle(.colorTextTertiary)
                        Spacer(minLength: 0)
                    }
                }
                .id("what-\(agent.id)")
                .transition(.blurReplace.animation(.easeInOut(duration: 0.3).delay(0.16)))
            }
        }
        // Fill the available width so the section's outer frame
        // doesn't shrink to the intrinsic width of the currently
        // focused agent's content — otherwise the leading alignment
        // visibly slides as the user swipes between cards with
        // longer / shorter items.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func aboutGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
            content()
        }
    }

    /// Shared text style for every item under a section header —
    /// `.footnote` (SF Pro Regular 13pt / 18pt line height) per the
    /// design spec, primary text color.
    private func sectionItemText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.colorTextPrimary)
    }

    /// Peek carousel — recipe from the working CardStackHorizontalScrollView
    /// in the prototype project. Combines:
    ///
    ///   - fixed per-card `.frame(width: cardW, height: cardH)`,
    ///   - `.scrollTargetLayout()` on the inner LazyHStack,
    ///   - `.scrollTargetBehavior(.viewAligned)` on the ScrollView,
    ///   - `.contentMargins(.horizontal, peekInset, for: .scrollContent)`
    ///     (NOT `.padding`; the rails must be stationary), and
    ///   - `.scrollPosition(id:)` + a `ScrollViewReader` `scrollTo`
    ///     fallback in `.onAppear` because `scrollPosition`'s initial
    ///     value isn't honored on a `LazyHStack` (children aren't laid
    ///     out yet at view-appear time).
    ///
    /// Peek per side = `peekInset − interCardSpacing`.
    private var cardCarousel: some View {
        GeometryReader { proxy in
            let containerWidth: CGFloat = proxy.size.width
            let containerHeight: CGFloat = proxy.size.height
            let cardWidth: CGFloat = max(0, containerWidth - 2 * Constant.peekInset)
            let cardHeight: CGFloat = max(0, containerHeight)
            let cardSize: CGSize = CGSize(width: cardWidth, height: cardHeight)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Constant.interCardSpacing) {
                        ForEach(agents) { agent in
                            card(for: agent, size: cardSize)
                                .id(agent.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .contentMargins(.horizontal, Constant.peekInset, for: .scrollContent)
                .scrollPosition(id: $focusedAgentId)
                .onAppear {
                    let initial = focusedAgentId ?? agents.first?.id
                    focusedAgentId = initial
                    if let initial {
                        // `scrollPosition`'s initial value isn't honored
                        // on a `LazyHStack`, so explicitly center the
                        // first card via `ScrollViewReader.scrollTo`.
                        reader.scrollTo(initial, anchor: .center)
                    }
                }
            }
        }
        .frame(height: Constant.carouselHeight)
        .accessibilityIdentifier("remix-agent-carousel")
    }

    private func card(for agent: RandomAgent, size: CGSize) -> some View {
        Button {
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.1)) {
                viewModel.pickRemixAgent(agent)
            }
        } label: {
            AgentContactCardView(
                profile: agent.syntheticProfile(),
                agentDescription: agent.jobSummary,
                style: .hero,
                cardSize: size
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
        /// Horizontal inset on the scroll viewport so each focused card
        /// sits with `step6x` margins on either side. Combined with
        /// `.scrollClipDisabled`, the neighboring cards peek out beyond
        /// these margins by roughly `peekInset - interCardSpacing` pts.
        static let peekInset: CGFloat = DesignConstants.Spacing.step6x
        static let interCardSpacing: CGFloat = DesignConstants.Spacing.step2x
        /// Roughly the intrinsic height of the `.hero` contact card
        /// with a 2-line summary (step8x top padding + 74 avatar +
        /// step4x gap + 40pt bold name + 2 + 2 × 18pt summary lines
        /// + step8x bottom padding ≈ 232pt). Sized to match the card
        /// so the about section sits exactly `step6x` below the
        /// card's bottom edge — there's no empty space inside the
        /// carousel frame to widen that gap.
        static let carouselHeight: CGFloat = 232
        static let exitButtonSize: CGFloat = 56
    }
}

// No #Preview — `AgentBuilderViewModel` requires a real `SessionManager`
// (no mock factory), and the carousel is best validated inside the
// running builder anyway.
