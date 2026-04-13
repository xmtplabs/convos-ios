import ConvosCore
import SwiftUI
import UIKit

struct AssistantSettingsView: View {
    let session: any SessionManagerProtocol

    @Bindable private var defaults: GlobalConvoDefaults = .shared
    @State private var presentingCodeEntry: Bool = false
    @State private var inviteCodeStatus: ConvosAPI.InviteCodeStatus?
    @State private var inviteCodeStatusTask: Task<Void, Never>?
    @State private var copiedInviteCode: Bool = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Assistants")
                        .font(.convosTitle)
                        .tracking(Font.convosTitleTracking)
                        .foregroundStyle(.colorTextPrimary)
                    Text("Help groups do things")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextPrimary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)
            .listRowSpacing(0.0)
            .listRowInsets(.all, DesignConstants.Spacing.step2x)
            .listSectionMargins(.top, 0.0)
            .listSectionSeparator(.hidden)

            Section {
                if defaults.assistantCodeUnlocked {
                    Toggle(isOn: $defaults.assistantsEnabled) {
                        Text("Instant assistant")
                            .foregroundStyle(.colorTextPrimary)
                    }
                    .accessibilityIdentifier("assistants-enabled-toggle")
                } else {
                    let action = { presentingCodeEntry = true }
                    Button(action: action) {
                        HStack {
                            Text("Instant assistant")
                                .foregroundStyle(.colorTextPrimary)
                            Spacer()
                            Toggle("", isOn: .constant(false))
                                .labelsHidden()
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("assistants-enabled-toggle")
                }
            } footer: {
                Text("Swipe up in new convos")
            }

            if let inviteCodeStatus {
                Section {
                    Button(action: copyInviteCode) {
                        HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.stepX) {
                            Text(inviteCodeStatus.code)
                                .font(.body.monospaced())
                                .foregroundStyle(.colorTextPrimary)
                            Spacer()
                            Text(remainingRedemptionsText(inviteCodeStatus.remainingRedemptions))
                                .font(.footnote)
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                    .accessibilityIdentifier("assistant-invite-code-row")
                    .accessibilityLabel("Invite code \(inviteCodeStatus.code), \(remainingRedemptionsText(inviteCodeStatus.remainingRedemptions)). Tap to copy")
                } footer: {
                    Text(copiedInviteCode ? "Copied" : "Tap to copy your invite code")
                }
            }

            Section {
                if let learnURL = URL(string: "https://learn.convos.org/assistants") {
                    Link(destination: learnURL) {
                        HStack {
                            Text("Learn about assistants")
                                .foregroundStyle(.colorTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.colorTextTertiary)
                        }
                    }
                }
            } footer: {
                Text("Capabilities, privacy and security")
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationBarTitleDisplayMode(.inline)
        .inviteCodeAlert(
            isPresented: $presentingCodeEntry,
            session: session,
            onUnlocked: {
                defaults.assistantsEnabled = true
                refreshInviteCodeStatus()
            }
        )
        .task {
            refreshInviteCodeStatus()
        }
        .onDisappear {
            inviteCodeStatusTask?.cancel()
        }
    }

    private func refreshInviteCodeStatus() {
        inviteCodeStatusTask?.cancel()
        guard let inviteCode = defaults.assistantInviteCode, !inviteCode.isEmpty else {
            inviteCodeStatus = nil
            return
        }

        inviteCodeStatusTask = Task {
            do {
                let status = try await session.fetchInviteCodeStatus(inviteCode)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    inviteCodeStatus = status
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    inviteCodeStatus = nil
                }
            }
        }
    }

    private func copyInviteCode() {
        guard let inviteCode = inviteCodeStatus?.code else { return }
        UIPasteboard.general.string = inviteCode
        copiedInviteCode = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                copiedInviteCode = false
            }
        }
    }

    private func remainingRedemptionsText(_ remainingRedemptions: Int) -> String {
        if remainingRedemptions == 1 {
            return "1 redemption left"
        }
        return "\(remainingRedemptions) redemptions left"
    }
}

#Preview {
    NavigationStack {
        AssistantSettingsView(session: MockInboxesService())
    }
}
