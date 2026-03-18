import ConvosCore
import SwiftUI

struct ConversationMembersListView: View {
    @Bindable var viewModel: ConversationViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.conversation.members.sortedByRole(), id: \.id) { member in
                    NavigationLink {
                        ConversationMemberView(viewModel: viewModel, member: member)
                    } label: {
                        MemberRow(member: member)
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
        }
        .background(.colorBackgroundRaisedSecondary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(viewModel.conversation.membersCountStringCapitalized)
                        .font(.headline)
                    if let assistantString = viewModel.conversation.agentCountString {
                        Text(assistantString)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                AddToConversationMenu(
                    isFull: viewModel.isFull,
                    hasAssistant: viewModel.conversation.hasAgent,
                    isEnabled: true,
                    onConvoCode: {
                        viewModel.presentingShareView = true
                    },
                    onCopyLink: {
                        viewModel.copyInviteLink()
                    },
                    onInviteAssistant: {
                        viewModel.requestAssistantJoin()
                    }
                )
            }
        }
    }
}

private struct MemberRow: View {
    let member: ConversationMember

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ProfileAvatarView(profile: member.profile, profileImage: nil, useSystemPlaceholder: false, isVerifiedAssistant: member.isVerifiedAssistant)
                .frame(width: DesignConstants.ImageSizes.mediumAvatar, height: DesignConstants.ImageSizes.mediumAvatar)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(member.displayName)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                if member.isCurrentUser {
                    Text("You")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            Spacer()

            if let roleLabel = member.roleLabel {
                Text(roleLabel)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .background(.colorTextSecondary.opacity(0.1), in: .capsule)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary.opacity(0.5))
        }
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("member-\(member.id)")
    }
}

private extension ConversationMember {
    var roleLabel: String? {
        if isVerifiedAssistant {
            return "Assistant"
        }
        if isAgent {
            return "Agent"
        }
        switch role {
        case .superAdmin:
            return "Creator"
        case .admin:
            return "Admin"
        case .member:
            return nil
        }
    }
}

#Preview {
    NavigationStack {
        ConversationMembersListView(viewModel: .mock)
    }
}
