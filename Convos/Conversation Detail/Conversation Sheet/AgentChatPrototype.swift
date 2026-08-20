import ConvosComposer
import ConvosCore
import Observation
import SwiftUI

/// One destination in the non-production agent-chat switcher. Live lanes bind
/// to a real agent DM; prototype lanes are deliberately local so the Firebase
/// build can demonstrate the full interaction before the runtime contracts in
/// `docs/plans/agent-chat-server-contract.md` exist.
struct AgentChatLane: Identifiable {
    enum Kind: Equatable {
        case live(inboxId: String)
        case prototype(PrototypeAgent)
        case external(ExternalAgentProvider)
        case grokBot(GrokBotAgent)
        case ghost
    }

    enum PrototypeAgent: String, CaseIterable {
        case flightTracker
        case shanesAgent
        case spaceAbilities

        var displayName: String {
            switch self {
            case .flightTracker: "Flight Tracker"
            case .shanesAgent: "Shane's Agent"
            case .spaceAbilities: "Space Abilities"
            }
        }

        var subtitle: String {
            switch self {
            case .flightTracker: "Flights, delays, and trip timing"
            case .shanesAgent: "Your personal operator"
            case .spaceAbilities: "Home, members, and group updates"
            }
        }

        var symbolName: String {
            switch self {
            case .flightTracker: "airplane"
            case .shanesAgent: "person.fill"
            case .spaceAbilities: "sparkles"
            }
        }

        var tint: Color {
            switch self {
            case .flightTracker: .colorBlue
            case .shanesAgent: .black
            case .spaceAbilities: .colorLava
            }
        }
    }

    let id: String
    let name: String
    let subtitle: String
    let kind: Kind
    let profile: Profile?
    let agentVerification: AgentVerification

    var liveInboxId: String? {
        guard case .live(let inboxId) = kind else { return nil }
        return inboxId
    }

    var isLocalPrototype: Bool {
        switch kind {
        case .prototype, .external, .grokBot, .ghost: true
        case .live: false
        }
    }

    var isGhost: Bool {
        kind == .ghost
    }

    var externalProvider: ExternalAgentProvider? {
        switch kind {
        case .external(let provider): provider
        case .grokBot: .grokBot
        default: nil
        }
    }

    var grokBotAgent: GrokBotAgent? {
        guard case .grokBot(let agent) = kind else { return nil }
        return agent
    }

    static func live(profile: Profile, verification: AgentVerification) -> AgentChatLane {
        AgentChatLane(
            id: "live:\(profile.inboxId)",
            name: profile.displayName,
            subtitle: "Available in this convo",
            kind: .live(inboxId: profile.inboxId),
            profile: profile,
            agentVerification: verification
        )
    }

    static func prototype(_ agent: PrototypeAgent) -> AgentChatLane {
        AgentChatLane(
            id: "prototype:\(agent.rawValue)",
            name: agent.displayName,
            subtitle: agent.subtitle,
            kind: .prototype(agent),
            profile: nil,
            agentVerification: .unverified
        )
    }

    static func external(_ provider: ExternalAgentProvider) -> AgentChatLane {
        AgentChatLane(
            id: "prototype:external:\(provider.rawValue)",
            name: provider.displayName,
            subtitle: provider.chatSubtitle,
            kind: .external(provider),
            profile: nil,
            agentVerification: .unverified
        )
    }

    static func grokBot(_ agent: GrokBotAgent) -> AgentChatLane {
        AgentChatLane(
            id: "prototype:external:grokbot:\(agent.id)",
            name: agent.harnessName,
            subtitle: agent.detail ?? "Live · Private agent on your computer",
            kind: .grokBot(agent),
            profile: nil,
            agentVerification: .unverified
        )
    }

    /// Every Convo owns one group-local agent lane. A verified live member
    /// replaces this preview as soon as it is available, but personal agents
    /// must never become the first/default lane while that member is syncing.
    static let groupAgentFallback: AgentChatLane = .prototype(.spaceAbilities)

    static func available(
        live: [AgentChatLane],
        connectedExternalProviders: [ExternalAgentProvider],
        grokBotAgents: [GrokBotAgent] = []
    ) -> [AgentChatLane] {
        var seenProviderIds: Set<String> = []
        let external = connectedExternalProviders
            .filter { provider in
                provider.connectionAvailability == .live
                    && seenProviderIds.insert(provider.id).inserted
            }
            .flatMap { provider in
                provider == .grokBot
                    ? grokBotAgents.map(AgentChatLane.grokBot)
                    : [AgentChatLane.external(provider)]
            }
        let groupAgent: AgentChatLane = live.first ?? groupAgentFallback
        return [groupAgent] + Array(live.dropFirst()) + external + [.ghost]
    }

    static let ghost: AgentChatLane = AgentChatLane(
        id: "prototype:ghost",
        name: "Ghost Mode",
        subtitle: "Private from the group · Share one message at a time",
        kind: .ghost,
        profile: nil,
        agentVerification: .unverified
    )

    func receipt(conversationId: String, messageId: String) -> MessageAgentReceipt {
        MessageAgentReceipt(
            conversationId: conversationId,
            messageId: messageId,
            agentId: id,
            agentName: name,
            appearance: receiptAppearance
        )
    }

