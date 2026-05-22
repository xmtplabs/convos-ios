import ConvosCore
import SwiftUI

struct ConversationMemberView: View {
    @Bindable var viewModel: ConversationViewModel
    let member: ConversationMember

    @State private var presentingBlockConfirmation: Bool = false
    @State private var creditsBalance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var presentingPaywall: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        List {
            headerSection
            outOfCreditsSection

            if member.isAgent {
                agentSections
            } else {
                nonAgentSections
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .onReceive(CreditsServices.shared.balancePublisher) { newBalance in
            creditsBalance = newBalance
        }
        .task {
            // Refresh credits when the contact sheet appears so the
            // "out of credits" section + upgrade CTA reflect current
            // backend state. TTL-debounced inside the service.
            await CreditsServices.shared.refresh()
        }
        .sheet(isPresented: $presentingPaywall) {
            let paywallViewModel = PaywallViewModel(subscriptionService: SubscriptionServices.shared)
            PaywallView(viewModel: paywallViewModel)
        }
        .alert(
            "Block \(member.profile.displayName) and leave convo?",
            isPresented: $presentingBlockConfirmation
        ) {
            let cancelAction = { presentingBlockConfirmation = false }
            Button("Cancel", role: .cancel, action: cancelAction)
            let confirmAction = { viewModel.blockAndLeaveConvo(inboxId: member.profile.inboxId) }
            Button("Confirm", role: .destructive, action: confirmAction)
        } message: {
            Text("They won't know they're blocked, and you'll leave this conversation so they can't reach you here.")
        }
    }

    @ViewBuilder
    private var outOfCreditsSection: some View {
        if shouldShowOutOfCredits {
            Section {
                outOfCreditsRow
                upgradeButton
            }
            .listRowBackground(Color.colorBackgroundRaised)
        }
    }

    private var shouldShowOutOfCredits: Bool {
        guard member.isAgent,
              !ConfigManager.shared.currentEnvironment.isProduction,
              let creditsBalance else { return false }
        return creditsBalance.isDepleted
    }

    @ViewBuilder
    private var outOfCreditsRow: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.colorRed)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text("Out of credits")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Your agents are paused until you upgrade or top up.")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DesignConstants.Spacing.stepX)
    }

    @ViewBuilder
    private var upgradeButton: some View {
        let upgradeAction = { presentingPaywall = true }
        Button(action: upgradeAction) {
            Text("Upgrade")
                .font(.body)
                .foregroundStyle(.colorRed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("upgrade-from-out-of-credits-button")
    }

    private var headerSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: DesignConstants.Spacing.step4x) {
                    MessageAvatarView(profile: member.profile, size: 160.0, agentVerification: member.agentVerification)

                    VStack(spacing: DesignConstants.Spacing.step2x) {
                        Text(member.profile.displayName)
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                            .foregroundStyle(.colorTextPrimary)

                        if member.isCurrentUser {
                            Text("You")
                                .font(.headline)
                                .foregroundStyle(.colorTextSecondary)
                        } else if let subtitle = memberSubtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    @ViewBuilder
    private var agentSections: some View {
        if member.agentVerification.isVerified {
            Section {
                let action = { openURL(Constant.getSkillsURL) }
                Button(action: action) {
                    cardRow(title: "Get skills")
                }
            } footer: {
                Text("Browse 100+ curated capabilities")
                    .foregroundStyle(.colorTextSecondary)
            }

            Section {
                let action = { openURL(Constant.learnAboutAgentsURL) }
                Button(action: action) {
                    cardRow(title: "Learn about agents")
                }
            } footer: {
                Text("Capabilities, privacy and security")
                    .foregroundStyle(.colorTextSecondary)
            }
        }

        if viewModel.canRemoveMembers {
            Section {
                let action = {
                    viewModel.remove(member: member)
                    dismiss()
                }
                Button(action: action) {
                    Text("Remove")
                        .font(.body)
                        .foregroundStyle(.colorCaution)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(member.profile.displayName)")
                .accessibilityIdentifier("remove-member-button")
            } footer: {
                Text("Dismiss and destroy \(member.profile.displayName)")
                    .foregroundStyle(.colorTextSecondary)
            }
        }

        if !member.isCurrentUser {
            Section {
                let action = { presentingBlockConfirmation = true }
                Button(action: action) {
                    Text("Block and leave")
                        .font(.body)
                        .foregroundStyle(.colorCaution)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Block \(member.profile.displayName)")
                .accessibilityIdentifier("block-member-button")
            } footer: {
                Text("Leave this convo and block \(member.profile.displayName)")
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var nonAgentSections: some View {
        if !member.isCurrentUser {
            if viewModel.canRemoveMembers {
                Section {
                    let action = {
                        viewModel.remove(member: member)
                        dismiss()
                    }
                    Button(action: action) {
                        Text("Remove")
                            .font(.body)
                            .foregroundStyle(.colorCaution)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Remove \(member.profile.displayName)")
                    .accessibilityIdentifier("remove-member-button")
                } footer: {
                    Text("Remove \(member.profile.displayName) from the convo")
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            Section {
                let action = { presentingBlockConfirmation = true }
                Button(action: action) {
                    Text("Block and leave")
                        .font(.body)
                        .foregroundStyle(.colorCaution)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Block \(member.profile.displayName)")
                .accessibilityIdentifier("block-member-button")
            } footer: {
                Text("Leave this convo and block \(member.profile.displayName)")
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    private func cardRow(title: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.colorTextTertiary)
        }
    }

    private var memberSubtitle: String? {
        var parts: [String] = []
        if member.isAgent {
            parts.append(Constant.agentLabel)
        }
        if let joinedAt = member.joinedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let relative = formatter.localizedString(for: joinedAt, relativeTo: Date())
            if let invitedBy = member.invitedBy {
                parts.append("Added \(relative) by \(invitedBy.displayName)")
            } else {
                parts.append("Added \(relative)")
            }
        } else if let invitedBy = member.invitedBy {
            parts.append("Added by \(invitedBy.displayName)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private enum Constant {
        static let agentLabel: String = "IA"
        // swiftlint:disable:next force_unwrapping
        static let getSkillsURL: URL = URL(string: "https://convos.org/assistants")!
        // swiftlint:disable:next force_unwrapping
        static let learnAboutAgentsURL: URL = URL(string: "https://learn.convos.org/assistants")!
    }
}

@MainActor
private func makeMemberPreviewViewModel() -> ConversationViewModel {
    .mock
}

#Preview {
    ConversationMemberView(viewModel: makeMemberPreviewViewModel(), member: .mock())
}
