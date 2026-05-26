import ConvosCore
import StoreKit
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
                    planPicker
                    creditRow
                    agentsRow
                    exampleUses
                    pricingSection
                    ctaButton
                    if onSkip != nil {
                        trialSkipButton
                    }
                    legalFooter
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

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text(SubscriptionCopy.heroLabel)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
            Text(SubscriptionCopy.heroTitle)
                .font(.convosTitle)
                .tracking(Font.convosTitleTracking)
                .foregroundStyle(.colorTextPrimary)
        }
    }

    // MARK: - Plan Picker

    @ViewBuilder
    private var planPicker: some View {
        Picker("Plan", selection: $viewModel.selectedPlan) {
            Text("Basic").tag(PaywallPlan.basic)
            Text("Plus").tag(PaywallPlan.plus)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Feature Rows

    @ViewBuilder
    private var creditRow: some View {
        featureRow(
            headline: SubscriptionCopy.creditHeadline(for: viewModel.selectedPlan),
            subheadline: SubscriptionCopy.creditSubheadline,
            iconName: "bolt.fill",
            isActive: viewModel.selectedPlan == .plus
        )
    }

    @ViewBuilder
    private var agentsRow: some View {
        featureRow(
            headline: SubscriptionCopy.agentsHeadline,
            subheadline: SubscriptionCopy.agentsSubheadline,
            iconName: "sparkles",
            isActive: viewModel.selectedPlan == .plus
        )
    }

    @ViewBuilder
    private func featureRow(
        headline: String,
        subheadline: String,
        iconName: String,
        isActive: Bool
    ) -> some View {
        let iconOpacity: Double = isActive ? 1.0 : 0.4
        HStack {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorRed)
                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
            Spacer()
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.colorRed)
                .opacity(iconOpacity)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.colorRed.opacity(isActive ? 0.12 : 0.06))
                )
        }
    }

    // MARK: - Example Uses

    @ViewBuilder
    private var exampleUses: some View {
        let outcomes: [String] = SubscriptionCopy.outcomes(for: viewModel.selectedPlan)
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Example uses")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
            ForEach(outcomes, id: \.self) { outcome in
                Text(outcome)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
            }
        }
    }

    // MARK: - Pricing

    @ViewBuilder
    private var pricingSection: some View {
        if viewModel.selectedPlan == .basic {
            basicPricing
        } else {
            plusPricing
        }
    }

    @ViewBuilder
    private var basicPricing: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Text(SubscriptionCopy.basicPriceLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text(SubscriptionCopy.basicPriceSubtitle)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var plusPricing: some View {
        let isMonthlySelected: Bool = viewModel.selectedProduct?.period == .monthly
        HStack(spacing: DesignConstants.Spacing.step3x) {
            if let monthly = viewModel.plusMonthlyProduct {
                pricePill(
                    price: monthly.displayPrice,
                    periodLabel: "Monthly",
                    savingsLabel: nil,
                    isSelected: isMonthlySelected,
                    product: monthly
                )
            }
            if let annual = viewModel.plusAnnualProduct {
                let savingsText: String? = viewModel.annualSavingsPercent.map { "Save \($0)%" }
                pricePill(
                    price: annual.displayPrice,
                    periodLabel: "Yearly",
                    savingsLabel: savingsText,
                    isSelected: !isMonthlySelected,
                    product: annual
                )
            }
        }
    }

    @ViewBuilder
    private func pricePill(
        price: String,
        periodLabel: String,
        savingsLabel: String?,
        isSelected: Bool,
        product: PaywallProduct
    ) -> some View {
        let borderColor: Color = isSelected ? .colorRed : .colorBorderSubtle
        let lineWidth: CGFloat = isSelected ? 2 : 1
        let selectAction = { viewModel.selectProduct(product) }
        Button(action: selectAction) {
            VStack(spacing: DesignConstants.Spacing.stepX) {
                Text(price)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .monospacedDigit()
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Text(periodLabel)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                    if let savingsLabel {
                        Text(savingsLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.colorRed)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .stroke(borderColor, lineWidth: lineWidth)
            )
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaButton: some View {
        if viewModel.selectedPlan == .basic {
            let dismissAction = { dismiss() }
            Button(action: dismissAction) {
                Text(SubscriptionCopy.stayBasicLabel)
            }
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorRed))
        } else if viewModel.isSubscribed {
            manageSubscriptionButton
        } else {
            upgradeButton
        }
    }

    @ViewBuilder
    private var upgradeButton: some View {
        let isPurchasing: Bool = viewModel.purchasingProductId != nil
        let purchaseAction = { _ = Task { await viewModel.purchase() } }
        Button(action: purchaseAction) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "bolt.fill")
                Text(SubscriptionCopy.upgradeLabel)
            }
            .opacity(isPurchasing ? 0 : 1)
            .overlay {
                if isPurchasing {
                    ProgressView()
                        .tint(.colorTextPrimaryInverted)
                        .controlSize(.small)
                }
            }
        }
        .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorRed))
        .disabled(viewModel.selectedProduct == nil || isPurchasing)
    }

    @State private var presentingManageSubscriptions: Bool = false

    @ViewBuilder
    private var manageSubscriptionButton: some View {
        let manageAction = { presentingManageSubscriptions = true }
        Button(action: manageAction) {
            Text(SubscriptionCopy.manageSubscriptionLabel)
        }
        .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorFillPrimary))
        .manageSubscriptionsSheet(isPresented: $presentingManageSubscriptions)
    }

    // MARK: - Legal & Skip

    @ViewBuilder
    private var legalFooter: some View {
        HStack(spacing: DesignConstants.Spacing.step6x) {
            if let url = URL(string: "https://convos.org/terms") {
                Link("Terms & Privacy", destination: url)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            Button("Restore", action: viewModel.restoreTapped)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity)
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

#Preview("Non-subscriber") {
    let service = MockSubscriptionService(initialPreset: .noSubNoTrial)
    let viewModel = PaywallViewModel(subscriptionService: service)
    return PaywallView(viewModel: viewModel)
}

#Preview("Subscriber") {
    let service = MockSubscriptionService(initialPreset: .plusAmple)
    let viewModel = PaywallViewModel(subscriptionService: service)
    return PaywallView(viewModel: viewModel)
}
