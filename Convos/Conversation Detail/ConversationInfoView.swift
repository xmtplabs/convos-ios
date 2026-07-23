import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

struct FeatureRowItem<AccessoryView: View>: View {
    let imageName: String?
    let symbolName: String?
    let title: String
    let subtitle: String?
    var iconBackgroundColor: Color = .colorOrange
    var iconForegroundColor: Color = .white
    @ViewBuilder let accessoryView: () -> AccessoryView

    private var hasIcon: Bool {
        imageName != nil || symbolName != nil
    }

    var image: Image? {
        if let imageName {
            Image(imageName)
        } else if let symbolName {
            Image(systemName: symbolName)
        } else {
            nil
        }
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if let image {
                Group {
                    image
                        .font(.headline)
                        .padding(.horizontal, DesignConstants.Spacing.step2x)
                        .padding(.vertical, DesignConstants.Spacing.step3x)
                        .foregroundStyle(iconForegroundColor)
                }
                .frame(width: DesignConstants.Spacing.step10x, height: DesignConstants.Spacing.step10x)
                .background(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .fill(iconBackgroundColor)
                        .aspectRatio(1.0, contentMode: .fit)
                )
            }

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            accessoryView()
        }
    }
}

#Preview {
    FeatureRowItem(imageName: nil, symbolName: "folder", title: "Files & Links", subtitle: "Managed by Agents") {
        EmptyView()
    }
    .padding(DesignConstants.Spacing.step4x)
}

struct ConversationInfoView: View {
    @Bindable var viewModel: ConversationViewModel
    let focusCoordinator: FocusCoordinator

