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
        case .prototype, .ghost: true
        case .live: false
        }
    }

    var isGhost: Bool {
        kind == .ghost
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

    static let ghost: AgentChatLane = AgentChatLane(
        id: "prototype:ghost",
        name: "Ghost Mode",
        subtitle: "Private from the group · Share one message at a time",
        kind: .ghost,
        profile: nil,
        agentVerification: .unverified
    )
}

struct AgentChatPrototypeMessage: Identifiable, Equatable {
    enum Sender {
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

    func select(_ lane: AgentChatLane) {
        selectedLaneId = lane.id
        prepare(lane)
    }

    func prepare(_ lane: AgentChatLane) {
        guard lane.isLocalPrototype, messagesByLane[lane.id] == nil else { return }
        messagesByLane[lane.id] = initialMessages(for: lane)
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

    func isWorking(_ lane: AgentChatLane) -> Bool {
        workingLaneIds.contains(lane.id)
    }

    func send(in lane: AgentChatLane) {
        prepare(lane)
        let text: String = (draftsByLane[lane.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draftsByLane[lane.id] = ""
        messagesByLane[lane.id, default: []].append(
            AgentChatPrototypeMessage(sender: .user, text: text)
        )
        workingLaneIds.insert(lane.id)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard let self else { return }
            messagesByLane[lane.id, default: []].append(
                AgentChatPrototypeMessage(sender: .agent, text: reply(for: lane, userText: text))
            )
            workingLaneIds.remove(lane.id)
        }
    }

    func share(_ message: AgentChatPrototypeMessage, to lane: AgentChatLane) {
        prepare(lane)
        guard lane.isLocalPrototype else {
            shareConfirmation = "Prototype preview only — nothing was sent to \(lane.name)"
            return
        }
        messagesByLane[lane.id, default: []].append(
            AgentChatPrototypeMessage(
                sender: .user,
                text: "Shared from Ghost Mode:\n\(message.text)"
            )
        )
        shareConfirmation = "Shared only this message with \(lane.name)"
    }

    func clearShareConfirmation() {
        shareConfirmation = nil
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
        case .ghost:
            "Here’s a private first pass: keep the core idea, remove anything identifying, and share only the sentence you want another agent to act on."
        case .live:
            ""
        }
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
    let onSelect: (AgentChatLane) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lanes.filter { !$0.isGhost }) { lane in
                        laneButton(lane)
                    }
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
    }

    private func laneButton(_ lane: AgentChatLane) -> some View {
        Button {
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
        prototypeState.isWorking(lane) ? "Working…" : lane.subtitle
    }

    private func accessibilityValue(for lane: AgentChatLane) -> String {
        var values: [String] = []
        if lane.id == selectedLane.id { values.append("Current") }
        if prototypeState.isWorking(lane) { values.append("Working") }
        if lane.isGhost { values.append("Private from the group") }
        return values.joined(separator: ", ")
    }
}

struct AgentChatDemoTranscript: View {
    let lane: AgentChatLane
    let lanes: [AgentChatLane]
    let prototypeState: AgentChatPrototypeState
    let extraBottomInset: CGFloat
    var onContentHeightChanged: ((CGFloat) -> Void)?

    @State private var messageToShare: AgentChatPrototypeMessage?
    @State private var isShareDialogPresented: Bool = false
    @State private var isNativeSharePresented: Bool = false

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
            }
            .padding(.bottom, DesignConstants.Spacing.step4x)
        }
    }

    private func messageRow(_ message: AgentChatPrototypeMessage) -> some View {
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
            if message.sender == .agent { Spacer(minLength: lane.isGhost ? 0 : 52) }
        }
        .frame(maxWidth: .infinity)
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

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if lane.isGhost {
                Image(systemName: "lock.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "camera.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
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
