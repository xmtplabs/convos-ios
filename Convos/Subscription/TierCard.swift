import ConvosCore
import SwiftUI

struct TierCard: View {
    let tier: SubscriptionTier
    let product: PaywallProduct?
    let isCurrent: Bool
    let isPurchasing: Bool
    let onPurchase: (PaywallProduct) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            header
            bullets
            if !isCurrent {
                purchaseButton
            }
        }
        .padding(DesignConstants.Spacing.step5x)
        .background(background)
        .overlay(border)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(SubscriptionCopy.displayName(for: tier))
                    .font(.title3.bold())
                    .foregroundStyle(.colorTextPrimary)
                if isCurrent {
                    Text("Current plan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorRed)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: DesignConstants.Spacing.stepHalf) {
                Text(priceText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .monospacedDigit()
                if let perMonth = product?.pricePerMonthDisplay {
                    Text(perMonth)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var bullets: some View {
        let outcomes: [String] = SubscriptionCopy.outcomes(for: tier)
        let features: [String] = SubscriptionCopy.features(for: tier)
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            examplesGroup(outcomes)
            if !features.isEmpty {
                featuresGroup(features)
            }
        }
    }

    @ViewBuilder
    private func examplesGroup(_ outcomes: [String]) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text(SubscriptionCopy.examplesIntro)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
            ForEach(outcomes, id: \.self) { outcome in
                bulletRow(outcome)
            }
            Text(SubscriptionCopy.examplesDisclaimer)
                .font(.caption)
                .italic()
                .foregroundStyle(.colorTextTertiary)
                .padding(.top, DesignConstants.Spacing.stepX)
        }
    }

    @ViewBuilder
    private func featuresGroup(_ features: [String]) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text(SubscriptionCopy.featuresIntro)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
            ForEach(features, id: \.self) { feature in
                bulletRow(feature)
            }
        }
    }

    @ViewBuilder
    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.colorRed)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        let isDisabled: Bool = product == nil || isPurchasing
        let purchaseAction = {
            if let product { onPurchase(product) }
        }
        Button(action: purchaseAction) {
            Text("Subscribe")
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
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
            .fill(Color.colorBackgroundRaised)
    }

    @ViewBuilder
    private var border: some View {
        let strokeColor: Color = isCurrent ? Color.colorRed : Color.colorBorderSubtle
        let lineWidth: CGFloat = isCurrent ? 2 : 1
        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
            .stroke(strokeColor, lineWidth: lineWidth)
    }

    private var priceText: String {
        product?.displayPrice ?? "—"
    }
}

#Preview {
    let product = PaywallProduct(
        id: "app.convos.subs.builder.monthly",
        tier: .builder,
        period: .monthly,
        displayPrice: "$9.99",
        pricePerMonthDisplay: nil,
        currencyCode: "USD"
    )
    return VStack(spacing: 16) {
        TierCard(
            tier: .plus,
            product: product,
            isCurrent: false,
            isPurchasing: false,
            onPurchase: { _ in }
        )
        TierCard(
            tier: .plus,
            product: nil,
            isCurrent: true,
            isPurchasing: false,
            onPurchase: { _ in }
        )
    }
    .padding()
}
