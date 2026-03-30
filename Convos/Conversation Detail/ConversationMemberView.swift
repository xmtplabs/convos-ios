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
    }

    private var headerSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: DesignConstants.Spacing.step4x) {
                    ProfileAvatarView(profile: member.profile, profileImage: nil, useSystemPlaceholder: false)
                        .frame(width: 160.0, height: 160.0)

                    VStack(spacing: DesignConstants.Spacing.step2x) {
                        Text(member.profile.displayName.capitalized)
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
            let url = URL(string: "https://convos.org/assistants")
            let action = { if let url { openURL(url) } }
            Button(action: action) {
                cardRow(title: "Get skills")
            }
        } footer: {
            Text("Browse 100+ curated capabilities")
        }

        Section {
            let url = URL(string: "https://learn.convos.org/assistants")
            let action = { if let url { openURL(url) } }
            Button(action: action) {
                cardRow(title: "Learn about assistants")
            }
        } footer: {
            Text("Capabilities, privacy and security")
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
                Text("Dismiss and destroy this assistant")
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
                .confirmationDialog("", isPresented: $presentingBlockConfirmation) {
                    Button("Block and leave", role: .destructive) {
                        viewModel.blockAndLeaveConvo()
                    }
                    Button(role: .cancel) {
                        presentingBlockConfirmation = false
                    }
                }
            } footer: {
                Text("Leave this convo and block this assistant")
            }
        }
    }

    @ViewBuilder
    private var nonAgentSections: some View {
        if !member.isCurrentUser {
            Section {
                let action = { presentingBlockConfirmation = true }
                Button(action: action) {
                    Text("Block")
                        .foregroundStyle(.colorCaution)
                }
                .accessibilityLabel("Block \(member.profile.displayName)")
                .accessibilityIdentifier("block-member-button")
                .confirmationDialog("", isPresented: $presentingBlockConfirmation) {
                    Button("Block and leave", role: .destructive) {
                        viewModel.blockAndLeaveConvo()
                    }
                    Button(role: .cancel) {
                        presentingBlockConfirmation = false
                    }
                }
            } footer: {
                Text("Block \(member.profile.displayName.capitalized) and leave the convo")
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
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .accessibilityLabel("Remove \(member.profile.displayName)")
                    .accessibilityIdentifier("remove-member-button")
                } footer: {
                    Text("Remove \(member.profile.displayName.capitalized) from the convo")
                }
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
            parts.append("IA")
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
}

#Preview {
    ConversationMemberView(viewModel: .mock, member: .mock())
}
