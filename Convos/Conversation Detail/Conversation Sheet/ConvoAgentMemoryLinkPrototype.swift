import ConvosComposer
import SwiftUI

/// Illustrative agents the current user owns in other convos. The production
/// list must come from an owner-scoped server query; these examples exist only
/// so the Firebase prototype can demonstrate the memory-link decision.
enum ConvoOwnedAgent: String, CaseIterable, Hashable, Identifiable {
    case flightTracker
    case hotelScout
    case tripCoordinator

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flightTracker: "AA Flight Tracker"
        case .hotelScout: "Hotel Scout"
        case .tripCoordinator: "Trip Coordinator"
        }
    }

    var originConvoName: String {
        switch self {
        case .flightTracker: "Austin → Tokyo"
        case .hotelScout: "Japan planning"
        case .tripCoordinator: "Summer in Europe"
        }
    }

    var memorySummary: String {
        switch self {
        case .flightTracker: "Flight numbers, seat preferences, airport timing, and delay decisions"
        case .hotelScout: "Hotel shortlist, neighborhood preferences, rates, and booking constraints"
        case .tripCoordinator: "Dates, traveler preferences, reservations, and the shared itinerary"
        }
    }

    var portableCapabilities: [ConvoAgentCapability] {
        switch self {
        case .flightTracker:
            [
                .init(id: "live-flight", name: "Track live flights", symbolName: "location.fill", kind: .ability),
                .init(id: "aa", name: "American Airlines", symbolName: "airplane", kind: .connection),
                .init(id: "calendar", name: "Calendar", symbolName: "calendar", kind: .connection),
                .init(id: "delay-recovery", name: "Delay recovery", symbolName: "arrow.trianglehead.branch", kind: .skill),
                .init(id: "airport-timing", name: "Airport timing", symbolName: "clock.fill", kind: .skill),
            ]
        case .hotelScout:
            [
                .init(id: "compare-hotels", name: "Compare hotels", symbolName: "building.2.fill", kind: .ability),
                .init(id: "booking", name: "Booking.com", symbolName: "bed.double.fill", kind: .connection),
                .init(id: "maps", name: "Maps", symbolName: "map.fill", kind: .connection),
                .init(id: "neighborhood-fit", name: "Neighborhood fit", symbolName: "mappin.and.ellipse", kind: .skill),
                .init(id: "rate-watch", name: "Rate watch", symbolName: "bell.fill", kind: .skill),
            ]
        case .tripCoordinator:
            [
                .init(id: "build-itinerary", name: "Build itineraries", symbolName: "list.bullet.rectangle", kind: .ability),
                .init(id: "calendar", name: "Calendar", symbolName: "calendar", kind: .connection),
                .init(id: "drive", name: "Google Drive", symbolName: "folder.fill", kind: .connection),
                .init(id: "reservation-organizer", name: "Reservation organizer", symbolName: "tray.full.fill", kind: .skill),
                .init(id: "conflict-checker", name: "Schedule conflict checker", symbolName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", kind: .skill),
            ]
        }
    }

    var symbolName: String {
        switch self {
        case .flightTracker: "airplane"
        case .hotelScout: "bed.double.fill"
        case .tripCoordinator: "map.fill"
        }
    }

    var tint: Color {
        switch self {
        case .flightTracker: .colorBlue
        case .hotelScout: Color(red: 0.52, green: 0.27, blue: 0.72)
        case .tripCoordinator: .colorLava
        }
    }

    var welcomeMessage: String {
        "I’m now shared with \(originConvoName). My memory, abilities, connections, and skills work across both convos, while the raw chats remain separate."
    }
}

struct ConvoAgentCapability: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case ability = "Ability"
        case connection = "Connection"
        case skill = "Skill"
    }

    let id: String
    let name: String
    let symbolName: String
    let kind: Kind
}

struct ConvoAgentMemoryLink: Equatable {
    let sharedCapabilityIds: Set<String>

    static func allCapabilities(for agent: ConvoOwnedAgent) -> ConvoAgentMemoryLink {
        .init(sharedCapabilityIds: Set(agent.portableCapabilities.map(\.id)))
    }
}