    @State private var connectionsViewModel: ConversationConnectionsViewModel?
    @State private var abilitiesViewModel: ConversationAbilitiesViewModel?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var showingExplodeSheet: Bool = false
    @State private var presentingMailCompose: Bool = false
    @State private var preparingReportIssueEmail: Bool = false
    @State private var reportIssueAttachment: MailComposeView.Attachment?
    @State private var exportLogsTask: Task<URL?, Never>?
    @State private var presentingEditView: Bool = false
    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var presentingShareView: Bool = false
    @State private var presentingAddFromContactsPicker: Bool = false
    /// Invite code scanned from the in-sheet Scan/Invite overlay, parked until
    /// this sheet finishes dismissing so the join sheet (presented by
    /// `ConversationView` beneath) isn't dropped mid-dismissal. Delivered by
    /// `onDisappear` via `deliverPendingScannedCodeIfNeeded`.
    @State private var pendingScannedCode: String?
    @State private var exportedLogsURL: URL?
    @State private var metadataDebugText: String = "Loading…"
    @State private var showingRestoreInviteTagAlert: Bool = false
    @State private var restoreInviteTagText: String = ""
    @State private var showingLeaveConfirmation: Bool = false
    /// "New Agent" builder, presented from here so it stacks on top of the
    /// Info sheet rather than racing the chat view's own builder sheet.
    @State private var presentingAgentBuilder: AgentBuilderViewModel?
    /// First-run agents explainer shown before the builder; its "Make an agent"
    /// button sets `pendingAgentBuilderAfterIntro` and the sheet's onDismiss
    /// then opens the builder.
    @State private var presentingAgentsIntro: Bool = false
    @State private var pendingAgentBuilderAfterIntro: Bool = false
    @State private var navState: ConversationInfoNavigatorImpl = .init()
    @State private var navigator: ConversationInfoCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = ConversationInfoCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func handleEditViewChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.navigateTo(edit: ConversationInfoEditNavigatorArgs(conversationId: viewModel.conversation.id))
    }

    private let maxMembersToShow: Int = 6
    private var displayedMembers: [ConversationMember] {
        let sortedMembers = viewModel.conversation.members.sortedByRole()
        return Array(sortedMembers.prefix(maxMembersToShow))
    }
    private var showViewAllMembers: Bool {
        viewModel.conversation.members.count > maxMembersToShow
    }

    @ViewBuilder
    private var agentSection: some View {
        if viewModel.conversation.hasEverHadVerifiedConvosAgent {
            Section {
                filesAndLinksRow
            }
        }
    }

    private var convoCodeSection: some View {
        Section {
            convoCodeRow

            lockRow
        }
    }

    @ViewBuilder
    private var filesAndLinksRow: some View {
        NavigationLink {
            AgentFilesLinksView(
                conversationId: viewModel.conversation.id,
                repository: viewModel.makeAgentFilesLinksRepository(),
                members: viewModel.conversation.members,
                profileSheetContent: { member in
                    AnyView(MemberContactDetailSheetContent(viewModel: viewModel, member: member, profileSettingsViewModel: .shared))
                }
            )
        } label: {
            FeatureRowItem(
                imageName: nil,
                symbolName: "folder",
                title: "Files & Links",
                subtitle: "Managed by Agents",
                iconBackgroundColor: .colorFillMinimal,
                iconForegroundColor: .colorTextPrimary
            ) {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("files-links-row")
    }

    @ViewBuilder
    private var convoCodeRow: some View {
        if viewModel.isLocked && !viewModel.isCurrentUserSuperAdmin {
            EmptyView()
        } else {
            let isUnavailable = viewModel.isLocked || viewModel.isFull
            let subtitle = if isUnavailable {
                "None"
            } else {
                "\(ConfigManager.shared.currentEnvironment.relyingPartyIdentifier)/\(viewModel.invite.urlSlug)"
            }

            if !isUnavailable, let inviteURL = viewModel.invite.inviteURL {
                ShareLink(item: inviteURL) {
                    convoCodeRowContent(subtitle: subtitle, showShareIcon: true)
                }
                .buttonStyle(.plain)
            } else {
                convoCodeRowContent(subtitle: subtitle, showShareIcon: false)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if viewModel.isFull {
                            showingFullInfo = true
                        }
                    }
                    .opacity(viewModel.isLocked ? 0.5 : 1.0)
            }
        }
    }

    @ViewBuilder
    private func convoCodeRowContent(subtitle: String, showShareIcon: Bool) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Group {
                Image(systemName: "qrcode")
                    .font(.headline)
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .padding(.vertical, 10.0)
                    .foregroundStyle(viewModel.isFull ? .colorTextSecondary : .colorTextPrimary)
            }
            .frame(width: 40.0, height: 40.0)
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                    .fill(Color.colorFillMinimal)
                    .aspectRatio(1.0, contentMode: .fit)
            )

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text("Convo code")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if showShareIcon {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var lockRow: some View {
        if viewModel.isCurrentUserSuperAdmin {
            FeatureRowItem(
                imageName: nil,
                symbolName: "lock.fill",
                title: "Lock",
                subtitle: "Nobody new can join",
                iconBackgroundColor: .colorFillMinimal,
                iconForegroundColor: .colorTextPrimary
            ) {
                Toggle("", isOn: Binding(
                    get: { viewModel.isLocked },
                    set: { _ in
                        showingLockedInfo = true
                    }
                ))
                .labelsHidden()
                .accessibilityLabel("Lock conversation")
                .accessibilityValue(viewModel.isLocked ? "locked" : "unlocked")
                .accessibilityIdentifier("lock-toggle")
            }
        }
    }

    private var headerSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: DesignConstants.Spacing.step4x) {
                    ConversationAvatarView(
                        conversation: viewModel.conversation,
                        conversationImage: viewModel.conversationImage
                    )
                    .frame(width: 160.0, height: 160.0)

                    VStack(spacing: DesignConstants.Spacing.step2x) {
                        Text(viewModel.untitledConversationPlaceholder)
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                            .multilineTextAlignment(.center)
                        if !viewModel.conversationDescription.isEmpty {
                            Text(viewModel.conversationDescription)
                                .font(.subheadline)
                        }

                        Button {
                            presentingEditView = true
                        } label: {
                            Text("Edit info")
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        .buttonStyle(.bordered)
                        .hoverEffect(.lift)
                        .padding(.top, DesignConstants.Spacing.step2x)
                        .accessibilityLabel("Edit conversation info")
                        .accessibilityIdentifier("edit-info-button")
                        .sheet(isPresented: $presentingEditView) {
                            ConversationInfoEditView(viewModel: viewModel, focusCoordinator: focusCoordinator)
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

    private var membersSection: some View {
        Section {
            NavigationLink {
                ConversationMembersListView(viewModel: viewModel)
            } label: {
                HStack {
                    Text(viewModel.conversation.membersCountString)
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    if viewModel.isFull {
                        Text("Full")
                            .foregroundStyle(.colorTextSecondary)
                    } else if viewModel.conversation.members.count > 100 {
                        Text("\(Conversation.maxMembers) max")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
        }
    }

    private var preferencesSection: some View {
        Section {
            FeatureRowItem(
                imageName: nil,
                symbolName: "bell.fill",
                title: "Notifications",
                subtitle: nil
            ) {
                Toggle("", isOn: $viewModel.notificationsEnabled)
                    .labelsHidden()
                    .accessibilityLabel("Notifications")
                    .accessibilityValue(viewModel.notificationsEnabled ? "on" : "off")
                    .accessibilityIdentifier("notifications-toggle")
            }

            FeatureRowItem(
                imageName: nil,
                symbolName: "eye",
                title: "Read receipts",
                subtitle: "Let others know you've read"
            ) {
                Toggle("", isOn: Binding(
                    get: { viewModel.sendReadReceipts },
                    set: { viewModel.setSendReadReceipts($0) }
                ))
                .labelsHidden()
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.setSendReadReceipts(!viewModel.sendReadReceipts)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Read receipts")
            .accessibilityValue(viewModel.sendReadReceipts ? "on" : "off")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("convo-read-receipts-toggle")
        } header: {
            Text("Personal preferences")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
    }

    /// Routes a code scanned from the in-sheet Scan/Invite overlay. The
    /// overlay is shown on this view's local `@State`, but the view model
    /// handler only flips its own flag, so the local overlay is dismissed here
    /// too. A regular invite code then opens the join flow via
    /// `presentingNewConversationForInvite`, whose sheet hangs off
    /// `ConversationView` beneath this sheet and cannot present while the info
    /// sheet is up (setting it mid-dismissal gets dropped by SwiftUI too) --
    /// so the code is parked in `pendingScannedCode`, the info sheet is
    /// dismissed, and `onDisappear` hands the code over once the dismissal has
    /// fully settled. Agent-template codes join in place with no
    /// presentation, so the info sheet stays.
    private func handleOverlayScannedCode(_ code: String) {
        presentingShareView = false
        let isAgentTemplate = URL(string: code).flatMap(DeepLinkHandler.agentTemplateId(from:)) != nil
        guard !isAgentTemplate else {
            viewModel.handleScannedCodeInCurrentConversation(code)
            return
        }
        pendingScannedCode = code
        dismiss()
    }

    /// Hands a parked scanned code to the view model once this sheet has left
    /// the hierarchy, so the resulting join sheet presents cleanly.
    private func deliverPendingScannedCodeIfNeeded() {
        guard let code = pendingScannedCode else { return }
        pendingScannedCode = nil
        viewModel.handleScannedCodeInCurrentConversation(code)
    }

    /// Opens the agent builder from this sheet's own `.sheet(item:)` so it
    /// stacks on top -- the chat view's builder sheet
    /// (`viewModel.presentAgentBuilder()`) would present beneath this
    /// still-visible sheet. On the first-ever tap, shows the agents explainer
    /// first (local mirror of the chat view's intro flow).
    private func presentAgentBuilderLocally() {
        if viewModel.consumeAgentsIntroGate() {
            presentingAgentsIntro = true
        } else {
            presentingAgentBuilder = viewModel.makeAgentBuilderViewModel()
        }
    }

    /// Local share-overlay presentation binding. Resets the requested initial
    /// segment on dismissal (mirroring `ConversationPresenter`'s binding) so
    /// the next plain convo-code open lands on the Invite tab, not a stale
    /// Scan request from the contacts picker.
    private var localShareOverlayBinding: Binding<Bool> {
        Binding(
            get: { presentingShareView },
            set: { newValue in
                presentingShareView = newValue
                if !newValue {
                    viewModel.shareViewInitialSegment = .invite
                }
            }
        )
    }

    var body: some View {
        infoContent
            .addFromContactsPicker(
                viewModel: viewModel,
                isPresented: $presentingAddFromContactsPicker,
                // This view is itself a presented sheet: the presenter-level
                // overlay (viewModel.presentingShareView) would open beneath
                // it, so route the picker's Show-invite-code / Scan rows to
                // the local in-sheet overlay instead.
                onPresentShareOverlay: { presentingShareView = true },
                // Same stacking rule for "Make an agent": the chat view's
                // builder sheet (viewModel.presentingAgentBuilder) would
                // present beneath this sheet, so drive the local one.
                onPresentAgentBuilder: presentAgentBuilderLocally
            )
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
                deliverPendingScannedCodeIfNeeded()
            }
            .onChange(of: presentingEditView) { oldValue, newValue in
                handleEditViewChanged(from: oldValue, to: newValue)
            }
    }

    private var infoList: some View {
        List {
            headerSection

            membersSection

            agentSection

            convoCodeSection

            if viewModel.canRemoveMembers {
                Section {
                    ExplodeInfoRow(
                        scheduledExplosionDate: viewModel.scheduledExplosionDate,
                        onTap: { showingExplodeSheet = true },
                        onExplodeNow: { viewModel.explodeConvo() }
                    )
                }
            }

            preferencesSection

            agentAccessSection

            if viewModel.canLeaveConversation {
                leaveSection
            }

            debugInfoSection
        }
    }

    /// The per-conversation agent access rows: the V2 abilities section
    /// behind the Abilities V2 flag, the V1 connections section otherwise.
    /// The matching view model is prepared in `prepareAgentAccessViewModels`.
    @ViewBuilder
    private var agentAccessSection: some View {
        if viewModel.conversation.hasAgent {
            if let abilitiesViewModel {
                ConversationAbilitiesSection(viewModel: abilitiesViewModel)
            } else if let connectionsViewModel {
                ConversationConnectionsSection(viewModel: connectionsViewModel)
            }
        }
    }

    /// Branches on the current flag value and clears the opposite mode's
    /// view model, so a flag flip while this view identity survives can
    /// never leave both models alive with the stale one rendering.
    private func prepareAgentAccessViewModels() {
        guard viewModel.conversation.hasAgent else { return }
        if FeatureFlags.shared.isAbilitiesV2Enabled {
            connectionsViewModel = nil
            if abilitiesViewModel == nil {
                abilitiesViewModel = makeConversationAbilitiesViewModel()
            }
        } else {
            abilitiesViewModel = nil
            if connectionsViewModel == nil {
                connectionsViewModel = viewModel.makeConversationConnectionsViewModel()
            }
        }
    }

    /// Snapshot of the conversation's agents at construction, mirroring
    /// `makeConversationConnectionsViewModel`; the section is recreated per
    /// conversation-info presentation, so membership changes pick up then.
    private func makeConversationAbilitiesViewModel() -> ConversationAbilitiesViewModel {
        let agents: [ConversationAgentDescriptor] = viewModel.conversation.members
            .filter { $0.isAgent }
            .map { (member: ConversationMember) -> ConversationAgentDescriptor in
                ConversationAgentDescriptor(inboxId: member.profile.inboxId, displayName: member.profile.displayName)
            }
        return ConversationAbilitiesViewModel(
            conversationId: viewModel.conversation.id,
            agents: agents,
            service: AbilitiesServices.shared
        )
    }

    private var leaveSection: some View {
        Section {
            let action = { showingLeaveConfirmation = true }
            Button(action: action) {
                HStack {
                    Text("Leave")
                        .foregroundStyle(.colorCaution)
                    Spacer()
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.colorCaution)
                }
            }
            .accessibilityIdentifier("leave-conversation-button")
        }
    }

    private var navigationBarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .cancel) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isLocked {
                    Button {
                        showingLockedInfo = true
                    } label: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.colorTextSecondary)
                    }
                    .accessibilityLabel("Conversation locked")
                    .accessibilityIdentifier("info-lock-button")
                } else {
                    AddToConversationMenu(
                        isFull: viewModel.isFull,
                        isEnabled: true,
                        onConvoCode: {
                            if viewModel.isFull {
                                showingFullInfo = true
                            } else {
                                presentingShareView = true
                            }
                        },
                        onInviteAgent: presentAgentBuilderLocally,
                        onAddFromContacts: {
                            presentingAddFromContactsPicker = true
                        }
                    )
                    .accessibilityIdentifier("info-add-button")
                }
            }
        }
    }

    private var infoContent: some View {
        NavigationStack {
            infoList
                .task {
                    prepareAgentAccessViewModels()
                }
                .alert("Restore invite tag", isPresented: $showingRestoreInviteTagAlert) {
                    TextField("Invite tag", text: $restoreInviteTagText)
                    Button("Cancel", role: .cancel) {
                        restoreInviteTagText = ""
                    }
                    Button("Restore") {
                        let expectedTag = restoreInviteTagText
                        restoreInviteTagText = ""
                        Task {
                            do {
                                try await viewModel.restoreInviteTagIfMissing(expectedTag)
                                metadataDebugText = await viewModel.conversationMetadataDebugText()
                            } catch {
                                let refreshedDebugText = await viewModel.conversationMetadataDebugText()
                                metadataDebugText = "Restore failed: \(error.localizedDescription)\n\n\(refreshedDebugText)"
                            }
                        }
                    }
                } message: {
                    Text("Only use this if you know the expected invite tag for this convo.")
                }
                .alert("Leave conversation?", isPresented: $showingLeaveConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Leave", role: .destructive) {
                        viewModel.leaveGroupConvo()
                    }
                } message: {
                    Text("You'll be removed from this conversation and stop receiving its messages.")
                }
                .scrollContentBackground(.hidden)
                .background(.colorBackgroundRaisedSecondary)
                .toolbarTitleDisplayMode(.inline)
                .toolbar { navigationBarContent }
                .selfSizingSheet(isPresented: $showingLockedInfo) {
                    LockedConvoInfoView(
                        isCurrentUserSuperAdmin: viewModel.isCurrentUserSuperAdmin,
                        isLocked: viewModel.isLocked,
                        onLock: {
                            viewModel.toggleLock()
                            showingLockedInfo = false
                        },
                        onDismiss: {
                            showingLockedInfo = false
                        }
                    )
                }
                .selfSizingSheet(isPresented: $showingFullInfo) {
                    FullConvoInfoView(onDismiss: {
                        showingFullInfo = false
                    })
                }
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
                .overlay {
                    if presentingShareView {
                        ConversationShareOverlay(
                            conversation: viewModel.conversation,
                            invite: viewModel.invite,
                            isPresented: localShareOverlayBinding,
                            topSafeAreaInset: 0,
                            coreActions: viewModel.coreActions,
                            // Honors the segment the contacts picker's rows
                            // request (Show invite code -> .invite, Scan ->
                            // .scan); the toolbar convo-code path leaves the
                            // view model default (.invite) untouched.
                            initialSegment: viewModel.shareViewInitialSegment,
                            onScannedCode: { code in
                                handleOverlayScannedCode(code)
                            }
                        )
                    }
                }
                .background {
                    Color.clear
                        .fullScreenCover(isPresented: $showingExplodeSheet) {
                            ExplodeConvoSheet(
                                isScheduled: viewModel.scheduledExplosionDate != nil,
                                onSchedule: { date in
                                    viewModel.scheduleExplosion(at: date)
                                    showingExplodeSheet = false
                                },
                                onExplodeNow: {
                                    viewModel.explodeConvo()
                                },
                                onDismiss: {
                                    showingExplodeSheet = false
                                }
                            )
                            .presentationBackground(.clear)
                        }
                        .transaction { transaction in
                            transaction.disablesAnimations = true
                        }
                }
        }
    }
}

