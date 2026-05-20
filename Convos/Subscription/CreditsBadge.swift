import ConvosCore
import SwiftUI

struct CreditsBadge: View {
    @State private var balance: CreditBalance? = CreditsServices.shared.currentBalance

    var body: some View {
        Group {
            if let balance, !ConfigManager.shared.currentEnvironment.isProduction {
                CreditsBadgePill(balance: balance)
            }
        }
        .onReceive(CreditsServices.shared.balancePublisher) { newBalance in
            balance = newBalance
        }
    }
}

private struct CreditsBadgePill: View {
    let balance: CreditBalance

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(.colorRed)
            Text(balance.balance, format: .number)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.stepHalf)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(balance.balance) credits remaining")
    }

    @ViewBuilder
    private var background: some View {
        Capsule()
            .fill(Color.colorFillMinimal)
    }
}

#Preview {
    let balance = CreditBalance(
        balance: 1_400,
        monthlyGrant: 1_500,
        monthlyGrantUsed: 100,
        nextRefreshAt: Date(),
        periodLabel: "May 2026"
    )
    return CreditsBadgePill(balance: balance)
        .padding()
}
