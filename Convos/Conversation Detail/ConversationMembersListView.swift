import ConvosCore
import ConvosMetrics
import SwiftUI

struct ConversationMembersListView: View {
    @Bindable var viewModel: ConversationViewModel

    @State private var presentingAddFromContactsPicker: Bool = false
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
    /// "New Agent" builder, presented from here so it stacks on top of the
    /// Members list (itself inside the Info sheet) rather than racing the
    /// chat view's own builder sheet.
    @State private var presentingAgentBuilder: AgentBuilderViewModel?
    /// First-run agents explainer shown before the builder; its "Make an agent"
    /// button sets `pendingAgentBuilderAfterIntro` and the sheet's onDismiss
    /// then opens the builder. Stacks over the Members list like the builder.
    @State private var presentingAgentsIntro: Bool = false
    @State private var pendingAgentBuilderAfterIntro: Bool = false

    /// Same pattern as `ConversationView`. Substitutes contact-list
    /// display names for members whose per-conversation profile name is
    /// empty. Adapted from the unified `contact(for:)` resolver to the
    /// name-only shape ConvosCore's `displayName(memberNameOverride:)`
    /// expects.
    private var contactNameOverride: @Sendable (String) -> String? {
        let resolver: @Sendable (String) -> Contact? = viewModel.messagingService.contactsRepository().contact(for:)
        return { resolver($0)?.displayName }
    }

    /// Opens the agent builder from this view's own `.sheet(item:)` so it
    /// stacks over the Members list (itself inside the Info sheet) -- the chat
    /// view's builder sheet (`viewModel.presentAgentBuilder()`) would present
    /// beneath the still-visible Info sheet. On the first-ever tap, shows the
    /// agents explainer first (local mirror of the chat view's intro flow).
    private func presentAgentBuilderLocally() {
        if viewModel.consumeAgentsIntroGate() {
            presentingAgentsIntro = true
        } else {
            presentingAgentBuilder = viewModel.makeAgentBuilderViewModel()
        }
    }

    var body: some View {
        membersList
            .addFromContactsPicker(
                viewModel: viewModel,
                isPresented: $presentingAddFromContactsPicker,
                onPresentAgentBuilder: presentAgentBuilderLocally
            )
            .sheet(item: $presentingAgentBuilder) { builderViewModel in
                AgentBuilderView(
                    viewModel: builderViewModel,
                    profileSettingsViewModel: .shared
                )
            }
            .selfSizingSheet(isPresented: $presentingAgentsIntro, onDismiss: {
                guard pendingAgentBuilderAfterIntro else { return }
                pendingAgentBuilderAfterIntro = false
                presentingAgentBuilder = viewModel.makeAgentBuilderViewModel()
            }, content: {
                AgentsInfoView(onMakeAgent: { pendingAgentBuilderAfterIntro = true })
                    .padding(.top, 20)
            })
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
                        viewModel.presentingShareView = true
                    },
                    onInviteAgent: presentAgentBuilderLocally,
                    onAddFromContacts: {
                        presentingAddFromContactsPicker = true
                    }
                )
            }
        }
    }

    /// Routes a member-row tap based on whether the row is for the local
    /// user. Tapping your own row opens "My info" via
    /// `viewModel.onProfileSettings()`; tapping someone else's pushes the
    /// contact card. Wrapping each branch as a separate view keeps the
    /// `ForEach` body small enough to stay clear of the type-checker
    /// timeout, and centralises the "no contact card for self" rule.
    @ViewBuilder
    private func memberRowDestination(for member: ConversationMember) -> some View {
        let row = MemberRow(
            member: member,
            displayName: member.displayName(memberNameOverride: contactNameOverride)
        )
        if member.isCurrentUser {
            Button(action: viewModel.onProfileSettings) {
                row
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                memberContactDetailDestination(for: member)
                    .onAppear { reportMemberProfileTap(member) }
            } label: {
                row
            }
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
        ContactDetailView(
            contact: resolvedContact,
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
            onRemove: onRemove
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
