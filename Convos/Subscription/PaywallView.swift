import ConvosCore
import SwiftUI

struct PaywallView: View {
    @State private var viewModel: PaywallViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: PaywallViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    hero
                    periodPicker
                    tierStack
                    legal
                }
                .padding(.horizontal)
                .padding(.vertical, 32)
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
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(SubscriptionCopy.heroTitle)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(SubscriptionCopy.heroSubtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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
        VStack(spacing: 16) {
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
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                if let url = URL(string: "https://convos.org/terms") {
                    Link("Terms", destination: url)
                }
                if let url = URL(string: "https://convos.org/privacy") {
                    Link("Privacy", destination: url)
                }
                Button("Restore", action: viewModel.restoreTapped)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(viewModel.legalDisclaimer)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ToolbarContentBuilder
    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            let dismissAction = { dismiss() }
            Button(action: dismissAction) {
                Image(systemName: "xmark")
            }
        }
    }
}

#Preview {
    let service = MockSubscriptionService(initialPreset: .noSubNoTrial)
    let viewModel = PaywallViewModel(subscriptionService: service)
    return PaywallView(viewModel: viewModel)
}