    private var receiptAppearance: MessageAgentReceipt.Appearance {
        switch kind {
        case .live, .prototype(.spaceAbilities):
            .init(
                symbolName: "sparkles",
                backgroundRed: 0.98,
                backgroundGreen: 0.30,
                backgroundBlue: 0.10,
                foregroundRed: 1,
                foregroundGreen: 0.85,
                foregroundBlue: 0.12
            )
        case .prototype(.flightTracker):
            .init(symbolName: "airplane", backgroundRed: 0.08, backgroundGreen: 0.42, backgroundBlue: 0.88)
        case .prototype(.shanesAgent):
            .init(symbolName: "person.fill", backgroundRed: 0.08, backgroundGreen: 0.08, backgroundBlue: 0.09)
        case .external(let provider):
            provider.receiptAppearance
        case .grokBot:
            ExternalAgentProvider.grokBot.receiptAppearance
        case .ghost:
            .init(symbolName: "eye.slash.fill", backgroundRed: 0.52, backgroundGreen: 0.20, backgroundBlue: 0.78)
        }
    }
}

private extension ExternalAgentProvider {
    var receiptAppearance: MessageAgentReceipt.Appearance {
        let background: [Double] = switch self {
        case .codex: [0.08, 0.08, 0.09]
        case .town: [0.10, 0.37, 0.28]
        case .tasklet: [0.30, 0.23, 0.76]
        case .claudeCode: [0.72, 0.36, 0.20]
        case .hermes: [0.23, 0.38, 0.74]
        case .openClaw: [0.77, 0.17, 0.13]
        case .grokBot: [0.12, 0.12, 0.14]
        case .connectMCP: [0.24, 0.27, 0.31]
        }
        return .init(
            symbolName: symbolName,
            backgroundRed: background[0],
            backgroundGreen: background[1],
            backgroundBlue: background[2]
        )
    }
}

struct AgentChatPrototypeMessage: Identifiable, Equatable, Codable {
    enum Sender: String, Codable {
        case user
        case agent
    }

    let id: UUID
    let sender: Sender
    let text: String

    init(id: UUID = UUID(), sender: Sender, text: String) {
        self.id = id
        self.sender = sender
        self.text = text
    }
}

/// Lane-local prototype state. Drafts, messages, and response activity stay
/// keyed to a lane so changing the visible agent never moves or cancels work.
@Observable
@MainActor
final class AgentChatPrototypeState {
    var selectedLaneId: String?
    private(set) var messagesByLane: [String: [AgentChatPrototypeMessage]] = [:]
    private(set) var draftsByLane: [String: String] = [:]
    private(set) var workingLaneIds: Set<String> = []
    private(set) var shareConfirmation: String?
    private(set) var approvedPersonalContextItemIds: Set<String> = []
    private(set) var connectedExternalProviders: [ExternalAgentProvider] = []
    private(set) var externalAccessByProvider: [ExternalAgentProvider: ExternalAgentAccess] = [:]
    @ObservationIgnored private let transcriptKeychain: any KeychainServiceProtocol
    @ObservationIgnored private var boundConversationId: String?

    init(
        restoresConnectedExternalProviders: Bool = true,
        transcriptKeychain: any KeychainServiceProtocol = KeychainService()
    ) {
        self.transcriptKeychain = transcriptKeychain
        if restoresConnectedExternalProviders {
            restoreExternalConnections()
        }
    }

    /// Restores the private agent transcript for this Convo. The payload lives
    /// in this-device-only Keychain storage so forwarded group text never goes
    /// through preferences or cloud sync just to remain visible on reopen.
    func bind(to conversationId: String) {
        guard boundConversationId != conversationId else { return }
        boundConversationId = conversationId
        messagesByLane = loadTranscript(for: conversationId)
    }

    var hasApprovedPersonalContext: Bool {
        !approvedPersonalContextItemIds.isEmpty
    }

    func restorePersonalContext(itemIds: Set<String>) {
        approvedPersonalContextItemIds = itemIds
    }

    func approvePersonalContext(_ bundle: PersonalContextBundle) {
        approvedPersonalContextItemIds.formUnion(bundle.items.map(\.id))
    }

    func removePersonalContextAccess() {
        approvedPersonalContextItemIds.removeAll()
    }

    func connect(_ provider: ExternalAgentProvider) {
        guard provider.connectionAvailability == .live else { return }
        if !connectedExternalProviders.contains(provider) {
            connectedExternalProviders.append(provider)
            connectedExternalProviders.sort { lhs, rhs in
                guard let lhsIndex = ExternalAgentProvider.allCases.firstIndex(of: lhs),
                      let rhsIndex = ExternalAgentProvider.allCases.firstIndex(of: rhs) else {
                    return lhs.rawValue < rhs.rawValue
                }
                return lhsIndex < rhsIndex
            }
        }
        if externalAccessByProvider[provider] == nil {
            externalAccessByProvider[provider] = .privateDesktop
        }
    }

    func restoreExternalConnections() {
        for provider in ExternalAgentProvider.allCases
            where provider.connectionAvailability == .live && provider.hasStoredConnection {
            connect(provider)
        }
    }

