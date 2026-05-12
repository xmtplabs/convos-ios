import ConvosCore
import SwiftUI

struct TierCard: View {
    let tier: SubscriptionTier
    let product: PaywallProduct?
    let isCurrent: Bool
    let isPurchasing: Bool
    let onPurchase: (PaywallProduct) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            bullets
            cta
        }
        .padding(16)
        .background(background)
        .overlay(border)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SubscriptionCopy.displayName(for: tier))
                    .font(.title3.bold())
                if isCurrent {
                    Text("Current plan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(priceText)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                if let perMonth = product?.pricePerMonthDisplay {
                    Text(perMonth)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var bullets: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SubscriptionCopy.bullets(for: tier), id: \.self) { bullet in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(bullet)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var cta: some View {
        let label: String = ctaLabel
        let isDisabled: Bool = product == nil || isCurrent || isPurchasing
        let purchaseAction = {
            if let product { onPurchase(product) }
        }
        Button(action: purchaseAction) {
            ZStack {
                if isPurchasing {
                    ProgressView()
                } else {
                    Text(label)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.thinMaterial)
    }

    @ViewBuilder
    private var border: some View {
        let strokeColor: Color = isCurrent ? Color.accentColor : Color.clear
        RoundedRectangle(cornerRadius: 16)
            .stroke(strokeColor, lineWidth: 2)
    }

    private var priceText: String {
        product?.displayPrice ?? "—"
    }

    private var ctaLabel: String {
        if isCurrent { return "Current" }
        if isPurchasing { return "Purchasing…" }
        return "Subscribe"
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
