import ConvosCore
import SwiftUI

struct PaywallView: View {
    @State private var viewModel: PaywallViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    private let onSkip: (() -> Void)?

    init(
        viewModel: PaywallViewModel,
        onSkip: (() -> Void)? = nil,
        onPurchaseSucceeded: (() -> Void)? = nil
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.onSkip = onSkip
        if let onPurchaseSucceeded {
            viewModel.onPurchaseSucceeded = onPurchaseSucceeded
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                    hero
                    periodPicker
                    tierStack
                    legal
                    if onSkip != nil {
                        trialSkipButton
                    }
                }
                .padding(.horizontal, DesignConstants.Spacing.step6x)
                .padding(.top, DesignConstants.Spacing.step6x)
                .padding(.bottom, DesignConstants.Spacing.step10x)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
        .task { await viewModel.loadProducts() }
        .alert(
            viewModel.alertTitle,
            isPresented: $viewModel.isShowingAlert,
            presenting: viewModel.alertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var trialSkipButton: some View {
        let skipAction: () -> Void = { onSkip?() }
        Button(action: skipAction) {
            Text("Start with a 7-day free trial")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        }
        .accessibilityIdentifier("paywall-skip-to-trial-button")
    }

    @ViewBuilder
    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Subscription")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)

            Text(SubscriptionCopy.heroTitle)
                .font(.convosTitle)
                .tracking(Font.convosTitleTracking)
                .foregroundStyle(.colorTextPrimary)

            Text(SubscriptionCopy.heroSubtitle)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    @ViewBuilder
    private var periodPicker: some View {
        Picker("Period", selection: $viewModel.selectedPeriod) {
            Text("Monthly").tag(SubscriptionPeriod?.some(.monthly))
            Text("Annual").tag(SubscriptionPeriod?.some(.annual))
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var tierStack: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            // No period chosen yet (typical for non-subscribers) → no cards.
            // The picker stays neutral until the user picks Monthly or Annual.
            if let period = viewModel.selectedPeriod {
                ForEach(SubscriptionTier.allCases, id: \.self) { tier in
                    // Hide tier cards that have no product for the selected
                    // period (e.g. Pro on Annual — Apple's price-tier ceiling
                    // for non-large-merchant accounts kept us from shipping
                    // Pro Annual at launch).
                    if viewModel.product(for: tier, period: period) != nil {
                        tierCard(for: tier, period: period)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tierCard(for tier: SubscriptionTier, period: SubscriptionPeriod) -> some View {
        let product: PaywallProduct? = viewModel.product(for: tier, period: period)
        // "Current plan" only highlights when both the tier AND the period
        // match the user's actual subscription — otherwise Builder Annual
        // subscribers would see "Current plan" on the Builder Monthly card
        // while the picker happens to be on Monthly.
        let isCurrent: Bool = viewModel.currentSubscription?.tier == tier
            && viewModel.currentSubscription?.period == period
        let isPurchasing: Bool = product != nil && viewModel.purchasingProductId == product?.id
        let purchaseHandler: (PaywallProduct) -> Void = { product in
            Task { await viewModel.purchase(product: product) }
        }
        TierCard(
            tier: tier,
            product: product,
            isCurrent: isCurrent,
            isPurchasing: isPurchasing,
            onPurchase: purchaseHandler
        )
    }

    @ViewBuilder
    private var legal: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.step6x) {
                if let url = URL(string: "https://convos.org/terms") {
                    Link("Terms", destination: url)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                if let url = URL(string: "https://convos.org/privacy") {
                    Link("Privacy", destination: url)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                Button("Restore", action: viewModel.restoreTapped)
                    .convosButtonStyle(.text)
            }
            .frame(maxWidth: .infinity)

            Text(viewModel.legalDisclaimer)
                .font(.caption2)
                .foregroundStyle(.colorTextTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DesignConstants.Spacing.step2x)
    }

    @ToolbarContentBuilder
    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            let dismissAction = { dismiss() }
            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .foregroundStyle(.colorTextPrimary)
            }
        }
    }
}

#Preview {
    let service = MockSubscriptionService(initialPreset: .noSubNoTrial)
    let viewModel = PaywallViewModel(subscriptionService: service)
    return PaywallView(viewModel: viewModel)
}