    func access(for provider: ExternalAgentProvider) -> ExternalAgentAccess {
        externalAccessByProvider[provider, default: .privateDesktop]
    }

    func accessBinding(for provider: ExternalAgentProvider) -> Binding<ExternalAgentAccess> {
        Binding(
            get: { [weak self] in self?.access(for: provider) ?? .privateDesktop },
            set: { [weak self] access in self?.externalAccessByProvider[provider] = access }
        )
    }

    func select(_ lane: AgentChatLane) {
        selectedLaneId = lane.id
        prepare(lane)
    }

    func prepare(_ lane: AgentChatLane) {
        guard lane.isLocalPrototype, messagesByLane[lane.id] == nil else { return }
        messagesByLane[lane.id] = initialMessages(for: lane)
        persistTranscript()
    }

    func messages(for lane: AgentChatLane) -> [AgentChatPrototypeMessage] {
        messagesByLane[lane.id] ?? initialMessages(for: lane)
    }

    func draftBinding(for lane: AgentChatLane) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.draftsByLane[lane.id] ?? "" },
            set: { [weak self] value in self?.draftsByLane[lane.id] = value }
        )
    }

    /// Selects a private lane and places text in its composer for review. An
    /// existing unfinished draft is preserved above the new handoff so opening
    /// a group message can never silently erase the user's work.
    func stageDraft(_ rawText: String, in lane: AgentChatLane) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        select(lane)
        let current = draftsByLane[lane.id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        draftsByLane[lane.id] = current.isEmpty ? text : "\(current)\n\n\(text)"
    }

    func isWorking(_ lane: AgentChatLane) -> Bool {
        workingLaneIds.contains(lane.id)
    }

    func send(in lane: AgentChatLane) {
        let text: String = (draftsByLane[lane.id] ?? "")
        guard send(text: text, in: lane) else { return }
        draftsByLane[lane.id] = ""
    }

    /// Queues explicit text after a composer confirms it. Group-message
    /// handoffs use `stageDraft(_:in:)` so selection never sends on its own.
    @discardableResult
    func send(text rawText: String, in lane: AgentChatLane) -> Bool {
        prepare(lane)
        guard !workingLaneIds.contains(lane.id) else { return false }
        let text: String = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        append(.init(sender: .user, text: text), to: lane)
        workingLaneIds.insert(lane.id)

        if case .external(.codex) = lane.kind {
            sendToCodex(text, in: lane)
            return true
        }
        if case .external(.town) = lane.kind {
            sendToTown(text, in: lane)
            return true
        }
        if case .external(.tasklet) = lane.kind {
            sendToTasklet(text, in: lane)
            return true
        }
        if case .grokBot(let agent) = lane.kind {
            sendToGrokBot(text, agent: agent, in: lane)
            return true
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard let self else { return }
            append(.init(sender: .agent, text: reply(for: lane, userText: text)), to: lane)
            workingLaneIds.remove(lane.id)
        }
        return true
    }

    private func sendToTown(_ text: String, in lane: AgentChatLane) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let configuration = TownConnectionStore.configuration() else {
                    throw TownConnectionError.notConnected
                }
                let result = try await TownBridgeClient().send(
                    text,
                    configuration: configuration,
                    yourSpaceSnapshot: nil
                )
                append(.init(sender: .agent, text: result.shareText), to: lane)
            } catch is CancellationError {
                // The lane may be dismissed while Town is still working.
            } catch {
                append(
                    AgentChatPrototypeMessage(
                        sender: .agent,
                        text: "I couldn't finish that Town request. \(error.localizedDescription)"
                    ),
                    to: lane
                )
            }
            workingLaneIds.remove(lane.id)
        }
    }

    private func sendToTasklet(_ text: String, in lane: AgentChatLane) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let configuration = TaskletConnectionStore.configuration() else {
                    throw TaskletConnectionError.notConnected
                }
                let result = try await TaskletBridgeClient().send(
                    text,
                    configuration: configuration,
                    yourSpaceSnapshot: nil
                )
                append(.init(sender: .agent, text: result.shareText), to: lane)
            } catch is CancellationError {
                // The lane may be dismissed while Tasklet is still working.
            } catch {
                append(
                    AgentChatPrototypeMessage(
                        sender: .agent,
                        text: "I couldn't finish that Tasklet request. \(error.localizedDescription)"
                    ),
                    to: lane
                )
            }
            workingLaneIds.remove(lane.id)
        }
    }

    private func sendToGrokBot(_ text: String, agent: GrokBotAgent, in lane: AgentChatLane) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let configuration = GrokBotConnectionStore.configuration() else {
                    throw GrokBotConnectionError.notConnected
                }
                let result = try await GrokBotBridgeClient().send(
                    text,
                    to: agent,
                    configuration: configuration,
                    yourSpaceSnapshot: nil
                )
                append(.init(sender: .agent, text: result.shareText), to: lane)
            } catch is CancellationError {
                // The lane may be dismissed while Grok Bot is still working.
            } catch {
                append(
                    AgentChatPrototypeMessage(
                        sender: .agent,
                        text: "I couldn't finish that \(agent.name) request. \(error.localizedDescription)"
                    ),
                    to: lane
                )
            }
            workingLaneIds.remove(lane.id)
        }
    }

    func share(_ message: AgentChatPrototypeMessage, to lane: AgentChatLane) {
        prepare(lane)
        guard lane.isLocalPrototype else {
            shareConfirmation = "Prototype preview only — nothing was sent to \(lane.name)"
            return
        }
        append(
            AgentChatPrototypeMessage(
                sender: .user,
                text: "Shared from Ghost Mode:\n\(message.text)"
            ),
            to: lane
        )
        shareConfirmation = "Shared only this message with \(lane.name)"
    }

    func clearShareConfirmation() {
        shareConfirmation = nil
    }

    private func sendToCodex(_ text: String, in lane: AgentChatLane) {
        guard let configuration = CodexConnectionStore.configuration() else {
            append(
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: "Codex isn’t connected yet. Open Add an external agent, choose Codex, and connect this iPhone to the app-server on your Mac."
                ),
                to: lane
            )
            workingLaneIds.remove(lane.id)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await CodexAppServerClient().send(
                    userRequest: text,
                    configuration: configuration,
                    snapshot: nil,
                    existingThreadId: CodexConnectionStore.threadId()
                )
                CodexConnectionStore.saveThreadId(result.threadId)
                append(.init(sender: .agent, text: result.text), to: lane)
            } catch {
                append(
                    AgentChatPrototypeMessage(
                        sender: .agent,
                        text: "I couldn’t reach Codex on your Mac. \(error.localizedDescription)"
                    ),
                    to: lane
                )
            }
            workingLaneIds.remove(lane.id)
        }
    }

    private func initialMessages(for lane: AgentChatLane) -> [AgentChatPrototypeMessage] {
        switch lane.kind {
        case .prototype(.flightTracker):
            [
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: "I can track a flight, watch delays, and turn the trip into a clean timeline. What flight should I follow?"
                ),
            ]
        case .prototype(.shanesAgent):
            [
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: "I’ve got the context from Home. What do you want to move forward today?"
                ),
            ]
        case .prototype(.spaceAbilities):
            [
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: "Tokyo redesign is live. I can update Home, check in with members, or turn the next idea into a plan."
                ),
            ]
        case .external(let provider):
            [
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: provider.welcomeMessage
                ),
            ]
        case .grokBot(let agent):
            [
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: "\(agent.name) is live in your private Convos lane. Ask me to work, then choose whether to save or share the result."
                ),
            ]
        case .ghost:
            [
                AgentChatPrototypeMessage(
                    sender: .agent,
                    text: "Start anywhere. I’ll help you search, think, and draft here—and nothing leaves unless you choose one message to share."
                ),
            ]
        case .live:
            []
        }
    }

    private func reply(for lane: AgentChatLane, userText: String) -> String {
        switch lane.kind {
        case .prototype(.flightTracker):
            "I’m tracking that as a prototype. Next I’d show the live status, terminal, delay risk, and when you should leave."
        case .prototype(.shanesAgent):
            "Got it. I’d turn “\(userText)” into the next concrete action and keep the working context in this lane."
        case .prototype(.spaceAbilities):
            "I can work with that privately here, then update Home or ping the right member once you approve it."
        case .external(let provider):
            "Demo connection active. \(provider.displayName) would work on “\(userText)” with only the access you approved for this convo."
        case .grokBot(let agent):
            "\(agent.name) would work on “\(userText)” through your private Grok Bot computer connection."
        case .ghost:
            "Here’s a private first pass: keep the core idea, remove anything identifying, and share only the sentence you want another agent to act on."
        case .live:
            ""
        }
    }

    private func append(_ message: AgentChatPrototypeMessage, to lane: AgentChatLane) {
        messagesByLane[lane.id, default: []].append(message)
        if let count = messagesByLane[lane.id]?.count, count > Constant.maximumMessagesPerLane {
            messagesByLane[lane.id]?.removeFirst(count - Constant.maximumMessagesPerLane)
        }
        persistTranscript()
    }

    private func loadTranscript(for conversationId: String) -> [String: [AgentChatPrototypeMessage]] {
        guard let data = try? transcriptKeychain.retrieveData(account: transcriptAccount(for: conversationId)),
              let envelope = try? JSONDecoder().decode(TranscriptEnvelope.self, from: data) else {
            return [:]
        }
        return envelope.messagesByLane
    }

    private func persistTranscript() {
        guard let boundConversationId,
              let data = try? JSONEncoder().encode(TranscriptEnvelope(messagesByLane: messagesByLane)) else {
            return
        }
        try? transcriptKeychain.saveData(data, account: transcriptAccount(for: boundConversationId))
    }

    private func transcriptAccount(for conversationId: String) -> String {
        "agent-chat-transcript.v1.\(conversationId)"
    }

    private struct TranscriptEnvelope: Codable {
        let messagesByLane: [String: [AgentChatPrototypeMessage]]
    }

    private enum Constant {
        static let maximumMessagesPerLane: Int = 100
    }
}

