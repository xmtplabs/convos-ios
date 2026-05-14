import ConvosCore
import SwiftUI

struct SubscriptionSettingsView: View {
    @State private var balance: CreditBalance?
    @State private var subscription: UserSubscription?
    @State private var presentingPaywall: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        List {
            statusSection
            if balance != nil {
                balanceSection
            }
            actionsSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(MockCreditsService.shared.balancePublisher) { newBalance in
            balance = newBalance
        }
        .onReceive(MockSubscriptionService.shared.subscriptionPublisher) { newSubscription in
            subscription = newSubscription
        }
        .sheet(isPresented: $presentingPaywall) {
            let viewModel = PaywallViewModel(subscriptionService: MockSubscriptionService.shared)
            PaywallView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(statusTitle)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.stepX)
        }
    }

    @ViewBuilder
    private var balanceSection: some View {
        if let balance {
            Section {
                HStack {
                    Text("Credits remaining")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    Text(balanceText(balance))
                        .foregroundStyle(.colorTextSecondary)
                        .monospacedDigit()
                }
            } footer: {
                Text(balanceFooter(balance))
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            let ctaTitle: String = subscription == nil ? "Subscribe" : "Change plan"
            let ctaAction = { presentingPaywall = true }
            Button(action: ctaAction) {
                Text(ctaTitle)
                    .foregroundStyle(.colorRed)
            }

            if subscription != nil {
                let manageAction = { openManageSubscriptionsURL() }
                Button(action: manageAction) {
                    Text("Manage in App Store")
                        .foregroundStyle(.colorTextPrimary)
                }
            }
        }
    }

    private var statusTitle: String {
        guard let subscription else { return "Free plan" }
        let name: String = SubscriptionCopy.displayName(for: subscription.tier)
        if subscription.isInTrial {
            return "\(name) trial"
        }
        return "\(name) plan"
    }

    private var statusSubtitle: String {
        guard let subscription else {
            return "Subscribe to power your agents"
        }
        let periodText: String = subscription.period == .monthly ? "Monthly" : "Annual"
        let dateString: String = Self.dateFormatter.string(from: subscription.currentPeriodEnd)
        let renewalText: String
        switch subscription.status {
        case .trial:
            renewalText = "Trial ends \(dateString)"
        case .grace:
            renewalText = "Grace period until \(dateString)"
        case .billingRetry:
            renewalText = "Payment retrying — update in App Store"
        case .expired, .revoked:
            renewalText = "Expired \(dateString)"
        case .active:
            renewalText = subscription.willRenew ? "Renews \(dateString)" : "Expires \(dateString)"
        }
        return "\(periodText) · \(renewalText)"
    }

    private func balanceText(_ balance: CreditBalance) -> String {
        "\(balance.balance) / \(balance.monthlyGrant)"
    }

    private func balanceFooter(_ balance: CreditBalance) -> String {
        let dateString: String = Self.dateFormatter.string(from: balance.nextRefreshAt)
        return "Refreshes \(dateString)"
    }

    private func openManageSubscriptionsURL() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        openURL(url)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

#Preview("Builder active") {
    NavigationStack {
        SubscriptionSettingsView()
            .onAppear {
                MockCreditsService.shared.setPreset(.builderAmple)
                MockSubscriptionService.shared.setPreset(.builderAmple)
            }
    }
}

#Preview("No subscription") {
    NavigationStack {
        SubscriptionSettingsView()
            .onAppear {
                MockCreditsService.shared.setPreset(.noSubNoTrial)
                MockSubscriptionService.shared.setPreset(.noSubNoTrial)
            }
    }
}
