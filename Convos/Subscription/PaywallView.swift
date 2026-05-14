import ConvosCore
import SwiftUI

struct PaywallView: View {
    @State private var viewModel: PaywallViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(viewModel: PaywallViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
                    hero
                    periodPicker
                    tierStack
                    legal
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
            "Something went wrong",
            isPresented: $viewModel.isShowingError,
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
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
            Text("Monthly").tag(SubscriptionPeriod.monthly)
            Text("Annual").tag(SubscriptionPeriod.annual)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var tierStack: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            ForEach(SubscriptionTier.allCases, id: \.self) { tier in
                tierCard(for: tier)
            }
        }
    }

    @ViewBuilder
    private func tierCard(for tier: SubscriptionTier) -> some View {
        let product: PaywallProduct? = viewModel.product(for: tier, period: viewModel.selectedPeriod)
        let isCurrent: Bool = viewModel.currentTier == tier
        let isPurchasing: Bool = viewModel.purchasingProductId == product?.id
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
