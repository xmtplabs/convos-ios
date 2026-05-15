import ConvosCore
import SwiftUI

struct LowBalanceBanner: View {
    @State private var balance: CreditBalance?
    @State private var presentingPaywall: Bool = false

    var body: some View {
        Group {
            if let balance, shouldShow(for: balance), !ConfigManager.shared.currentEnvironment.isProduction {
                bannerContent(balance: balance)
            }
        }
        .onReceive(MockCreditsService.shared.balancePublisher) { newBalance in
            balance = newBalance
        }
        .sheet(isPresented: $presentingPaywall) {
            let viewModel = PaywallViewModel(subscriptionService: SubscriptionServices.shared)
            PaywallView(viewModel: viewModel)
        }
    }

    private func shouldShow(for balance: CreditBalance) -> Bool {
        balance.isLow || balance.isDepleted
    }

    @ViewBuilder
    private func bannerContent(balance: CreditBalance) -> some View {
        let isDepleted: Bool = balance.isDepleted
        let icon: String = isDepleted ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        let title: String = isDepleted ? "You're out of credits" : "\(balance.balance) credits left"
        let upgradeAction = { presentingPaywall = true }
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.colorRed)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
            Spacer(minLength: DesignConstants.Spacing.step2x)
            Button(action: upgradeAction) {
                Text("Upgrade")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorRed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Upgrade plan")
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .frame(maxWidth: .infinity)
        .background(.colorBackgroundRaised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.colorBorderSubtle)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Low") {
    let balance = CreditBalance(
        balance: 180,
        monthlyGrant: 1_500,
        monthlyGrantUsed: 1_320,
        nextRefreshAt: Date(),
        periodLabel: "May 2026"
    )
    return LowBalancePreviewWrapper(balance: balance)
}

#Preview("Depleted") {
    let balance = CreditBalance(
        balance: 0,
        monthlyGrant: 1_500,
        monthlyGrantUsed: 1_500,
        nextRefreshAt: Date(),
        periodLabel: "May 2026"
    )
    return LowBalancePreviewWrapper(balance: balance)
}

private struct LowBalancePreviewWrapper: View {
    let balance: CreditBalance

    var body: some View {
        VStack(spacing: 0) {
            LowBalanceBanner()
                .onAppear {
                    MockCreditsService.shared.setPreset(preset(for: balance))
                }
            Color.colorBackgroundSurfaceless
        }
    }

    private func preset(for balance: CreditBalance) -> CreditsStatePreset {
        balance.isDepleted ? .builderDepleted : .builderLow
    }
}
