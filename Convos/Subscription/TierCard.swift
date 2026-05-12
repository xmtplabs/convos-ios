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
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            ForEach(SubscriptionCopy.bullets(for: tier), id: \.self) { bullet in
                HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.colorRed)
                    Text(bullet)
                        .font(.subheadline)
                        .foregroundStyle(.colorTextPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        let isDisabled: Bool = product == nil || isPurchasing
        let purchaseAction = {
            if let product { onPurchase(product) }
        }
        Button(action: purchaseAction) {
            ZStack {
                if isPurchasing {
                    ProgressView()
                        .tint(.colorTextPrimaryInverted)
                } else {
                    Text("Subscribe")
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
            tier: .builder,
            product: product,
            isCurrent: false,
            isPurchasing: false,
            onPurchase: { _ in }
        )
        TierCard(
            tier: .pro,
            product: nil,
            isCurrent: true,
            isPurchasing: false,
            onPurchase: { _ in }
        )
    }
    .padding()
}