// MARK: - Support and debug section

extension ConversationInfoView {
    // The support rows ship in every environment so production users can
    // send on-device diagnostics to support; the remaining rows are internal
    // debugging tools and stay out of production builds.
    @ViewBuilder
    private var debugInfoSection: some View {
        let isProduction = ConfigManager.shared.currentEnvironment.isProduction
        Section {
            if !isProduction {
                internalDebugRows
            }
            reportIssueRow
            shareLogsRow
        } header: {
            Text("Support")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
        .task {
            await prepareExportedLogs()
        }
    }

    @ViewBuilder
    private var internalDebugRows: some View {
        HStack {
            Text("Fork status")
            Spacer()
            Text(viewModel.conversation.debugInfo.commitLogForkStatus.rawValue)
                .foregroundStyle(.colorTextSecondary)
        }
        HStack {
            Text("Epoch")
            Spacer()
            Text("\(viewModel.conversation.debugInfo.epoch)")
                .foregroundStyle(.colorTextSecondary)
        }
        NavigationLink {
            DebugLogsTextView(logs: viewModel.conversation.debugInfo.forkDetails)
        } label: {
            Text("Fork details")
        }
        NavigationLink {
            DebugLogsTextView(logs: viewModel.conversation.debugInfo.localCommitLog)
        } label: {
            Text("Local commit log")
        }
        NavigationLink {
            DebugLogsTextView(logs: viewModel.conversation.debugInfo.remoteCommitLog)
        } label: {
            Text("Remote commit log")
        }
        NavigationLink {
            DebugLogsTextView(logs: metadataDebugText)
                .task {
                    metadataDebugText = await viewModel.conversationMetadataDebugText()
                }
        } label: {
            Text("Metadata")
        }
        NavigationLink {
            MigrationCapabilitiesView(
                loadDebugText: { await viewModel.membershipCapabilitiesDebugText() },
                enableProposals: { force, minVersion in
                    await viewModel.enableProposals(force: force, minVersion: minVersion)
                }
            )
        } label: {
            Text("Migration capabilities")
        }
        NavigationLink {
            HiddenMessagesView { try await viewModel.hiddenMessagesDebugInfo() }
        } label: {
            Text("Hidden messages")
        }
        Button {
            showingRestoreInviteTagAlert = true
        } label: {
            Text("Restore invite tag")
        }
    }

    @ViewBuilder
    private var reportIssueRow: some View {
        Button {
            reportIssue()
        } label: {
            HStack {
                Text("Report an issue")
                    .foregroundStyle(.colorTextPrimary)
                Spacer()
                if preparingReportIssueEmail {
                    ProgressView()
                } else {
                    Image(systemName: "envelope")
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        }
        .accessibilityIdentifier("report-issue-button")
        .sheet(isPresented: $presentingMailCompose) {
            MailComposeView(
                recipients: [Constant.supportEmail],
                subject: Constant.supportEmailSubject,
                attachment: reportIssueAttachment
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var shareLogsRow: some View {
        if let url = exportedLogsURL {
            ShareLink(item: url) {
                HStack {
                    Text("Share logs")
                        .foregroundStyle(.colorTextPrimary)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Text("Preparing logs…")
                Spacer()
                ProgressView()
            }
            .foregroundStyle(.colorTextSecondary)
        }
    }

    private func reportIssue() {
        guard !preparingReportIssueEmail else { return }
        guard MailComposeView.canSendMail else {
            // No mail account configured for the system compose sheet: fall
            // back to a mailto: draft, which cannot carry the logs attachment.
            let subject = Constant.supportEmailSubject
            let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
            guard let url = URL(string: "mailto:\(Constant.supportEmail)?subject=\(encodedSubject)") else { return }
            openURL(url)
            return
        }
        preparingReportIssueEmail = true
        Task {
            reportIssueAttachment = await loadReportIssueAttachment()
            preparingReportIssueEmail = false
            presentingMailCompose = true
        }
    }

    /// Waits for the log export if it is still running, then reads the
    /// bundle into memory off the main thread so presenting the compose
    /// sheet doesn't stall on a large file read.
    private func loadReportIssueAttachment() async -> MailComposeView.Attachment? {
        guard let url = await exportedLogsURLAwaitingExport() else { return nil }
        let task = Task.detached { MailComposeView.Attachment(contentsOf: url) }
        return await task.value
    }

    private func exportedLogsURLAwaitingExport() async -> URL? {
        if let exportedLogsURL { return exportedLogsURL }
        if let exportLogsTask { return await exportLogsTask.value }
        // The section's export task hasn't started yet; run it directly.
        return try? await viewModel.exportDebugLogs()
    }

    private func prepareExportedLogs() async {
        let task = Task { () -> URL? in
            do {
                return try await viewModel.exportDebugLogs()
            } catch {
                Log.error("Failed to export logs for conversation: \(error.localizedDescription)")
                return nil
            }
        }
        exportLogsTask = task
        exportedLogsURL = await task.value
    }

    private enum Constant {
        static let supportEmail: String = "hi@convos.org"
        static let supportEmailSubject: String = "I'm reporting an issue"
    }
}

struct DebugLogsTextView: View {
    let logs: String
    var body: some View {
        VStack {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(logs)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding()
                            .id("logs")
                    }
                    .onChange(of: logs) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("logs", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private func makeConversationInfoPreviewViewModel() -> ConversationViewModel {
    .mock
}

#Preview {
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    ConversationInfoView(viewModel: makeConversationInfoPreviewViewModel(), focusCoordinator: focusCoordinator)
}