struct ConvoAgentMemoryLinkOnboardingView: View {
    let prototypeState: AgentChatPrototypeState
    let onLinked: (ConvoOwnedAgent, ConvoAgentMemoryLink) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var selectedAgent: ConvoOwnedAgent?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                    introduction
                    agentList
                    privacyBoundary
                }
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.top, DesignConstants.Spacing.step5x)
                .padding(.bottom, DesignConstants.Spacing.step12x)
            }
            .background(.colorBackgroundSurfaceless)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedAgent) { agent in
                ConvoAgentMemoryLinkDetailView(
                    agent: agent,
                    isAlreadyLinked: prototypeState.linkedConvoAgents.contains(agent),
                    onLink: { configuration in onLinked(agent, configuration) }
                )
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            memoryBridgeGraphic
                .frame(maxWidth: .infinity)
                .padding(.bottom, DesignConstants.Spacing.step2x)
            Text("Share one agent’s memory across convos")
                .font(.system(size: 38, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Bring an agent you own into this convo. Its memory, abilities, connections, and installed skills stay together and work across both places.")
                .font(.title3)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memoryBridgeGraphic: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            convoNode(symbol: "bubble.left.and.bubble.right.fill")
            ZStack {
                Capsule()
                    .fill(Color.colorLava.opacity(0.18))
                    .frame(width: 86, height: 8)
                Image(systemName: "brain.head.profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(width: 52, height: 52)
                    .background(.colorLava, in: .circle)
            }
            convoNode(symbol: "person.3.fill")
        }
        .frame(height: 132)
        .accessibilityHidden(true)
    }

    private func convoNode(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(.colorTextPrimary)
            .frame(width: 56, height: 56)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Your agents in other convos")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)

            VStack(spacing: DesignConstants.Spacing.step2x) {
                ForEach(ConvoOwnedAgent.allCases) { agent in
                    Button {
                        selectedAgent = agent
                    } label: {
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            agentBadge(agent, size: 46)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                                Text(agent.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                Text("From \(agent.originConvoName) · \(agent.portableCapabilities.count) abilities, connections & skills")
                                    .font(.footnote)
                                    .foregroundStyle(.colorTextSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: DesignConstants.Spacing.step2x)
                            if prototypeState.linkedConvoAgents.contains(agent) {
                                Text("Linked")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.colorTextSecondary)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.colorTextSecondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                        .frame(minHeight: 72)
                        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Reviews the memory, abilities, connections, and skills that would be shared")
                }
            }
        }
    }

    private var privacyBoundary: some View {
        Label {
            Text("Raw chat history, Ghost Mode, private DMs, member lists, and unsaved files never cross between convos.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.colorTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func agentBadge(_ agent: ConvoOwnedAgent, size: CGFloat) -> some View {
        Image(systemName: agent.symbolName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(agent.tint, in: .circle)
    }
}

private struct ConvoAgentMemoryLinkDetailView: View {
    let agent: ConvoOwnedAgent
    let isAlreadyLinked: Bool
    let onLink: (ConvoAgentMemoryLink) -> Void

    @State private var isLinking: Bool = false

    init(
        agent: ConvoOwnedAgent,
        isAlreadyLinked: Bool,
        onLink: @escaping (ConvoAgentMemoryLink) -> Void
    ) {
        self.agent = agent
        self.isAlreadyLinked = isAlreadyLinked
        self.onLink = onLink
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                heading
                warning
                sharedMemory
                portableAgentLayer
                neverShared
                demoDisclosure
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.top, DesignConstants.Spacing.step5x)
            .padding(.bottom, 120)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                linkDemo()
            } label: {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    if isLinking {
                        ProgressView()
                            .tint(.colorTextPrimaryInverted)
                    }
                    Text(buttonTitle)
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(.colorFillPrimary, in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(isLinking)
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(.colorBackgroundSurfaceless)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                agentBadge(size: 68)
                Image(systemName: "link")
                    .font(.headline)
                    .foregroundStyle(.colorLava)
                convoBadge
            }
            Text("Use \(agent.displayName) in this convo")
                .font(.largeTitle.bold())
                .tracking(-0.8)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You own this agent in \(agent.originConvoName). Linking it makes the same memory, abilities, connections, and skills available in both convos.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var warning: some View {
        Label {
            Text("People in either convo can influence what this agent remembers. Its full set of abilities, connections, and skills becomes available in both places.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.colorTextPrimary)
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorLava.opacity(0.12), in: .rect(cornerRadius: 16))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sharedMemory: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("One memory, kept in sync")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            infoRow(
                symbol: "brain.head.profile",
                title: "Existing saved memory",
                detail: agent.memorySummary
            )
            infoRow(
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                title: "Future saved memory",
                detail: "New facts and decisions saved in either convo become available in both."
            )
        }
    }

    private var portableAgentLayer: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Everything the agent can do")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("All abilities, connections, and installed skills move with the agent and remain shared across both convos.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(agent.portableCapabilities) { capability in
                    HStack(spacing: DesignConstants.Spacing.step3x) {
                        Image(systemName: capability.symbolName)
                            .foregroundStyle(agent.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                            Text(capability.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.colorTextPrimary)
                            Text(capability.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.colorLava)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 56)

                    if capability.id != agent.portableCapabilities.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
        }
    }

    private var neverShared: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Always stays separate")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Label("Raw messages and full transcripts", systemImage: "bubble.left.fill")
            Label("Ghost Mode and private agent chats", systemImage: "lock.fill")
            Label("Members, DMs, and unsaved attachments", systemImage: "person.2.slash")
        }
        .font(.footnote)
        .foregroundStyle(.colorTextSecondary)
    }

    private var demoDisclosure: some View {
        Label("Clickable prototype — no memory, ability, connection, or skill is moved", systemImage: "sparkles")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.colorTextSecondary)
    }

    private var convoBadge: some View {
        Image(systemName: "person.3.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.colorTextPrimary)
            .frame(width: 68, height: 68)
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: 16))
    }

    private func agentBadge(size: CGFloat) -> some View {
        Image(systemName: agent.symbolName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(agent.tint, in: .circle)
    }

    private func infoRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorLava)
                .frame(width: 32, height: 32)
                .background(Color.colorLava.opacity(0.1), in: .circle)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.colorLava)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var buttonTitle: String {
        if isLinking { return "Linking demo…" }
        return isAlreadyLinked ? "Open shared agent" : "Share memory across convos"
    }

    private func linkDemo() {
        isLinking = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            isLinking = false
            onLink(.allCapabilities(for: agent))
        }
    }
}

