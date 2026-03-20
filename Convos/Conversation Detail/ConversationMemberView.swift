import ConvosCore
import SwiftUI

struct ConversationMemberView: View {
    @Bindable var viewModel: ConversationViewModel
    let member: ConversationMember

    @State private var presentingBlockConfirmation: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        List {
            headerSection

            if member.isAgent {
                agentSections
            } else {
                nonAgentSections
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .alert(
            "Block \(member.profile.displayName) and leave convo?",
            isPresented: $presentingBlockConfirmation
        ) {
            let cancelAction = { presentingBlockConfirmation = false }
            Button("Cancel", role: .cancel, action: cancelAction)
            let confirmAction = { viewModel.blockAndLeaveConvo() }
            Button("Confirm", role: .destructive, action: confirmAction)
        } message: {
            Text("They won't know they're blocked, and you'll leave this conversation so they can't reach you here.")
        }
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
            let action = { openURL(Constant.learnAboutAssistantsURL) }
            Button(action: action) {
                cardRow(title: "Learn about assistants")
            }
        } footer: {
            Text("Capabilities, privacy and security")
                .foregroundStyle(.colorTextSecondary)
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
        static let learnAboutAssistantsURL: URL = URL(string: "https://learn.convos.org/assistants")!
    }
}

#Preview {
    ConversationMemberView(viewModel: .mock, member: .mock())
}
