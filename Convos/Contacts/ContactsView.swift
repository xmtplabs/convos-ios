import ConvosCore
import ConvosMetrics
import SwiftUI

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel
    @State private var presentingPicker: Bool = false
    @State private var presentingNewConvo: NewConversationViewModel?
    /// Retains the presented new-conversation VM so its empty-invite teardown
    /// can run on sheet dismiss (`presentingNewConvo` is already nil by then).
    @State private var dismissedNewConvo: NewConversationViewModel?
    /// Claimed warm-cache conversation (mode `.newConversation`, which already
    /// has an invite) backing the "Invite a new contact" top-three. Minted on
    /// appear exactly like `ConversationsViewModel.onStartConvo` does for the
    /// compose flow, so "Show an invite code" / "Send an invite" can read the
    /// same `conversation` + signed `invite` the in-convo share flow uses,
    /// without first navigating into a conversation.
    @State private var inviteConversationViewModel: NewConversationViewModel?
    @State private var presentingInviteShareSheet: Bool = false

    private let contactsRepository: any ContactsRepositoryProtocol
    private let contactsWriter: any ContactsWriterProtocol
    private let session: (any SessionManagerProtocol)?
    private let coreActions: any CoreActions
    private let profileSettingsViewModel: ProfileSettingsViewModel
    /// Whether to render the contacts-scoped compose button. The Contacts
    /// tab hides it because the shell's shared toolbar already provides a
    /// compose button (whose `onStartConvo` opens the same contacts picker),
    /// so the tab's top bar matches Chats and Things exactly.
    private let showsComposeButton: Bool
    /// Optional request from the shell to scroll the list to a given section
    /// id once it appears. Used by the "See suggested agents" button in the
    /// empty Things state; consumed (set back to nil) after the scroll lands.
    private let scrollTarget: Binding<String?>?
    /// Launches the agent builder for the "Make an agent" top-three action.
    /// Make-agent presents from the shell (`MainTabView`), which can't be
    /// presented from under this tab's stack, so the shell injects a closure
    /// that calls `ConversationsViewModel.onStartAgent()`. Nil hides the row.
    private let onMakeAgent: (() -> Void)?

    init(
        contactsRepository: any ContactsRepositoryProtocol,
        contactsWriter: any ContactsWriterProtocol = MockContactsWriter(),
        session: (any SessionManagerProtocol)? = nil,
        coreActions: any CoreActions = NoOpCoreActions(),
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        showsComposeButton: Bool = true,
        suggestedAgentsService: (any SuggestedAgentsServiceProtocol)? = nil,
        scrollTarget: Binding<String?>? = nil,
        onMakeAgent: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: ContactsViewModel(
            contactsRepository: contactsRepository,
            suggestedAgentsService: suggestedAgentsService
        ))
        self.contactsRepository = contactsRepository
        self.contactsWriter = contactsWriter
        self.session = session
        self.coreActions = coreActions
        self.profileSettingsViewModel = profileSettingsViewModel
        self.showsComposeButton = showsComposeButton
        self.scrollTarget = scrollTarget
        self.onMakeAgent = onMakeAgent
    }

    var body: some View {
        contactsContent
        .task { await viewModel.loadSuggestedAgentsIfNeeded() }
        .onAppear(perform: claimInviteConversationIfNeeded)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.colorBackgroundRaisedSecondary
                .ignoresSafeArea()
        }
        // The nav bar is forced to inline mode with a hidden background so
        // only the toolbar items remain visible at the top and the list
        // scrolls behind it with the iOS 26 glass blur, matching the
        // `safeAreaBar` treatment applied to the search bar below.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarContent }
        .navigationDestination(for: Contact.self) { contact in
            contactDetail(for: contact)
        }
        .sheet(isPresented: $presentingPicker) { pickerSheet }
        .sheet(item: $presentingNewConvo, onDismiss: cleanUpDismissedNewConvo) { vm in
            NewConversationView(
                viewModel: vm,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .background(.colorBackgroundSurfaceless)
        }
        .shareSheet(
            isPresented: $presentingInviteShareSheet,
            items: inviteShareItems
        )
    }

    // MARK: - List

    /// Same `safeAreaBar` treatment the contacts picker and chat
    /// composer use. The search bar floats at the top with iOS 26 glass
    /// blur, and the underlying list's scroll inset is auto-adjusted so
    /// rows scroll cleanly under the bar. Wrapped in a `ScrollViewReader`
    /// so the shell can scroll the list to a section (see `scrollTarget`).
    @ViewBuilder
    private var contactsContent: some View {
        ScrollViewReader { proxy in
            listOrFilteredEmptyState
                .background(.colorBackgroundRaisedSecondary)
                .safeAreaBar(edge: .top) {
                    ContactsSearchBar(
                        query: $viewModel.searchQuery,
                        placeholder: "People and agents",
                        accessibilityIdentifier: "contacts-search-field",
                        filter: $viewModel.filter,
                        showBlocked: $viewModel.showBlocked
                    )
                }
                .onChange(of: incomingScrollTarget) { _, target in
                    handleScrollTargetChange(target, proxy: proxy)
                }
                .onChange(of: sectionIDs, initial: true) { _, _ in
                    scrollToTargetIfPresent(incomingScrollTarget, proxy: proxy)
                }
        }
    }

    /// Shows the filtered empty state when a search or filter matches nothing
    /// (keeping the search bar above so the user can clear it), a spinner while
    /// the suggested-agents first page is in flight for a user with no
    /// contacts, and otherwise the contacts list. There is no full-screen
    /// onboarding empty state: with zero saved contacts the list simply renders
    /// the suggested-agents section.
    @ViewBuilder
    private var listOrFilteredEmptyState: some View {
        if viewModel.sections.isEmpty {
            if viewModel.isFiltering {
                filteredEmptyState
            } else if viewModel.isLoadingSuggestedAgents {
                loadingState
            } else {
                Color.colorBackgroundRaisedSecondary
            }
        } else {
            contactList
        }
    }

    private var filteredEmptyState: some View {
        VStack {
            Spacer()
            FilteredEmptyStateView(
                message: "No contacts",
                accessibilityLabel: "Show all contacts"
            ) {
                viewModel.clearFilters()
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll to section

    /// The section id the shell has asked us to scroll to, if any.
    private var incomingScrollTarget: String? {
        scrollTarget.flatMap(\.wrappedValue)
    }

    /// Section ids in render order. Watched so a pending scroll request can
    /// fire once an async-loaded section (e.g. suggested agents) appears.
    private var sectionIDs: [String] {
        viewModel.sections.map(\.id)
    }

    /// Reacts to a new scroll request from the shell. For the suggested-agents
    /// target, first clears any filter/search that would keep the section
    /// hidden, then scrolls if it's already present; otherwise the `sectionIDs`
    /// handler scrolls once the section loads.
    private func handleScrollTargetChange(_ target: String?, proxy: ScrollViewProxy) {
        guard let target else { return }
        if target == SuggestedAgentsSection.id {
            if !viewModel.filter.includesAgents { viewModel.filter = .all }
            if !viewModel.searchQuery.isEmpty { viewModel.searchQuery = "" }
        }
        scrollToTargetIfPresent(target, proxy: proxy)
    }

    /// Scrolls to `target` when a matching section exists, then clears the
    /// request. Deferred one runloop hop so a freshly-inserted section is laid
    /// out before the scroll.
    private func scrollToTargetIfPresent(_ target: String?, proxy: ScrollViewProxy) {
        guard let target, viewModel.sections.contains(where: { $0.id == target }) else { return }
        Task { @MainActor in
            withAnimation { proxy.scrollTo(target, anchor: .top) }
            scrollTarget?.wrappedValue = nil
        }
    }

    @ViewBuilder
    private var contactList: some View {
        ContactsListView(
            sections: viewModel.sections.map { section in
                ContactsListSection(
                    id: section.id,
                    title: section.title,
                    rows: section.rows
                )
            },
            rowContent: { (row: ContactsViewModel.Row) in
                contactRow(for: row)
            },
            sectionHeader: { (section: ContactsListSection<ContactsViewModel.Row>) in
                contactsSectionHeader(for: section)
            },
            leadingContent: inviteActionsContent,
            listBackground: { Color.colorBackgroundRaisedSecondary }
        )
    }

    /// The "Invite a new contact" top-three, pinned above the contacts list
    /// (same `leadingContent` slot the compose picker uses). Hidden while the
    /// user is narrowing the list with a search or filter so results read
    /// cleanly. Reuses `ContactsPickerActionsSection` / `ContactsPickerActionRow`.
    private var inviteActionsContent: AnyView? {
        guard !viewModel.isFiltering, let actions = inviteActions else { return nil }
        return AnyView(
            ContactsPickerActionsSection(actions: actions, headerTitle: "Invite a new contact")
        )
    }

    /// Bundles the available top-three closures. "Show an invite code" and
    /// "Send an invite" appear once the claimed conversation's invite has
    /// hydrated; "Make an agent" only when the shell injected a launcher.
    private var inviteActions: ContactsPickerActions? {
        let hasInvite: Bool = invite != nil
        var showInviteCode: (() -> Void)?
        var sendInvite: (() -> Void)?
        if hasInvite {
            showInviteCode = handleShowInviteCode
            sendInvite = handleSendInvite
        }
        guard showInviteCode != nil || sendInvite != nil || onMakeAgent != nil else { return nil }
        return ContactsPickerActions(
            onShowInviteCode: showInviteCode,
            onSendInvite: sendInvite,
            onMakeAgent: onMakeAgent
        )
    }

    @ViewBuilder
    private func contactRow(for row: ContactsViewModel.Row) -> some View {
        NavigationLink(value: row.contact) {
            ContactRowView(contact: row.contact, subtitle: row.subtitle)
        }
        .onAppear {
            guard row.isSuggestedAgent else { return }
            let rowId = row.id
            Task { await viewModel.suggestedAgentRowAppeared(id: rowId) }
        }
    }

    @ViewBuilder
    private func contactsSectionHeader(for section: ContactsListSection<ContactsViewModel.Row>) -> some View {
        if section.id == SuggestedAgentsSection.id {
            SuggestedAgentsSectionHeader()
        } else {
            ContactsListSectionHeader(title: section.title)
        }
    }

    /// Detail pushed when a contact row is tapped. Built here (rather than
    /// inline in the row) so navigation is value-based -- the host lifts the
    /// stack path to know when a detail is on screen.
    @ViewBuilder
    private func contactDetail(for contact: Contact) -> some View {
        ContactDetailView(
            contact: contact,
            contactsWriter: contactsWriter,
            contactsRepository: contactsRepository,
            session: session,
            coreActions: coreActions,
            profileSettingsViewModel: profileSettingsViewModel,
            showsCloseButton: false,
            pushedConversationInsetsTopSafeArea: true
        )
    }

    /// Shown while the suggested-agents first page is in flight and the user
    /// has no contacts yet, so the list area doesn't flash empty before the
    /// suggestions arrive.
    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.colorBackgroundRaisedSecondary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsComposeButton {
            ToolbarItem(placement: .topBarTrailing) {
                let canCompose = session != nil && viewModel.contactCount > 0
                Button(action: presentPicker) {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!canCompose)
                .accessibilityLabel("Start a new conversation from contacts")
                .accessibilityIdentifier("contacts-compose-button")
            }
        }
    }

    // MARK: - Picker sheet

    @ViewBuilder
    private var pickerSheet: some View {
        ContactsPickerView(
            mode: .newConversation,
            contactsRepository: contactsRepository,
            suggestedAgentsService: SuggestedAgentsService.live(),
            onConfirm: handlePickerConfirm
        )
    }

    // MARK: - Invite a new contact

    /// The signed per-conversation invite for the claimed conversation, the
    /// same one the in-convo share flow reads. Nil until the invite hydrates.
    private var invite: Invite? {
        let invite = inviteConversationViewModel?.conversationViewModel?.invite
        guard let invite, !invite.isEmpty else { return nil }
        return invite
    }

    private var inviteShareItems: [Any] {
        guard let invite else { return [] }
        return [invite.inviteURLString]
    }

    /// Mints the claimed conversation once per appearance of the tab, mirroring
    /// `ConversationsViewModel.onStartConvo`. Requires a live session; with the
    /// mock session used in previews this is a no-op so the rows stay hidden.
    private func claimInviteConversationIfNeeded() {
        guard inviteConversationViewModel == nil, let session else { return }
        inviteConversationViewModel = NewConversationViewModel(
            session: session,
            mode: .newConversation,
            showsEmbeddedInvite: true,
            coreActions: coreActions
        )
    }

    /// Enters the claimed conversation as a full new-conversation sheet so the
    /// user lands inside a fresh chat with the invite QR at the top (the
    /// standard message-list header), mirroring the "Skip" path in
    /// `ConversationsViewModel.onStartConvo`. The just-entered VM is handed off
    /// and a fresh claimed conversation is minted so the top-three rows keep
    /// working for the next invite.
    private func handleShowInviteCode() {
        guard invite != nil, let enteredViewModel = inviteConversationViewModel else { return }
        inviteConversationViewModel = nil
        dismissedNewConvo = enteredViewModel
        presentingNewConvo = enteredViewModel
        claimInviteConversationIfNeeded()
    }

    /// Runs the empty-invite teardown for a dismissed new-conversation sheet so
    /// a "Show an invite code" convo the user closed without messaging or
    /// adding anyone doesn't linger in the chats list. A no-op for convos that
    /// gained messages / members, or for the picker-confirm path (those aren't
    /// embedded-invite convos).
    private func cleanUpDismissedNewConvo() {
        dismissedNewConvo?.cleanUpEmptyEmbeddedInviteIfNeeded()
        dismissedNewConvo = nil
    }

    /// Pops the native share sheet directly with the invite link -- no
    /// intermediate screen, unlike the in-convo flow which routes through the
    /// Scan/Invite screen first.
    private func handleSendInvite() {
        guard invite != nil else { return }
        presentingInviteShareSheet = true
    }

    // MARK: - Actions

    private func presentPicker() {
        presentingPicker = true
    }

    /// Spins up a `NewConversationViewModel` locally and presents it as a
    /// sheet from this view, so the new conversation appears in place of
    /// the picker while the App Settings sheet stack stays alive
    /// underneath. Dismissing the new-convo sheet lands the user back on
    /// the contacts list, not at the root conversations list. Mirrors the
    /// invite-cell-tap pattern (`presentingNewConversationForInvite` on
    /// `ConversationViewModel`) where the sheet is owned by the same view
    /// that hosted the picker.
    private func handlePickerConfirm(_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) {
        guard !memberInboxIds.isEmpty || !agentTemplateIds.isEmpty, let session else { return }
        let viewModel = NewConversationViewModel(
            session: session,
            mode: .newConversationWithMembers(
                initialMemberInboxIds: Array(memberInboxIds),
                initialAgentTemplateIds: agentTemplateIds
            ),
            coreActions: coreActions
        )
        dismissedNewConvo = viewModel
        presentingNewConvo = viewModel
    }
}

#Preview("With Contacts") {
    NavigationStack {
        ContactsView(contactsRepository: MockContactsRepository())
    }
}

#Preview("Empty") {
    NavigationStack {
        ContactsView(contactsRepository: MockContactsRepository(contacts: []))
    }
}