struct AgentChatLaneAvatar: View {
    let lane: AgentChatLane
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let profile = lane.profile {
                MessageAvatarView(
                    profile: profile,
                    size: size,
                    agentVerification: lane.agentVerification
                )
            } else {
                prototypeAvatar
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var prototypeAvatar: some View {
        switch lane.kind {
        case .prototype(let agent):
            Image(systemName: agent.symbolName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(agent == .spaceAbilities ? Color.yellow : Color.white)
                .frame(width: size, height: size)
                .background(agent.tint, in: .circle)
        case .external(let provider):
            Image(systemName: provider.symbolName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(provider.tint, in: .circle)
        case .grokBot:
            Image(systemName: ExternalAgentProvider.grokBot.symbolName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: size, height: size)
                .background(ExternalAgentProvider.grokBot.tint, in: .circle)
        case .ghost:
            GhostGlyph()
                .frame(width: size * 0.48, height: size * 0.52)
                .frame(width: size, height: size)
                .background(Color.purple, in: .circle)
        case .live:
            EmptyView()
        }
    }
}

private struct GhostGlyph: View {
    var body: some View {
        ZStack {
            GhostSilhouette()
                .fill(.white)

            HStack(spacing: 4) {
                Circle()
                Circle()
            }
            .foregroundStyle(.purple)
            .frame(width: 10, height: 3)
            .offset(y: -2)
        }
    }
}

private struct GhostSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let width: CGFloat = rect.width
        let height: CGFloat = rect.height
        var path = Path()

        path.move(to: CGPoint(x: width * 0.14, y: height * 0.92))
        path.addLine(to: CGPoint(x: width * 0.14, y: height * 0.42))
        path.addCurve(
            to: CGPoint(x: width * 0.86, y: height * 0.42),
            control1: CGPoint(x: width * 0.14, y: height * 0.04),
            control2: CGPoint(x: width * 0.86, y: height * 0.04)
        )
        path.addLine(to: CGPoint(x: width * 0.86, y: height * 0.92))
        path.addLine(to: CGPoint(x: width * 0.68, y: height * 0.78))
        path.addLine(to: CGPoint(x: width * 0.50, y: height * 0.94))
        path.addLine(to: CGPoint(x: width * 0.32, y: height * 0.78))
        path.closeSubpath()
        return path
    }
}

struct AgentSwitcherSheet: View {
    let lanes: [AgentChatLane]
    let selectedLane: AgentChatLane
    let prototypeState: AgentChatPrototypeState
    let conversationId: String
    let onSelect: (AgentChatLane) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isPersonalContextPresented: Bool = false
    @State private var isExternalOnboardingPresented: Bool = false
    @State private var reconnectProvider: ExternalAgentProvider?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lanes.filter { !$0.isGhost }) { lane in
                        laneButton(lane)
                    }
                }

                Section {
                    Button {
                        isPersonalContextPresented = true
                    } label: {
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimaryInverted)
                                .frame(width: 44, height: 44)
                                .background(.colorLava, in: .circle)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                                Text("My context")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                Text(personalContextSubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: DesignConstants.Spacing.step2x)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.colorTextSecondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Suggests a relevant bundle, then asks before sharing anything with this group")
                }

                Section {
                    Button {
                        reconnectProvider = nil
                        isExternalOnboardingPresented = true
                    } label: {
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimaryInverted)
                                .frame(width: 44, height: 44)
                                .background(.colorFillPrimary, in: .circle)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                                Text("Add an external agent")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                Text("Connect Codex, Town, Tasklet, or Grok Bot · Preview more providers")
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: DesignConstants.Spacing.step2x)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.colorTextSecondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the external agent setup demo")
                }

                Section {
                    ForEach(lanes.filter(\.isGhost)) { lane in
                        laneButton(lane)
                    }
                } footer: {
                    Text("Ghost Mode stays separate from the group. You choose exactly which message leaves.")
                }
            }
            .navigationTitle("Talk to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            prototypeState.restoreExternalConnections()
            prototypeState.restorePersonalContext(
                itemIds: PersonalContextPrototypeStore.approvedItemIds(for: conversationId)
            )
        }
        .fullScreenCover(isPresented: $isPersonalContextPresented) {
            PersonalContextSuggestionView(
                conversationId: conversationId,
                approvedItemIds: prototypeState.approvedPersonalContextItemIds,
                onApproved: { bundle in
                    prototypeState.approvePersonalContext(bundle)
                    PersonalContextPrototypeStore.save(
                        prototypeState.approvedPersonalContextItemIds,
                        for: conversationId
                    )
                    isPersonalContextPresented = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        dismiss()
                    }
                },
                onRemoved: {
                    prototypeState.removePersonalContextAccess()
                    PersonalContextPrototypeStore.removeAccess(for: conversationId)
                    isPersonalContextPresented = false
                }
            )
        }
        .fullScreenCover(isPresented: $isExternalOnboardingPresented) {
            ExternalAgentOnboardingView(
                prototypeState: prototypeState,
                initialProvider: reconnectProvider,
                onConnected: { provider in
                    prototypeState.connect(provider)
                    AddedExternalAgentStore.remember(provider)
                    let lane: AgentChatLane?
                    if provider == .grokBot {
                        lane = GrokBotConnectionStore.configuration()?.enabledAgents.first.map(AgentChatLane.grokBot)
                    } else {
                        lane = .external(provider)
                    }
                    reconnectProvider = nil
                    if let lane {
                        onSelect(lane)
                    }
                    isExternalOnboardingPresented = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        dismiss()
                    }
                }
            )
        }
    }

    private func laneButton(_ lane: AgentChatLane) -> some View {
        Button {
            if let provider = lane.externalProvider, !provider.hasStoredConnection {
                reconnectProvider = provider
                isExternalOnboardingPresented = true
                return
            }
            onSelect(lane)
            dismiss()
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                AgentChatLaneAvatar(lane: lane)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(lane.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text(rowSubtitle(for: lane))
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DesignConstants.Spacing.step2x)
                if lane.id == selectedLane.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.colorLava)
                        .accessibilityHidden(true)
                } else if prototypeState.isWorking(lane) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lane.name)
        .accessibilityValue(accessibilityValue(for: lane))
        .accessibilityHint("Switches the private agent lane")
    }

    private func rowSubtitle(for lane: AgentChatLane) -> String {
        if let provider = lane.externalProvider, !provider.hasStoredConnection {
            return "Disconnected · Tap to reconnect"
        }
        return prototypeState.isWorking(lane) ? "Working…" : lane.subtitle
    }

    private var personalContextSubtitle: String {
        if prototypeState.hasApprovedPersonalContext {
            return "\(prototypeState.approvedPersonalContextItemIds.count) approved items · Home + conversation"
        }
        return "Get a suggested bundle for this Home + conversation"
    }

    private func accessibilityValue(for lane: AgentChatLane) -> String {
        var values: [String] = []
        if lane.id == selectedLane.id { values.append("Current") }
        if prototypeState.isWorking(lane) { values.append("Working") }
        if lane.isGhost { values.append("Private from the group") }
        return values.joined(separator: ", ")
    }
}

