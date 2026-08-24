import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

struct ConversationMembersListView: View {
    @Bindable var viewModel: ConversationViewModel

    @State private var presentingAddFromContactsPicker: Bool = false
    /// Drives the system share sheet behind the menu's "Invite friends" row.
    @State private var presentingInviteShareSheet: Bool = false

    /// This conversation's signed invite link. Empty until the invite
    /// hydrates, which is also when there is nothing to share.
    private var inviteShareItems: [Any] {
        let invite = viewModel.invite
        guard !invite.isEmpty else { return [] }
        return [invite.inviteURLString]
    }
    @State private var navState: MembersListNavigatorImpl = .init()
    @State private var navigator: MembersListCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = MembersListCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func reportMemberProfileTap(_ member: ConversationMember) {
        navigator?.navigateTo(
            memberProfile: MemberProfileNavigatorArgs(
                conversationId: viewModel.conversation.id,
                memberId: member.profile.inboxId
            )
        )
    }

    /// Same pattern as `ConversationView`. Substitutes contact-list
    /// display names for members whose per-conversation profile name is
    /// empty. Adapted from the unified `contact(for:)` resolver to the
    /// name-only shape ConvosCore's `displayName(memberNameOverride:)`
    /// expects.
    private var contactNameOverride: @Sendable (String) -> String? {
        let resolver: @Sendable (String) -> Contact? = viewModel.messagingService.contactsRepository().contact(for:)
        return { resolver($0)?.displayName }
    }

    var body: some View {
        membersList
            .addFromContactsPicker(
                viewModel: viewModel,
                isPresented: $presentingAddFromContactsPicker
            )
            .shareSheet(
                isPresented: $presentingInviteShareSheet,
                items: inviteShareItems
            )
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
            }
    }

    private var membersList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.conversation.members.sortedByRole(), id: \.id) { member in
                    memberRowDestination(for: member)
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
                    if let agentString = viewModel.conversation.agentCountString {
                        Text(agentString)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                AddToConversationMenu(
                    isFull: viewModel.isFull,
                    isEnabled: true,
                    onConvoCode: {
                        presentingInviteShareSheet = true
                    },
                    onAddFromContacts: {
                        presentingAddFromContactsPicker = true
                    }
                )
            }
        }
    }

    /// Routes every member-row tap to the canonical contact card. The current
    /// user's row deliberately takes the same path as everyone else's:
    /// current-user mode keeps self-only actions safe while showing the
    /// connected-agent social profile and its visibility controls.
    @ViewBuilder
    private func memberRowDestination(for member: ConversationMember) -> some View {
        let row = MemberRow(
            member: member,
            displayName: member.displayName(memberNameOverride: contactNameOverride)
        )
        NavigationLink {
            memberContactDetailDestination(for: member)
                .onAppear { reportMemberProfileTap(member) }
        } label: {
            row
        }
    }

    @ViewBuilder
    private func memberContactDetailDestination(for member: ConversationMember) -> some View {
        let messagingService = viewModel.messagingService
        let contactsRepository = messagingService.contactsRepository()
        let contactsWriter = messagingService.contactsWriter()
        let resolvedContact = Contact.resolved(
            member: member,
            in: viewModel.conversation.id,
            contactsRepository: contactsRepository
        )
        let onRemove: () -> Void = { viewModel.remove(member: member) }
        let onStartAgentDm: (String) -> Void = { agentInboxId in
            viewModel.presentingConversationSettings = false
            NotificationCenter.default.post(
                name: .selectAgentDmPageRequested,
                object: nil,
                userInfo: [
                    "conversationId": viewModel.conversation.id,
                    "agentInboxId": agentInboxId,
                ]
            )
        }
        ContactDetailView(
            contact: resolvedContact,
            connectedAgentProviderIds: member.profile.connectedAgentProviderIds,
            groupAgentSetUpByContact: viewModel.conversation.groupAgentSetUp(
                by: member.profile.inboxId
            ),
            mode: .scopedToConversation(
                conversationId: viewModel.conversation.id,
                canRemoveMembers: viewModel.canRemoveMembers,
                isCurrentUser: member.isCurrentUser,
                invitedBy: member.invitedBy,
                joinedAt: member.joinedAt
            ),
            contactsWriter: contactsWriter,
            contactsRepository: contactsRepository,
            session: viewModel.session,
            coreActions: viewModel.coreActions,
            showsCloseButton: false,
            onRemove: onRemove,
            onStartAgentDm: onStartAgentDm
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
                RoleLabelPill(label: roleLabel)
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

@MainActor
private func makeMembersListPreviewViewModel() -> ConversationViewModel {
    .mock
}

#Preview {
    NavigationStack {
        ConversationMembersListView(viewModel: makeMembersListPreviewViewModel())
    }
}
