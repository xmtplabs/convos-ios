import ConvosCore
import SwiftUI

struct ConversationMembersListView: View {
    @Bindable var viewModel: ConversationViewModel

    /// Phase 2.9 stopgap — same resolver pattern as `ConversationView`.
    /// Used to substitute contact-list display names for members whose
    /// per-conversation profile name is empty.
    private var memberNameResolver: MemberNameResolver {
        MemberNameResolver(contactsRepository: viewModel.messagingService.contactsRepository())
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.conversation.members.sortedByRole(), id: \.id) { member in
                    NavigationLink {
                        memberContactCardDestination(for: member)
                    } label: {
                        MemberRow(
                            member: member,
                            displayName: member.displayName(memberNameOverride: memberNameResolver.contactName(for:))
                        )
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

    @ViewBuilder
    private func memberContactCardDestination(for member: ConversationMember) -> some View {
        let messagingService = viewModel.messagingService
        let contactsRepository = messagingService.contactsRepository()
        let contactsWriter = messagingService.contactsWriter()
        let resolvedContact: Contact = {
            if let stored = try? contactsRepository.fetchContact(inboxId: member.profile.inboxId) {
                return stored
            }
            return Contact.synthetic(
                inboxId: member.profile.inboxId,
                displayName: member.profile.displayName,
                avatarURL: member.profile.avatar,
                addedViaConversationId: viewModel.conversation.id,
                agentVerification: member.agentVerification
            )
        }()
        let onRemove: () -> Void = { viewModel.remove(member: member) }
        let onBlockAndLeave: () -> Void = {
            viewModel.blockAndLeaveConvo(inboxId: member.profile.inboxId)
        }
        ContactCardView(
            contact: resolvedContact,
            mode: .scopedToConversation(
                conversationId: viewModel.conversation.id,
                canRemoveMembers: viewModel.canRemoveMembers,
                isCurrentUser: member.isCurrentUser
            ),
            contactsWriter: contactsWriter,
            contactsRepository: contactsRepository,
            session: viewModel.session,
            onRemove: onRemove,
            onBlockAndLeave: onBlockAndLeave
        )
    }
}

private struct MemberRow: View {
    let member: ConversationMember
    /// Pre-resolved name (per-conversation profile → contact-list override
    /// → "Somebody"). Computed by the parent so the row stays a pure
    /// presentation view.
    let displayName: String

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ProfileAvatarView(profile: member.profile, profileImage: nil, useSystemPlaceholder: false, agentVerification: member.agentVerification)
                .frame(width: DesignConstants.ImageSizes.mediumAvatar, height: DesignConstants.ImageSizes.mediumAvatar)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(displayName)
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
        if let agentLabel = agentVerification.roleLabel {
            return agentLabel
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
