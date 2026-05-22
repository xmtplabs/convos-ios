import ConvosCore
import StoreKit
import SwiftUI

struct SubscriptionSettingsView: View {
    // Seed @State synchronously from whatever the services have cached so the
    // first render shows real data instead of nil for one runloop tick.
    // `.onReceive` still drives updates on subsequent fetches.
    @State private var balance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var subscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    @State private var presentingPaywall: Bool = false
    @State private var presentingManageSubscriptions: Bool = false

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
        .onReceive(CreditsServices.shared.balancePublisher) { newBalance in
            balance = newBalance
        }
        .onReceive(SubscriptionServices.shared.subscriptionPublisher) { newSubscription in
            subscription = newSubscription
        }
        .task {
            // Refresh on appear (TTL-debounced) so the screen reflects
            // current backend state without waiting for foreground.
            await CreditsServices.shared.refresh()
            await SubscriptionServices.shared.refresh()
        }
        .refreshable {
            // Explicit user-initiated freshness — bypass TTL.
            await CreditsServices.shared.refresh(force: true)
            await SubscriptionServices.shared.refresh(force: true)
        }
        .sheet(isPresented: $presentingPaywall) {
            let viewModel = PaywallViewModel(subscriptionService: SubscriptionServices.shared)
            PaywallView(viewModel: viewModel)
        }
        .manageSubscriptionsSheet(isPresented: $presentingManageSubscriptions)
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
                let manageAction = { presentingManageSubscriptions = true }
                Button(action: manageAction) {
                    Text("Manage subscription")
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