struct ConvoAgentMemoryLinkSettingsSheet: View {
    let agent: ConvoOwnedAgent
    let configuration: ConvoAgentMemoryLink
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var isDisconnectConfirmationPresented: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Existing saved memory", systemImage: "brain.head.profile")
                    Label("Future memory syncs both ways", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                } header: {
                    Text("Shared with \(agent.originConvoName)")
                } footer: {
                    Text("Raw messages, Ghost Mode, private DMs, member lists, and unsaved files stay separate.")
                }

                Section("Abilities, connections & skills") {
                    ForEach(sharedCapabilities) { capability in
                        HStack {
                            Label(capability.name, systemImage: capability.symbolName)
                            Spacer()
                            Text(capability.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.colorLava)
                                .accessibilityHidden(true)
                        }
                    }
                }

                Section {
                    Label {
                        Text("Anyone in either convo can influence future saved memory while this link is active.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.colorLava)
                    }
                }

                Section {
                    Button("Disconnect from this convo", role: .destructive) {
                        isDisconnectConfirmationPresented = true
                    }
                } footer: {
                    Text("The agent and its memory stay intact in \(agent.originConvoName). This convo immediately loses future memory updates and access to its abilities, connections, and skills.")
                }
            }
            .navigationTitle("Shared memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog(
            "Disconnect shared agent?",
            isPresented: $isDisconnectConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                onDisconnect()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops memory sharing and removes this agent’s abilities, connections, and skills from this convo. Nothing is deleted from the original convo.")
        }
    }

    private var sharedCapabilities: [ConvoAgentCapability] {
        agent.portableCapabilities.filter { configuration.sharedCapabilityIds.contains($0.id) }
    }
}
