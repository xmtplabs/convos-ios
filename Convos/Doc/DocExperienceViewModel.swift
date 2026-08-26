import Combine
import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import Foundation

enum DocPreviewStage: String {
    case welcome
    case connect
    case empty
    case cards

    static var current: DocPreviewStage? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-DocPreviewState"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        return DocPreviewStage(rawValue: arguments[flagIndex + 1])
    }
}

@MainActor @Observable
final class DocExperienceViewModel {
    private(set) var conversationViewModel: NewConversationViewModel?
    private(set) var agentDmSession: AgentDmSession?
    private(set) var state: DocState?
    private(set) var pendingScreenshotCount: Int = 0
    var isPresentingGoogleConnect: Bool = false
    var isPresentingHistory: Bool = false
    var hasCompletedWelcome: Bool

    let previewStage: DocPreviewStage?

    @ObservationIgnored private let session: any SessionManagerProtocol
    @ObservationIgnored private let coreActions: any CoreActions
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var messagesCancellable: AnyCancellable?
    @ObservationIgnored private var observedDmConversationId: String?
    @ObservationIgnored private var latestStateMessageId: String?
    @ObservationIgnored private var stateMessageIdAtLastSend: String?

    init(
        session: any SessionManagerProtocol,
        coreActions: any CoreActions,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.coreActions = coreActions
        self.defaults = defaults
        self.previewStage = DocPreviewStage.current
        self.hasCompletedWelcome = defaults.bool(forKey: Self.key("welcome", session: session))

        if previewStage == .cards {
            state = Self.previewState
        } else if previewStage == nil,
                  let data = defaults.data(forKey: Self.key("state", session: session)) {
            state = try? JSONDecoder().decode(DocState.self, from: data)
        }
    }

    var docs: [DocStatus] {
        (state?.docs ?? []).sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var agentInboxId: String? {
        originViewModel?.conversation.members.first(where: \.isAgent)?.profile.inboxId
    }

    var agentBindingKey: String {
        let originId = originViewModel?.conversation.id ?? "waiting"
        return "\(originId)|\(agentInboxId ?? "waiting")"
    }

    var dmViewModel: ConversationViewModel? {
        agentDmSession?.dmViewModel
    }

    var isPreparingAgent: Bool {
        previewStage == nil && hasCompletedWelcome && dmViewModel == nil
    }

    var googleConnectConversation: Conversation? {
        dmViewModel?.conversation
    }

    private var originViewModel: ConversationViewModel? {
        conversationViewModel?.conversationViewModel
    }

    func completeWelcome() {
        hasCompletedWelcome = true
        guard previewStage == nil else { return }
        defaults.set(true, forKey: Self.key("welcome", session: session))
        Task { await startAgentIfNeeded() }
    }

    func startAgentIfNeeded() async {
        guard previewStage == nil, hasCompletedWelcome, conversationViewModel == nil else { return }

        let storedId = defaults.string(forKey: Self.key("originConversationId", session: session))
        let conversations = try? await session
            .conversationsRepository(for: [.allowed, .unknown])
            .fetchAll()
        let existingId = storedId.flatMap { id in
            conversations?.contains(where: { $0.id == id }) == true ? id : nil
        }
        let mode: NewConversationMode = if let existingId {
            .existingConversation(conversationId: existingId)
        } else {
            .newConversation
        }

        conversationViewModel = NewConversationViewModel(
            session: session,
            mode: mode,
            coreActions: coreActions,
            agentVariantSlug: FeatureFlags.shared.effectiveAgentVariantSlug
        )
    }

    func synchronizeAgentDm() async {
        guard previewStage == nil, let originViewModel else { return }
        persistOriginConversationId(originViewModel.conversation.id)

        let dmSession = agentDmSession ?? AgentDmSession(originViewModel: originViewModel)
        if agentDmSession == nil {
            agentDmSession = dmSession
        }
        dmSession.updateOrigin(originViewModel)
        dmSession.setAgent(inboxId: agentInboxId)
        await dmSession.refreshDefaultAgentProvisioning()
        await dmSession.rebindWhenDmAppears()
        observeDmIfReady()
    }

    func showGoogleConnectIfNeeded() {
        guard previewStage == nil,
              dmViewModel != nil,
              !defaults.bool(forKey: Self.key("googleConnectHandled", session: session)) else {
            return
        }
        isPresentingGoogleConnect = true
    }

    func didDismissGoogleConnect() {
        isPresentingGoogleConnect = false
        guard previewStage == nil else { return }
        defaults.set(true, forKey: Self.key("googleConnectHandled", session: session))
    }

    func didSend(screenshotCount: Int) {
        guard screenshotCount > 0 else { return }
        pendingScreenshotCount = screenshotCount
        stateMessageIdAtLastSend = latestStateMessageId
    }

    private func observeDmIfReady() {
        guard let dmViewModel,
              dmViewModel.conversation.id != observedDmConversationId else {
            showGoogleConnectIfNeeded()
            return
        }
        observedDmConversationId = dmViewModel.conversation.id
        messagesCancellable = session.messagesRepository(for: dmViewModel.conversation.id)
            .messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.ingest(messages)
            }
        showGoogleConnectIfNeeded()
    }

    private func ingest(_ messages: [AnyMessage]) {
        guard let agentInboxId else { return }
        let candidates: [(message: AnyMessage, state: DocState)] = messages.compactMap { message in
            guard message.senderId == agentInboxId,
                  case .text(let text) = message.content,
                  let state = DocStateMessage.parse(text) else {
                return nil
            }
            return (message, state)
        }
        guard let latest = candidates.first,
              latest.message.id != latestStateMessageId else {
            return
        }

        latestStateMessageId = latest.message.id
        state = latest.state
        if let data = try? JSONEncoder().encode(latest.state) {
            defaults.set(data, forKey: Self.key("state", session: session))
        }
        if pendingScreenshotCount > 0,
           latest.message.id != stateMessageIdAtLastSend {
            pendingScreenshotCount = 0
            stateMessageIdAtLastSend = nil
        }
    }

    private func persistOriginConversationId(_ id: String) {
        guard !id.hasPrefix("draft-") else { return }
        defaults.set(id, forKey: Self.key("originConversationId", session: session))
    }

    private static func key(_ component: String, session: any SessionManagerProtocol) -> String {
        let account: String
        switch session.messagingServiceSync().state {
        case .authorized(let inboxId):
            account = inboxId
        case .registering:
            account = "registering"
        }
        return "doc.v1.\(account).\(component)"
    }

    private static var previewState: DocState {
        let now = Date()
        return DocState(docs: [
            DocStatus(
                id: "tahoe-trip",
                name: "Tahoe Trip",
                url: "https://docs.google.com/document/d/example-tahoe",
                updatedAt: now.addingTimeInterval(-12 * 60),
                lastChange: DocLastChange(
                    who: "Sara",
                    what: "added flight times",
                    at: now.addingTimeInterval(-12 * 60)
                ),
                binding: DocBinding(
                    state: .live,
                    number: "+16285550123",
                    group: "Tahoe Weekend"
                ),
                dates: "Dec 12–15",
                people: 7
            ),
            DocStatus(
                id: "house-projects",
                name: "House Projects",
                url: "https://docs.google.com/document/d/example-house",
                updatedAt: now.addingTimeInterval(-3 * 60 * 60),
                lastChange: DocLastChange(
                    who: "Noah",
                    what: "checked off paint samples",
                    at: now.addingTimeInterval(-3 * 60 * 60)
                ),
                binding: DocBinding(
                    state: .none,
                    number: "+16285550123"
                ),
                people: 4
            ),
        ])
    }
}
