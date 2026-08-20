#if DEBUG
import ConvosCore
import ConvosMetrics
import SwiftUI

/// Debug-only launch surface for the SHANE MAC UX DONT MERGE branch. Launch
/// with `CONVOS_AGENT_MODEL_PROTOTYPE=1` to evaluate the exact selector,
/// picker, pending-upgrade state, and existing paywall without account data.
struct AgentModelPrototypeView: View {
    let coreActions: any CoreActions
    private let subscriptionService: any SubscriptionServiceProtocol

    @State private var selectedModel: AgentModelOption = .chatGPT
    @State private var pendingModel: AgentModelOption?
    @State private var hasPlusSubscription: Bool
    @State private var presentingPicker: Bool = false
    @State private var presentingPaywall: Bool = false

    init(coreActions: any CoreActions) {
        self.coreActions = coreActions
        let prototypeState: String? = ProcessInfo.processInfo.environment[
            "CONVOS_AGENT_MODEL_PROTOTYPE_STATE"
        ]
        let subscriptionService: any SubscriptionServiceProtocol = prototypeState == nil
            ? SubscriptionServices.shared
            : MockSubscriptionService(initialPreset: .noSubNoTrial)
        self.subscriptionService = subscriptionService
        _hasPlusSubscription = State(
            initialValue: subscriptionService.currentSubscription != nil
        )
        _pendingModel = State(
            initialValue: prototypeState.map { ["upgrade", "paywall"].contains($0) } == true
                ? .claude
                : nil
        )
        _presentingPicker = State(initialValue: prototypeState == "picker")
        _presentingPaywall = State(initialValue: prototypeState == "paywall")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0.0) {
                    prototypeLabel
                    agentHeader

                    AgentModelSelectorSection(
                        model: pendingModel ?? selectedModel,
                        needsUpgrade: pendingModel != nil,
                        onChooseModel: { presentingPicker = true },
                        onUpgrade: { presentingPaywall = true }
                    )
                    .padding(.top, DesignConstants.Spacing.step8x)

                    explanation
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.bottom, DesignConstants.Spacing.step10x)
            }
            .background(.colorBackgroundRaisedSecondary)
            .navigationTitle("Agent profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset") {
                        selectedModel = .chatGPT
                        pendingModel = nil
                    }
                }
            }
        }
        .sheet(isPresented: $presentingPicker) {
            AgentModelPickerSheet(
                activeModel: selectedModel,
                highlightedModel: pendingModel ?? selectedModel,
                hasPlusSubscription: hasPlusSubscription,
                onSelect: handleSelection
            )
        }
        .sheet(isPresented: $presentingPaywall) {
            PaywallView(
                viewModel: PaywallViewModel(
                    subscriptionService: subscriptionService,
                    paywallSource: .settings,
                    coreActions: coreActions
                ),
                onPurchaseSucceeded: handlePurchaseSucceeded
            )
        }
        .onReceive(subscriptionService.subscriptionPublisher) { subscription in
            hasPlusSubscription = subscription != nil
            if subscription != nil, let pendingModel {
                activate(pendingModel)
            }
        }
    }

    private var prototypeLabel: some View {
        Text("SHANE MAC UX · DONT MERGE")
            .font(.caption.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.colorTextPrimary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 32.0)
            .background(Capsule().fill(.colorFillMinimal))
            .padding(.top, DesignConstants.Spacing.step6x)
    }

    private var agentHeader: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text("✨")
                .font(.system(size: 68.0))
                .frame(width: 156.0, height: 156.0)
                .background(Circle().fill(.colorLava))
                .accessibilityLabel("Space Abilities profile photo")

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Text("Space Abilities")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Choose how much power this agent uses")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
                Text("Agent")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 28.0)
                    .background(Capsule().fill(.colorFillMinimal))
            }
        }
        .padding(.top, DesignConstants.Spacing.step8x)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Label("Selection applies only to Space Abilities", systemImage: "person.crop.circle")
            Label("Credit use is shown before activation", systemImage: "bolt.circle")
            Label("Premium choices use the existing membership sheet", systemImage: "creditcard.circle")
        }
        .font(.footnote)
        .foregroundStyle(.colorTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignConstants.Spacing.step4x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(.colorFillMinimal)
        )
        .padding(.top, DesignConstants.Spacing.step4x)
    }

    private func handleSelection(_ model: AgentModelOption) {
        if model.requiresPlus, !hasPlusSubscription {
            pendingModel = model
        } else {
            activate(model)
        }
    }

    private func activate(_ model: AgentModelOption) {
        selectedModel = model
        pendingModel = nil
    }

    private func handlePurchaseSucceeded() {
        presentingPaywall = false
        Task { await subscriptionService.refresh(force: true) }
    }
}
#endif
