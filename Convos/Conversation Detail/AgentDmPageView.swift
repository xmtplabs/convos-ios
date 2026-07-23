import Combine
import ConvosComposer
import ConvosCore
import SwiftUI

/// The agent-DM page inside `ConversationPager`: the user's private DM with
/// the conversation's agent, rendered as a page of the origin conversation.
/// The DM is a real 2-member conversation (see docs/plans/agent-dms.md); this
/// page binds to it when it exists and creates it lazily on first send.
@MainActor
@Observable
final class AgentDmPageModel {
    private let session: any SessionManagerProtocol
    private let messagingService: any MessagingServiceProtocol
    private let originConversationId: String
    let agentInboxId: String

    private(set) var items: [MessagesListItemType] = []
    private(set) var dmConversationId: String?
    @ObservationIgnored private var listRepository: (any MessagesListRepositoryProtocol)?
    @ObservationIgnored private var writer: (any OutgoingMessageWriterProtocol)?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(
        session: any SessionManagerProtocol,
        messagingService: any MessagingServiceProtocol,
        originConversationId: String,
        agentInboxId: String
    ) {
        self.session = session
        self.messagingService = messagingService
        self.originConversationId = originConversationId
        self.agentInboxId = agentInboxId
        refresh()
    }

    /// Binds to an existing DM if one is already in the local database.
    func refresh() {
        guard dmConversationId == nil else { return }
        let existing = try? session
            .conversationsRepository(for: [.allowed, .unknown])
            .findAgentDm(with: agentInboxId)
        guard let existing else { return }
        bind(to: existing.id)
    }

    func send(text: String) async {
        do {
            if dmConversationId == nil {
                let conversationId = try await AgentDmFlow.startOrFindDm(
                    agentInboxId: agentInboxId,
                    originConversationId: originConversationId,
                    session: session
                )
                bind(to: conversationId)
            }
            try await writer?.send(text: text)
        } catch {
            Log.error("Agent DM send failed: \(error.localizedDescription)")
        }
    }

    private func bind(to conversationId: String) {
        dmConversationId = conversationId
        let listRepo = MessagesListRepository(
            messagesRepository: session.messagesRepository(for: conversationId),
            transcriptRepository: session.voiceMemoTranscriptRepository(),
            hiddenBundleMessagesRepository: session.builderBundleHiddenMessagesRepository(),
            conversationId: conversationId
        )
        listRepository = listRepo
        listRepo.messagesListPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.items = items
            }
            .store(in: &cancellables)
        listRepo.startObserving()
        if let initial = try? listRepo.fetchInitial() {
            items = initial
        }
        writer = messagingService.messageWriter(
            for: conversationId,
            backgroundUploadManager: UnavailableBackgroundUploadManager()
        )
    }
}

struct AgentDmPageView: View {
    @Bindable var viewModel: ConversationViewModel
    let agentInboxId: String

    @State private var model: AgentDmPageModel?
    /// Local focus state, deliberately not shared with the chat composer:
    /// every pager page stays mounted in the paging HStack, so a shared
    /// focus value would fight with the chat page's text field.
    @FocusState private var focusState: MessagesViewInputFocus?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @State private var messageText: String = ""
    @State private var bottomBarHeight: CGFloat = 0.0

    private var agent: ConversationMember? {
        viewModel.conversation.members.first { $0.profile.inboxId == agentInboxId }
    }

    private var agentName: String {
        agent?.profile.displayName ?? "Assistant"
    }

    private var sendButtonEnabled: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            if let model, !model.items.isEmpty {
                messagesBody(model: model)
            } else {
                AgentDmEmptyStateView(agentName: agentName)
            }
        }
        .background(Color.colorBackgroundRaisedSecondary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .onAppear {
            if model == nil {
                model = AgentDmPageModel(
                    session: viewModel.session,
                    messagingService: viewModel.messagingService,
                    originConversationId: viewModel.conversation.id,
                    agentInboxId: agentInboxId
                )
            } else {
                model?.refresh()
            }
        }
    }

    private func handleSendMessage() {
        let text = messageText
        messageText = ""
        guard let model else { return }
        Task { await model.send(text: text) }
    }

    private var composer: some View {
        MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messageText: $messageText,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: sendButtonEnabled,
            focusState: $focusState,
            messagesTextFieldEnabled: true,
            onSendMessage: handleSendMessage,
            onClearInvite: {},
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: 26.0))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            bottomBarHeight = newHeight
        }
    }

    private func messagesBody(model: AgentDmPageModel) -> some View {
        MessagesViewRepresentable(
            conversation: viewModel.conversation,
            messages: model.items,
            invite: .empty,
            onUserInteraction: {},
            hasLoadedAllMessages: false,
            focusCoordinator: focusCoordinator,
            onTapAvatar: { _ in },
            onLoadPreviousMessages: {},
            onTapInvite: { _ in },
            onReaction: { _, _ in },
            onToggleReaction: { _, _ in },
            onTapReactions: { _ in },
            onTapReadReceipts: { _ in },
            onTapThinkingIndicator: { _ in },
            onReply: { _ in },
            onOpenMessageDetail: { _ in },
            contextMenuState: .init(),
            onPhotoDimensionsLoaded: { _, _, _ in },
            onAgentOutOfCredits: {},
            creditsDepleted: false,
            onTapUpdateMember: { _ in },
            onRetryMessage: { _ in },
            onDeleteMessage: { _ in },
            onRetryAgentJoin: {},
            onCopyInviteLink: {},
            onConvoCode: {},
            onInviteAgent: {},
            onRetryTranscript: { _ in },
            profileSheetForMember: { _ in AnyView(EmptyView()) },
            memberContactOverride: { _ in nil },
            isAgentJoinPending: false,
            bottomBarHeight: bottomBarHeight,
            hasBottomBar: true,
            topContentInset: 0.0,
            scrollToBottomTrigger: { _ in },
            messageInputFocusTrigger: { _ in }
        )
        .ignoresSafeArea()
    }
}

/// Empty state for an agent DM with no messages yet: names the space and
/// carries the shared-memory disclosure (docs/plans/agent-dms.md, "shared
/// brain, disclosed").
private struct AgentDmEmptyStateView: View {
    let agentName: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            avatarCircle
            Text("\(agentName) 1:1 chat")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step4x)
            Text("Chat here to work with \(agentName) without blowing up the groupchat.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.step4x)
            Text("This space is not confidential.")
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, DesignConstants.Spacing.step4x)
            Text("\(agentName) can share anything it knows.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.stepX)
            Spacer(minLength: 0)
        }
        .offset(y: -DesignConstants.Spacing.step6x)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .background(.colorBackgroundSurfaceless)
    }

    private var avatarCircle: some View {
        ZStack {
            Circle()
                .fill(Color.colorFillTertiary)
                .frame(width: 64.0, height: 64.0)
            Text(String(agentName.prefix(1)).uppercased())
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
        }
    }
}