/// Destination-only companion to the Agent switcher. It intentionally uses
/// the same ordered lanes, while omitting setup and context controls so a
/// long-press remains one quick handoff instead of becoming another workflow.
struct AgentMessageDestinationSheet: View {
    let lanes: [AgentChatLane]
    let prototypeState: AgentChatPrototypeState
    let onSelect: (AgentChatLane) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var reconnectProvider: ExternalAgentProvider?
    @State private var isExternalOnboardingPresented: Bool = false

    private var groupAgent: AgentChatLane? { lanes.first }
    private var personalAgents: [AgentChatLane] { Array(lanes.dropFirst()).filter { !$0.isGhost } }
    private var ghost: AgentChatLane? { lanes.first(where: \.isGhost) }

    var body: some View {
        NavigationStack {
            List {
                if let groupAgent {
                    Section("This Convo") {
                        laneButton(groupAgent)
                    }
                }
                if !personalAgents.isEmpty {
                    Section("Your agents") {
                        ForEach(personalAgents) { lane in
                            laneButton(lane)
                        }
                    }
                }
                Section("Open in external app") {
                    ForEach(ExternalAppDestination.allCases) { destination in
                        externalAppButton(destination)
                    }
                }
                if let ghost {
                    Section {
                        laneButton(ghost)
                    } footer: {
                        Text("Only this message is sent. Personal agents and Ghost Mode stay private from the group.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundSurfaceless)
            .navigationTitle("Send to agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .background(.colorBackgroundSurfaceless)
        .preferredColorScheme(.dark)
        .presentationBackground(.colorBackgroundSurfaceless)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $isExternalOnboardingPresented) {
            ExternalAgentOnboardingView(
                prototypeState: prototypeState,
                initialProvider: reconnectProvider,
                onConnected: { provider in
                    prototypeState.connect(provider)
                    AddedExternalAgentStore.remember(provider)
                    let connectedLane: AgentChatLane?
                    if provider == .grokBot {
                        connectedLane = GrokBotConnectionStore.configuration()?
                            .enabledAgents.first.map(AgentChatLane.grokBot)
                    } else {
                        connectedLane = .external(provider)
                    }
                    reconnectProvider = nil
                    isExternalOnboardingPresented = false
                    if let connectedLane {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            dismiss()
                            try? await Task.sleep(for: .milliseconds(250))
                            onSelect(connectedLane)
                        }
                    }
                }
            )
        }
    }

    private func laneButton(_ lane: AgentChatLane) -> some View {
        Button {
            if let provider = lane.externalProvider, !provider.hasStoredConnection {
                reconnectProvider = provider
                isExternalOnboardingPresented = true
                return
            }
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                onSelect(lane)
            }
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                AgentChatLaneAvatar(lane: lane)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(lane.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text(subtitle(for: lane))
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DesignConstants.Spacing.step2x)
                if prototypeState.isWorking(lane) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "square.and.pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.colorLava)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open message in \(lane.name)")
        .accessibilityHint("Opens an editable draft in this private agent chat")
    }

    private func externalAppButton(_ destination: ExternalAppDestination) -> some View {
        Button {
            guard let url = URL(string: destination.urlString) else { return }
            openURL(url)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: destination.symbolName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(destination.tint, in: .circle)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(destination.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Opens the app when installed, otherwise the website")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer(minLength: DesignConstants.Spacing.step2x)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.title3)
                    .foregroundStyle(.colorTextSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in \(destination.displayName)")
    }

    private func subtitle(for lane: AgentChatLane) -> String {
        if let provider = lane.externalProvider, !provider.hasStoredConnection {
            return "Disconnected · Tap to reconnect"
        }
        return prototypeState.isWorking(lane) ? "Working…" : lane.subtitle
    }
}

private enum ExternalAppDestination: String, CaseIterable, Identifiable {
    case chatGPT
    case claude
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var symbolName: String {
        switch self {
        case .chatGPT: "circle.hexagongrid.fill"
        case .claude: "sun.max.fill"
        case .gemini: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .chatGPT: Color(red: 0.06, green: 0.65, blue: 0.53)
        case .claude: Color(red: 0.82, green: 0.43, blue: 0.27)
        case .gemini: Color(red: 0.35, green: 0.38, blue: 0.90)
        }
    }

    var urlString: String {
        switch self {
        case .chatGPT: "https://chatgpt.com/"
        case .claude: "https://claude.ai/new"
        case .gemini: "https://gemini.google.com/app"
        }
    }
}

/// Bottom drawer for the private, reaction-sized marker under a group
/// message. It mirrors the Reactions drawer's hierarchy while being explicit
/// that this state is device-local and invisible to the Convo.
struct AgentReceiptDrawer: View {
    let receipt: MessageAgentReceipt
    let lane: AgentChatLane?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Sent to Agent")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .padding(.bottom, DesignConstants.Spacing.step2x)

            HStack(spacing: DesignConstants.Spacing.step3x) {
                if let lane {
                    AgentChatLaneAvatar(lane: lane, size: 48)
                } else {
                    fallbackAvatar
                }
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(receipt.agentName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Only you can see this was sent to an agent")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Opened in \(receipt.agentName). Only you can see this.")
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step5x)
    }

    private var fallbackAvatar: some View {
        Image(systemName: receipt.appearance.symbolName)
            .font(.body.weight(.semibold))
            .foregroundStyle(
                Color(
                    red: receipt.appearance.foregroundRed,
                    green: receipt.appearance.foregroundGreen,
                    blue: receipt.appearance.foregroundBlue
                )
            )
            .frame(width: 48, height: 48)
            .background(
                Color(
                    red: receipt.appearance.backgroundRed,
                    green: receipt.appearance.backgroundGreen,
                    blue: receipt.appearance.backgroundBlue
                ),
                in: .circle
            )
    }
}

/// Picks a Convo for an agent response. The origin Convo is pinned first and
/// every selection stages an editable group draft rather than sending.
struct AgentShareToConvoSheet: View {
    let conversations: [Conversation]
    let currentConversationId: String
    let onSelect: (Conversation) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var searchText: String = ""

    private var visibleConversations: [Conversation] {
        let sorted = conversations.sorted { lhs, rhs in
            if lhs.id == currentConversationId { return true }
            if rhs.id == currentConversationId { return false }
            return (lhs.lastMessage?.createdAt ?? lhs.createdAt) >
                (rhs.lastMessage?.createdAt ?? rhs.createdAt)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(visibleConversations) { conversation in
                Button {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        onSelect(conversation)
                    }
                } label: {
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        ConversationAvatarView(
                            conversation: conversation,
                            conversationImage: nil,
                            size: 44
                        )
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                            Text(conversation.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimary)
                                .lineLimit(1)
                            Text(conversation.id == currentConversationId ? "Current Convo · Edit before sending" : "Edit before sending")
                                .font(.footnote)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        Spacer(minLength: DesignConstants.Spacing.step2x)
                        Image(systemName: "square.and.pencil")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.colorLava)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
            .background(.colorBackgroundSurfaceless)
            .navigationTitle("Share to a convo")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search Convos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.colorBackgroundSurfaceless)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct AgentChatDemoTranscript: View {
    let lane: AgentChatLane
    let lanes: [AgentChatLane]
    let prototypeState: AgentChatPrototypeState
    let extraBottomInset: CGFloat
    var onContentHeightChanged: ((CGFloat) -> Void)?
    var onShareToConvo: ((String) -> Void)?

    @State private var messageToShare: AgentChatPrototypeMessage?
    @State private var isShareDialogPresented: Bool = false
    @State private var isNativeSharePresented: Bool = false
    @State private var isExternalAccessPresented: Bool = false

    private var messages: [AgentChatPrototypeMessage] {
        prototypeState.messages(for: lane)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignConstants.Spacing.step4x) {
                    laneHeader
                    ForEach(messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if prototypeState.isWorking(lane) {
                        workingRow
                            .id(Constant.workingRowId)
                    }
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.top, DesignConstants.Spacing.step6x)
                .padding(.bottom, extraBottomInset + DesignConstants.Spacing.step6x)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onContentHeightChanged?(height)
                }
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: prototypeState.isWorking(lane)) { _, _ in
                scrollToBottom(proxy)
            }
        }
        .background(.colorBackgroundSurfaceless)
        .overlay(alignment: .top) {
            if let confirmation = prototypeState.shareConfirmation {
                shareToast(confirmation)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: prototypeState.shareConfirmation)
        .task { prototypeState.prepare(lane) }
        .confirmationDialog(
            "Send to",
            isPresented: $isShareDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(lanes.filter { !$0.isGhost }) { destination in
                Button(destination.name) {
                    guard let messageToShare else { return }
                    prototypeState.share(messageToShare, to: destination)
                    clearShareToastLater()
                }
            }
            Button("Save to Desktop") {
                isNativeSharePresented = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this message will leave Ghost Mode.")
        }
        .shareSheet(
            isPresented: $isNativeSharePresented,
            items: messageToShare.map { [$0.text] } ?? []
        )
        .sheet(isPresented: $isExternalAccessPresented) {
            if let provider = lane.externalProvider {
                ExternalAgentAccessSheet(
                    provider: provider,
                    access: prototypeState.accessBinding(for: provider)
                )
            }
        }
    }

    @ViewBuilder
    private var laneHeader: some View {
        if lane.isGhost {
            VStack(spacing: DesignConstants.Spacing.step3x) {
                AgentChatLaneAvatar(lane: lane, size: 64)
                Text("Completely off the record.")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.colorTextPrimary)
                Text("This is just between you and me. Search, think, and draft here—then choose exactly what leaves.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Nothing leaves unless you share it", systemImage: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(minHeight: 32)
                    .background(.colorFillSubtle, in: .capsule)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, DesignConstants.Spacing.step5x)
        } else {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                AgentChatLaneAvatar(lane: lane, size: 48)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("1-on-1 with \(lane.name)")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                    Text(lane.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
                Spacer()
                if lane.externalProvider != nil {
                    Button {
                        isExternalAccessPresented = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                            .frame(width: 44, height: 44)
                            .background(.colorFillSubtle, in: .circle)
                    }
                    .accessibilityLabel("Agent access")
                    .accessibilityHint("Choose where this external agent can read and respond")
                }
            }
            .padding(.bottom, DesignConstants.Spacing.step4x)
        }
    }

    private func messageRow(_ message: AgentChatPrototypeMessage) -> some View {
        VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: DesignConstants.Spacing.step2x) {
            HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                if message.sender == .user { Spacer(minLength: 52) }
                if message.sender == .agent {
                    AgentChatLaneAvatar(lane: lane, size: 30)
                }
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(message.sender == .user ? Color.black : Color.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.vertical, DesignConstants.Spacing.step3x)
                    .background(
                        message.sender == .user ? Color.white : Color.colorBackgroundRaisedSecondary,
                        in: .rect(cornerRadius: 18)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                if lane.isGhost {
                    ghostShareButton(for: message)
                }
                if message.sender == .agent { Spacer(minLength: lane.isGhost ? 0 : 52) }
            }
            if message.sender == .agent, lane.externalProvider != nil {
                Button {
                    onShareToConvo?(message.text)
                } label: {
                    Label("Share to a convo", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .padding(.horizontal, DesignConstants.Spacing.step3x)
                        .frame(minHeight: 44)
                        .background(.colorFillSubtle, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.leading, 38)
                .accessibilityHint("Choose a Convo and edit the message before sending")
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }

    private func ghostShareButton(for message: AgentChatPrototypeMessage) -> some View {
        Button {
            messageToShare = message
            isShareDialogPresented = true
        } label: {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 44, height: 44)
                .background(.colorFillSubtle, in: .circle)
        }
        .accessibilityLabel("Share this message")
        .accessibilityHint("Opens destinations. Only this message will be shared")
    }

    private var workingRow: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            AgentChatLaneAvatar(lane: lane, size: 30)
            ProgressView()
                .tint(.colorTextSecondary)
            Text("\(lane.name) is working…")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func shareToast(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.colorTextPrimaryInverted)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .frame(minHeight: 44)
            .background(.colorFillPrimary, in: .capsule)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step3x)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            let id: AnyHashable? = prototypeState.isWorking(lane)
                ? Constant.workingRowId
                : messages.last?.id
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func clearShareToastLater() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            prototypeState.clearShareConfirmation()
        }
    }

    private enum Constant {
        static let workingRowId: String = "agent-chat-prototype-working"
    }
}

struct AgentChatDemoComposer: View {
    let lane: AgentChatLane
    let prototypeState: AgentChatPrototypeState
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    var onUsePersonalContext: () -> Void = {}

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if lane.isGhost {
                Image(systemName: "lock.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            } else {
                Button(action: onUsePersonalContext) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .accessibilityLabel("Use my context")
                .accessibilityHint("Suggests a bundle for this Home and conversation, then asks for approval")
            }

            TextField(
                lane.isGhost ? "Ask privately" : "Chat with \(lane.name)",
                text: prototypeState.draftBinding(for: lane),
                axis: .vertical
            )
            .font(.body)
            .lineLimit(1 ... 5)
            .focused($focusState, equals: .message)
            .submitLabel(.send)
            .onSubmit { prototypeState.send(in: lane) }

            Button { prototypeState.send(in: lane) } label: {
                Image(systemName: "arrow.up")
                    .font(.body.bold())
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(width: 38, height: 38)
                    .background(.colorFillPrimary, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .disabled(prototypeState.draftBinding(for: lane).wrappedValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, DesignConstants.Spacing.step2x)
        .padding(.trailing, DesignConstants.Spacing.stepX)
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .frame(minHeight: 52)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .task { prototypeState.prepare(lane) }
    }
}
