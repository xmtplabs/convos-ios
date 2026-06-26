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
    @State private var exportedLogsURL: URL?
    @State private var metadataDebugText: String = "Loading…"
    @State private var showingRestoreInviteTagAlert: Bool = false
    @State private var restoreInviteTagText: String = ""
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

    var body: some View {
        infoContent
            .addFromContactsPicker(
                viewModel: viewModel,
                isPresented: $presentingAddFromContactsPicker
            )
            .onAppear {
                ensureNavigator()
                navState.markScreenAppeared()
            }
            .onDisappear {
                navigator?.closed(context: navState.closeContext())
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

            if viewModel.conversation.hasAgent,
               let connectionsViewModel {
                ConversationConnectionsSection(viewModel: connectionsViewModel)
            }

            debugInfoSection
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
                        onInviteAgent: {
                            if viewModel.consumeAgentsIntroGate() {
                                presentingAgentsIntro = true
                            } else {
                                presentingAgentBuilder = viewModel.makeAgentBuilderViewModel()
                            }
                        },
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
                    if viewModel.conversation.hasAgent, connectionsViewModel == nil {
                        connectionsViewModel = viewModel.makeConversationConnectionsViewModel()
                    }
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
                            isPresented: $presentingShareView,
                            topSafeAreaInset: 0,
                            coreActions: viewModel.coreActions
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
