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
                    agentsRow
                    usageRow
                    exampleUses
                    pricingSection
                    ctaSection
                    if onSkip != nil {
                        trialSkipButton
                    }
                    legalFooter
                }
                .padding(.horizontal, DesignConstants.Spacing.step10x)
                .padding(.bottom, DesignConstants.Spacing.step10x)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .contentMargins(.top, DesignConstants.Spacing.step10x, for: .scrollContent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            Text(SubscriptionCopy.heroLabel)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
            TightLineHeightText(text: SubscriptionCopy.heroTitle, fontSize: 40, lineHeight: 38)
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
        .padding(.vertical, DesignConstants.Spacing.stepX)
    }

    // MARK: - Feature Rows

    @ViewBuilder
    private var agentsRow: some View {
        HStack {
            featureText(
                headline: SubscriptionCopy.agentsHeadline,
                subheadline: SubscriptionCopy.agentsSubheadline
            )
            Spacer()
            Image("addAgentIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.colorLava)
                .frame(width: 20, height: 20)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.colorFillPrimary))
        }
    }

    @ViewBuilder
    private var usageRow: some View {
        let isPlus: Bool = viewModel.selectedPlan == .plus
        let boltIcon: String = isPlus
            ? "bolt.fill"
            : "bolt.trianglebadge.exclamationmark.fill"
        let iconColor: Color = .colorLava
        let circleColor: Color = isPlus ? .colorFillPrimary : Color.colorLava.opacity(0.12)
        HStack {
            featureText(
                headline: SubscriptionCopy.usageHeadline(for: viewModel.selectedPlan),
                subheadline: SubscriptionCopy.usageSubheadline(for: viewModel.selectedPlan)
            )
            Spacer()
            Image(systemName: boltIcon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .offset(x: -1)
                .frame(width: 44, height: 44)
                .background(Circle().fill(circleColor))
        }
    }

    @ViewBuilder
    private func featureText(headline: String, subheadline: String) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(headline)
                .font(.body.weight(.medium))
                .foregroundStyle(.colorLava)
            Text(subheadline)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    // MARK: - Example Uses

    @ViewBuilder
    private var exampleUses: some View {
        let outcomes: [String] = SubscriptionCopy.outcomes(for: viewModel.selectedPlan)
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Example uses")
                .font(.footnote)
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
        } else if viewModel.plusMonthlyProduct != nil {
            plusPricing
        } else {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(.colorFillSubtle)
                .frame(height: 80)
        }
    }

    @ViewBuilder
    private var basicPricing: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(SubscriptionCopy.basicPriceLabel)
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
            Text(SubscriptionCopy.basicPriceSubtitle)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(.colorFillSubtle)
        )
    }

    @State private var thumbDragOffset: CGFloat = 0

    @ViewBuilder
    private var plusPricing: some View {
        let isMonthlySelected: Bool = viewModel.selectedProduct?.period == .monthly
        let thumbInset: CGFloat = 5
        let thumbRadius: CGFloat = DesignConstants.CornerRadius.mediumLarge - thumbInset
        HStack(spacing: 0) {
            pricePillLabel(
                price: viewModel.plusMonthlyProduct?.displayPrice ?? "",
                periodLabel: "Monthly",
                savingsLabel: nil
            )
            .contentShape(Rectangle())
            .onTapGesture { selectMonthlyIfAvailable() }

            pricePillLabel(
                price: viewModel.plusAnnualProduct?.displayPrice ?? "",
                periodLabel: "Yearly",
                savingsLabel: viewModel.annualSavingsPercent.map { "Save \($0)%" }
            )
            .contentShape(Rectangle())
            .onTapGesture { selectAnnualIfAvailable() }
        }
        .padding(thumbInset)
        .background {
            GeometryReader { geo in
                let thumbWidth: CGFloat = (geo.size.width - thumbInset * 2) / 2
                let thumbHeight: CGFloat = geo.size.height - thumbInset * 2
                let restOffset: CGFloat = isMonthlySelected ? 0 : thumbWidth
                let clampedDrag: CGFloat = min(max(restOffset + thumbDragOffset, 0), thumbWidth)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                        .fill(.colorFillSubtle)
                    RoundedRectangle(cornerRadius: thumbRadius)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .offset(x: thumbInset + clampedDrag, y: thumbInset)
                        .animation(
                            thumbDragOffset == 0 ? .snappy(duration: 0.25) : .interactiveSpring,
                            value: clampedDrag
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    thumbDragOffset = value.translation.width
                }
                .onEnded { value in
                    let isMonthly: Bool = viewModel.selectedProduct?.period == .monthly
                    let segmentGuess: CGFloat = 150
                    let restX: CGFloat = isMonthly ? 0 : segmentGuess
                    let landX: CGFloat = restX + value.translation.width
                    thumbDragOffset = 0
                    if landX > segmentGuess / 2 {
                        selectAnnualIfAvailable()
                    } else {
                        selectMonthlyIfAvailable()
                    }
                }
        )
    }

    private func selectMonthlyIfAvailable() {
        if let monthly = viewModel.plusMonthlyProduct {
            viewModel.selectProduct(monthly)
        }
    }

    private func selectAnnualIfAvailable() {
        if let annual = viewModel.plusAnnualProduct {
            viewModel.selectProduct(annual)
        }
    }

    @ViewBuilder
    private func pricePillLabel(
        price: String,
        periodLabel: String,
        savingsLabel: String?
    ) -> some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(price)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .monospacedDigit()
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(periodLabel)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                if let savingsLabel {
                    Text(savingsLabel)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorLava)
                }
            }
        }
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        if viewModel.selectedPlan == .basic {
            basicCTA
        } else if viewModel.isChangingPeriod {
            switchPeriodButton
        } else if viewModel.isSubscribed {
            manageSubscriptionButton
        } else {
            upgradeButton
        }
    }

    @ViewBuilder
    private var basicCTA: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            let dismissAction = { dismiss() }
            Button(action: dismissAction) {
                Text(SubscriptionCopy.stayBasicLabel)
            }
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))

            Text(SubscriptionCopy.upgradeAnytimeLabel)
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var upgradeButton: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
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
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
            .disabled(viewModel.selectedProduct == nil || isPurchasing)

            let renewPeriod: String = viewModel.selectedProduct?.period == .annual ? "yearly" : "monthly"
            Text("Auto-renews \(renewPeriod) \u{00B7} Cancel anytime")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var switchPeriodButton: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            let isPurchasing: Bool = viewModel.purchasingProductId != nil
            let periodName: String = viewModel.selectedProduct?.period == .annual ? "Yearly" : "Monthly"
            let purchaseAction = { _ = Task { await viewModel.purchase() } }
            Button(action: purchaseAction) {
                Text("Switch to \(periodName)")
                    .opacity(isPurchasing ? 0 : 1)
                    .overlay {
                        if isPurchasing {
                            ProgressView()
                                .tint(.colorTextPrimaryInverted)
                                .controlSize(.small)
                        }
                    }
            }
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
            .disabled(viewModel.selectedProduct == nil || isPurchasing)

            subscriberFooter
        }
    }

    @State private var presentingManageSubscriptions: Bool = false

    @ViewBuilder
    private var manageSubscriptionButton: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            let manageAction = { presentingManageSubscriptions = true }
            Button(action: manageAction) {
                Text(SubscriptionCopy.manageSubscriptionLabel)
            }
            .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorFillPrimary))

            subscriberFooter
        }
        .manageSubscriptionsSheet(isPresented: $presentingManageSubscriptions)
    }

    @ViewBuilder
    private var subscriberFooter: some View {
        if let sub = viewModel.currentSubscription {
            let tierName: String = SubscriptionCopy.displayName(for: sub.tier)
            let periodName: String = sub.period == .monthly ? "Monthly" : "Annual"
            Text("You subscribe to \(tierName) \(periodName)")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Legal & Skip

    @ViewBuilder
    private var legalFooter: some View {
        HStack(spacing: DesignConstants.Spacing.step6x) {
            if let url = URL(string: "https://convos.org/terms") {
                Link("Terms & Privacy", destination: url)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            Button("Restore", action: viewModel.restoreTapped)
                .font(.footnote)
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
}

#Preview("Basic") {
    let service = MockSubscriptionService(initialPreset: .noSubNoTrial)
    let viewModel = PaywallViewModel(subscriptionService: service)
    viewModel.selectedPlan = .basic
    return PaywallView(viewModel: viewModel)
}

#Preview("Plus - Upgrade Path") {
    let service = MockSubscriptionService(initialPreset: .noSubNoTrial)
    let viewModel = PaywallViewModel(subscriptionService: service)
    return PaywallView(viewModel: viewModel)
}

#Preview("Plus - Subscribed") {
    let service = MockSubscriptionService(initialPreset: .plusAmple)
    let viewModel = PaywallViewModel(subscriptionService: service)
    return PaywallView(viewModel: viewModel)
}
