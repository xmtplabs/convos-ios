import ConvosComposer
import ConvosConnections
import ConvosCore
import SwiftUI
import UIKit

enum AgentUseAnywhereChannel: String, CaseIterable, Identifiable {
    case iMessage
    case whatsapp
    case telegram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iMessage: "iMessage"
        case .whatsapp: "WhatsApp"
        case .telegram: "Telegram"
        }
    }

    var symbolName: String {
        switch self {
        case .iMessage: "message.fill"
        case .whatsapp: "phone.bubble.fill"
        case .telegram: "paperplane.fill"
        }
    }
}

/// One access-aware roster for every smart group doc the person controls or can
/// use. The underlying runtime remains agent-shaped, but the product surface is
/// the durable multiplayer workspace people recognize as @doc.
struct ManageAgentsView: View {
    struct Agent: Identifiable {
        struct Place: Identifiable {
            let id: String
            let name: String
            let access: String
            let replyBehavior: String
            let isListening: Bool
            let participationMode: ConversationParticipationMode

            init(
                id: String,
                name: String,
                access: String,
                replyBehavior: String,
                isListening: Bool,
                participationMode: ConversationParticipationMode = .mentionsOnly
            ) {
                self.id = id
                self.name = name
                self.access = access
                self.replyBehavior = replyBehavior
                self.isListening = isListening
                self.participationMode = participationMode
            }
        }

        let id: String
        let name: String
        let subtitle: String
        let symbolName: String
        let tint: Color
        let relationship: String
        let owner: String
        let accessSummary: String
        let permissionSummary: String
        let billingSummary: String
        let status: String
        let isListening: Bool
        let isOwnedByCurrentUser: Bool
        let phone: String?
        let email: String?
        let canManageParticipation: Bool
        let participationMode: ConversationParticipationMode
        let places: [Place]
        let shareText: String
        let primaryConversationId: String?
        let agentInboxId: String?
        let providerRawValue: String?

        init(
            id: String,
            name: String,
            subtitle: String,
            symbolName: String,
            tint: Color,
            relationship: String = "Connected by you",
            owner: String = "You",
            accessSummary: String = "Private in Your Space",
            permissionSummary: String = "Uses only context you allow",
            billingSummary: String = "Your account",
            status: String = "Available",
            isListening: Bool = false,
            isOwnedByCurrentUser: Bool = true,
            phone: String? = nil,
            email: String? = nil,
            canManageParticipation: Bool = false,
            participationMode: ConversationParticipationMode = .mentionsOnly,
            places: [Place] = [],
            shareText: String = "Add @doc to a group with me in Convos.",
            primaryConversationId: String? = nil,
            agentInboxId: String? = nil,
            providerRawValue: String? = nil
        ) {
            self.id = id
            self.name = name
            self.subtitle = subtitle
            self.symbolName = symbolName
            self.tint = tint
            self.relationship = relationship
            self.owner = owner
            self.accessSummary = accessSummary
            self.permissionSummary = permissionSummary
            self.billingSummary = billingSummary
            self.status = status
            self.isListening = isListening
            self.isOwnedByCurrentUser = isOwnedByCurrentUser
            self.phone = phone
            self.email = email
            self.canManageParticipation = canManageParticipation
            self.participationMode = participationMode
            self.places = places
            self.shareText = shareText
            self.primaryConversationId = primaryConversationId
            self.agentInboxId = agentInboxId
            self.providerRawValue = providerRawValue
        }
    }

    let agents: [Agent]
    let preferredChannel: AgentUseAnywhereChannel?
    let appConnectionsViewModel: ConnectionsListViewModel?
    let makePlaceConnectionsViewModel: ((Agent, Agent.Place) -> ConversationConnectionsViewModel?)?
    let onSetParticipationMode: ((Agent, Agent.Place?, ConversationParticipationMode) async throws -> Void)?

    init(
        agents: [Agent],
        preferredChannel: AgentUseAnywhereChannel? = nil,
        appConnectionsViewModel: ConnectionsListViewModel? = nil,
        makePlaceConnectionsViewModel: ((Agent, Agent.Place) -> ConversationConnectionsViewModel?)? = nil,
        onSetParticipationMode: ((Agent, Agent.Place?, ConversationParticipationMode) async throws -> Void)? = nil
    ) {
        self.agents = agents
        self.preferredChannel = preferredChannel
        self.appConnectionsViewModel = appConnectionsViewModel
        self.makePlaceConnectionsViewModel = makePlaceConnectionsViewModel
        self.onSetParticipationMode = onSetParticipationMode
    }

    private var ownedDocs: [Agent] {
        agents.filter { $0.providerRawValue == nil && $0.isOwnedByCurrentUser }
    }

    private var sharedDocs: [Agent] {
        agents.filter { $0.providerRawValue == nil && !$0.isOwnedByCurrentUser }
    }

    private var advancedEngines: [Agent] {
        agents.filter { $0.providerRawValue != nil }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(Color.black)
                    Text("One smart doc for every group.")
                        .font(.system(.title2, design: .rounded, weight: .black))
                        .foregroundStyle(Color.black)
                    Text("@doc listens, remembers, and turns conversation into shared docs, sheets, and calendars.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.black.opacity(0.72))
                }
                .padding(.vertical, DesignConstants.Spacing.step3x)
                .listRowBackground(Color.colorLava)
            }

            if let preferredChannel {
                Section {
                    Label {
                        Text("Choose a @doc you control. Its page shows the contact to add to \(preferredChannel.title) and exactly what it can hear or say.")
                    } icon: {
                        Image(systemName: preferredChannel.symbolName)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                } header: {
                    Text("Connect to \(preferredChannel.title)")
                }
            }

            if agents.isEmpty {
                emptyState
            } else {
                if !ownedDocs.isEmpty {
                    Section {
                        ForEach(ownedDocs) { doc in
                            agentRow(doc)
                        }
                    } header: {
                        Text("Docs you control")
                    } footer: {
                        Text("You choose where each @doc lives, what it can use, and when it speaks.")
                    }
                }

                if !sharedDocs.isEmpty {
                    Section {
                        ForEach(sharedDocs) { doc in
                            agentRow(doc)
                        }
                    } header: {
                        Text("Docs shared with you")
                    } footer: {
                        Text("Someone else controls these @docs, but your group can use what they make.")
                    }
                }

                if !advancedEngines.isEmpty {
                    Section {
                        ForEach(advancedEngines) { engine in
                            agentRow(engine)
                        }
                    } header: {
                        Text("Advanced engines")
                    } footer: {
                        Text("Optional private engines behind @doc. Group members never need to understand or configure these.")
                    }
                }
            }
        }
        .navigationTitle("@docs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func agentRow(_ agent: Agent) -> some View {
        NavigationLink {
            AgentAccessDetailView(
                agent: agent,
                preferredChannel: preferredChannel,
                appConnectionsViewModel: appConnectionsViewModel,
                makePlaceConnectionsViewModel: makePlaceConnectionsViewModel,
                onSetParticipationMode: onSetParticipationMode
            )
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: agent.providerRawValue == nil ? "doc.text.fill" : agent.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(agent.tint, in: .circle)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text(agent.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                            .lineLimit(1)
                        Text(agent.isOwnedByCurrentUser ? "Yours" : "\(agent.owner)’s")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(agent.isOwnedByCurrentUser ? Color.colorTextPrimaryInverted : Color.colorTextSecondary)
                            .padding(.horizontal, DesignConstants.Spacing.step2x)
                            .padding(.vertical, DesignConstants.Spacing.stepX)
                            .background(
                                agent.isOwnedByCurrentUser ? Color.colorBackgroundInverted : Color.colorFillMinimal,
                                in: .capsule
                            )
                            .lineLimit(1)
                    }
                    Text(agent.subtitle)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        Circle()
                            .fill(agent.isListening ? Color.green : Color.colorTextTertiary)
                            .frame(width: 6, height: 6)
                        Text(agent.status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, DesignConstants.Spacing.stepHalf)
        }
        .accessibilityValue("\(agent.relationship). \(agent.status). \(agent.permissionSummary)")
    }

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.colorTextSecondary)
            Text("Your first @doc is ready")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Start or join a group, then add @doc so everyone has one living place for what matters.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step8x)
        .listRowBackground(Color.clear)
    }
}

private struct AgentAccessDetailView: View {
    let agent: ManageAgentsView.Agent
    let preferredChannel: AgentUseAnywhereChannel?
    let appConnectionsViewModel: ConnectionsListViewModel?
    let makePlaceConnectionsViewModel: ((ManageAgentsView.Agent, ManageAgentsView.Agent.Place) -> ConversationConnectionsViewModel?)?
    let onSetParticipationMode: ((ManageAgentsView.Agent, ManageAgentsView.Agent.Place?, ConversationParticipationMode) async throws -> Void)?

    @State private var selectedMode: ConversationParticipationMode
    @State private var isSavingMode: Bool = false
    @State private var modeError: String?
    @State private var copiedContact: ContactKind?

    init(
        agent: ManageAgentsView.Agent,
        preferredChannel: AgentUseAnywhereChannel?,
        appConnectionsViewModel: ConnectionsListViewModel?,
        makePlaceConnectionsViewModel: ((ManageAgentsView.Agent, ManageAgentsView.Agent.Place) -> ConversationConnectionsViewModel?)?,
        onSetParticipationMode: ((ManageAgentsView.Agent, ManageAgentsView.Agent.Place?, ConversationParticipationMode) async throws -> Void)?
    ) {
        self.agent = agent
        self.preferredChannel = preferredChannel
        self.appConnectionsViewModel = appConnectionsViewModel
        self.makePlaceConnectionsViewModel = makePlaceConnectionsViewModel
        self.onSetParticipationMode = onSetParticipationMode
        _selectedMode = State(initialValue: agent.participationMode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                identity
                useAnywhere
                connections
                listeningReceipt
                permissionReceipt
                places
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.vertical, DesignConstants.Spacing.step6x)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t change @doc access", isPresented: Binding(
            get: { modeError != nil },
            set: { if !$0 { modeError = nil } }
        )) {
            Button("OK", role: .cancel) { modeError = nil }
        } message: {
            Text(modeError ?? "Try again in a moment.")
        }
    }

    private var identity: some View {
        HStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: agent.symbolName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 64)
                .background(agent.tint, in: .circle)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(agent.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text(agent.subtitle)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                Text(agent.isOwnedByCurrentUser ? "Owned by you" : "Owned by \(agent.owner)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(agent.isOwnedByCurrentUser ? Color.colorLava : Color.colorTextSecondary)
            }
        }
    }

    private var useAnywhere: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Add @doc anywhere")
                    .font(.title2.weight(.bold))
                Text("Add @doc to another group like a person. It listens, keeps the shared workspace current, and leaves useful docs, sheets, and calendars ready for everyone.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            contactCard
            participationControl
            channelInstructions

            ShareLink(item: agent.shareText) {
                Label("Share @doc setup", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        .colorBackgroundInverted,
                        in: .rect(cornerRadius: DesignConstants.CornerRadius.medium)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the iOS share sheet")
        }
    }

    private var contactCard: some View {
        VStack(spacing: 0) {
            contactRow(kind: .phone, value: agent.phone)
            Divider().padding(.leading, 44)
            contactRow(kind: .email, value: agent.email)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
    }

    private func contactRow(kind: ContactKind, value: String?) -> some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: kind.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
                .frame(width: 28, height: 44)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                Text(value ?? "Not available for this @doc")
                    .font(.subheadline.weight(value == nil ? .regular : .medium))
                    .foregroundStyle(value == nil ? Color.colorTextTertiary : Color.colorTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DesignConstants.Spacing.step2x)

            if let value {
                Button {
                    UIPasteboard.general.string = value
                    copiedContact = kind
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        if copiedContact == kind { copiedContact = nil }
                    }
                } label: {
                    Image(systemName: copiedContact == kind ? "checkmark" : "square.on.square")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedContact == kind ? "Copied" : "Copy \(kind.title.lowercased())")
            }
        }
        .frame(minHeight: 64)
    }

    private var participationControl: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            HStack {
                Text("How @doc joins in")
                    .font(.headline)
                Spacer(minLength: DesignConstants.Spacing.step2x)
                if isSavingMode { ProgressView().controlSize(.small) }
            }

            Picker("@doc participation", selection: $selectedMode) {
                Text("Listen").tag(ConversationParticipationMode.mentionsOnly)
                Text("Talk").tag(ConversationParticipationMode.speakFreely)
                Text("Pause").tag(ConversationParticipationMode.paused)
            }
            .pickerStyle(.segmented)
            .disabled(!agent.canManageParticipation || isSavingMode)
            .onChange(of: selectedMode) { previous, mode in
                guard previous != mode else { return }
                updateParticipation(from: previous, to: mode)
            }

            Text(participationDescription)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var participationDescription: String {
        guard agent.canManageParticipation else {
            return "Add this @doc to a supported group before choosing Listen, Talk, or Pause."
        }
        switch selectedMode {
        case .mentionsOnly:
            return "Listens continuously and only replies when someone mentions it."
        case .speakFreely:
            return "Listens continuously and can speak when it has something useful."
        case .paused:
            return "Stops receiving new group context and uses no credits."
        }
    }

    private var channelInstructions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(orderedChannels) { channel in
                HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                    Image(systemName: channel.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(preferredChannel == channel ? Color.colorTextPrimaryInverted : Color.colorTextPrimary)
                        .frame(width: 32, height: 32)
                        .background(
                            preferredChannel == channel ? Color.colorLava : Color.colorFillMinimal,
                            in: .circle
                        )
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text("Add to \(channel.title)")
                            .font(.subheadline.weight(.semibold))
                        Text(instructions(for: channel))
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, DesignConstants.Spacing.step3x)
                if channel != orderedChannels.last {
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    private var orderedChannels: [AgentUseAnywhereChannel] {
        guard let preferredChannel else { return AgentUseAnywhereChannel.allCases }
        return [preferredChannel] + AgentUseAnywhereChannel.allCases.filter { $0 != preferredChannel }
    }

    private func instructions(for channel: AgentUseAnywhereChannel) -> String {
        switch channel {
        case .iMessage:
            return agent.phone != nil || agent.email != nil
                ? "Copy a contact above, save it, then open the group details in Messages and add @doc."
                : "This @doc does not have a Messages contact yet. Share its setup while a contact address is provisioned."
        case .whatsapp:
            return agent.phone != nil
                ? "Save the phone number, then open Group info → Add participants and choose @doc."
                : "WhatsApp needs a phone number. This @doc has not published one yet."
        case .telegram:
            return "Share the @doc setup to Telegram, then follow its Add to group action when supported."
        }
    }

    private func updateParticipation(
        from previous: ConversationParticipationMode,
        to mode: ConversationParticipationMode
    ) {
        guard agent.canManageParticipation, let onSetParticipationMode else { return }
        isSavingMode = true
        Task { @MainActor in
            do {
                try await onSetParticipationMode(agent, nil, mode)
            } catch {
                selectedMode = previous
                modeError = error.localizedDescription
            }
            isSavingMode = false
        }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Connections")
                    .font(.title2.weight(.bold))
                Text("Connect once in Convos. Then choose each group below to decide where @doc can use it.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let appConnectionsViewModel {
                AgentAppConnectionsView(viewModel: appConnectionsViewModel)
            } else {
                Text("Connections are unavailable for this preview.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    private var listeningReceipt: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: agent.isListening ? "ear.fill" : "pause.fill")
                Text(agent.status)
                    .font(.headline)
            }
            Text(agent.accessSummary)
                .font(.body)
            Text(agent.permissionSummary)
                .font(.subheadline)
                .foregroundStyle(agent.isListening
                    ? Color.colorTextPrimaryInverted.opacity(0.78)
                    : Color.colorTextSecondary)
        }
        .foregroundStyle(agent.isListening ? .colorTextPrimaryInverted : .colorTextPrimary)
        .padding(DesignConstants.Spacing.step5x)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            agent.isListening ? Color.colorBackgroundInverted : Color.colorBackgroundRaisedSecondary,
            in: .rect(cornerRadius: DesignConstants.CornerRadius.medium)
        )
    }

    private var permissionReceipt: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Permissions")
                .font(.title2.weight(.bold))
            receiptRow("Your access", detail: agent.relationship, symbol: "person.crop.circle.badge.checkmark")
            Divider()
            receiptRow("@doc access", detail: agent.permissionSummary, symbol: "lock.shield.fill")
            Divider()
            receiptRow("Cost", detail: agent.billingSummary, symbol: "creditcard.fill")
        }
    }

    @ViewBuilder
    private var places: some View {
        if !agent.places.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text("Groups & permissions")
                        .font(.title2.weight(.bold))
                    Text("Control what @doc can hear, use, and do with each group of people.")
                        .font(.body)
                        .foregroundStyle(.colorTextSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(agent.places.enumerated()), id: \.element.id) { index, place in
                        Group {
                            if let connectionsViewModel = makePlaceConnectionsViewModel?(agent, place) {
                                NavigationLink {
                                    AgentPlacePermissionsView(
                                        agent: agent,
                                        place: place,
                                        connectionsViewModel: connectionsViewModel,
                                        onSetParticipationMode: onSetParticipationMode
                                    )
                                } label: {
                                    placeRow(place, showsDisclosure: true)
                                }
                            } else {
                                placeRow(place, showsDisclosure: true)
                            }
                        }
                        .padding(.vertical, DesignConstants.Spacing.step3x)
                        if index < agent.places.count - 1 {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    private func placeRow(_ place: ManageAgentsView.Agent.Place, showsDisclosure: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: place.isListening ? "ear.fill" : "pause.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(place.isListening ? Color.green : Color.colorTextSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(place.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("\(place.access) · \(place.replyBehavior)")
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            Spacer(minLength: 0)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextTertiary)
            }
        }
        .contentShape(.rect)
    }

    private func receiptRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }

    private enum ContactKind: Equatable {
        case phone
        case email

        var title: String {
            switch self {
            case .phone: "Phone"
            case .email: "Email"
            }
        }

        var symbolName: String {
            switch self {
            case .phone: "phone.fill"
            case .email: "envelope.fill"
            }
        }
    }
}

private struct AgentAppConnectionsView: View {
    @Bindable var viewModel: ConnectionsListViewModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: DesignConstants.Spacing.step3x) {
                    Image(systemName: symbolName(for: row))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(width: 40, height: 40)
                        .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.small))

                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text(row.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                        Text(row.isOn ? "Connected to your app" : row.subtitle)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: DesignConstants.Spacing.step2x)

                    Toggle("", isOn: Binding(
                        get: { row.isOn },
                        set: { _ in viewModel.toggle(row) }
                    ))
                    .labelsHidden()
                    .tint(.colorLava)
                    .disabled(viewModel.isConnecting || !row.isToggleEnabled)
                    .accessibilityLabel("\(row.isOn ? "Disconnect" : "Connect") \(row.title)")
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .frame(minHeight: 68)

                if index < viewModel.rows.count - 1 {
                    Divider().padding(.leading, 64)
                }
            }
        }
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.medium))
        .task { viewModel.refresh() }
    }

    private func symbolName(for row: ConnectionsListViewModel.Row) -> String {
        switch row.source {
        case .cloud(let service, _):
            service.iconSystemName
        case .device(let kind, _):
            kind.systemImageName
        }
    }
}

private struct AgentPlacePermissionsView: View {
    let agent: ManageAgentsView.Agent
    let place: ManageAgentsView.Agent.Place
    @Bindable var connectionsViewModel: ConversationConnectionsViewModel
    let onSetParticipationMode: ((ManageAgentsView.Agent, ManageAgentsView.Agent.Place?, ConversationParticipationMode) async throws -> Void)?

    @State private var selectedMode: ConversationParticipationMode
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(
        agent: ManageAgentsView.Agent,
        place: ManageAgentsView.Agent.Place,
        connectionsViewModel: ConversationConnectionsViewModel,
        onSetParticipationMode: ((ManageAgentsView.Agent, ManageAgentsView.Agent.Place?, ConversationParticipationMode) async throws -> Void)?
    ) {
        self.agent = agent
        self.place = place
        self.connectionsViewModel = connectionsViewModel
        self.onSetParticipationMode = onSetParticipationMode
        _selectedMode = State(initialValue: place.participationMode)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text("\(agent.name) in \(place.name)")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("These permissions apply only to this @doc with this group of people.")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("Participation", selection: $selectedMode) {
                    Text("Listen").tag(ConversationParticipationMode.mentionsOnly)
                    Text("Talk").tag(ConversationParticipationMode.speakFreely)
                    Text("Pause").tag(ConversationParticipationMode.paused)
                }
                .pickerStyle(.segmented)
                .disabled(isSaving || onSetParticipationMode == nil)
                .onChange(of: selectedMode) { previous, mode in
                    guard previous != mode else { return }
                    updateParticipation(from: previous, to: mode)
                }

                Text(participationDescription)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            } header: {
                Text("What @doc can do")
            }

            ConversationConnectionsSection(viewModel: connectionsViewModel)
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t change permissions", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Try again in a moment.")
        }
    }

    private var participationDescription: String {
        switch selectedMode {
        case .mentionsOnly:
            "Listens continuously and replies only when someone mentions it."
        case .speakFreely:
            "Listens continuously and can speak when it has something useful."
        case .paused:
            "Receives no new group context until you turn it back on."
        }
    }

    private func updateParticipation(
        from previous: ConversationParticipationMode,
        to mode: ConversationParticipationMode
    ) {
        guard let onSetParticipationMode else { return }
        isSaving = true
        Task { @MainActor in
            do {
                try await onSetParticipationMode(agent, place, mode)
            } catch {
                selectedMode = previous
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

#Preview {
    NavigationStack {
        ManageAgentsView(agents: [
            .init(
                id: "quarter-planner",
                name: "Quarter’s Planner",
                subtitle: "Smart group doc",
                symbolName: "sparkles",
                tint: .colorLava,
                relationship: "Shared with you in Toronto Coworking",
                owner: "Quarter",
                accessSummary: "Listening continuously in Toronto Coworking",
                permissionSummary: "Full Convo context · private replies · responds on mention",
                billingSummary: "Quarter pays",
                status: "Listening in 1 Place",
                isListening: true,
                isOwnedByCurrentUser: false,
                phone: "+1 615 555 0142",
                email: "quarter-planner@agents.convos.org",
                canManageParticipation: true,
                places: [
                    .init(
                        id: "toronto",
                        name: "Toronto Coworking",
                        access: "Full Convo context",
                        replyBehavior: "Responds on mention",
                        isListening: true
                    ),
                ]
            ),
            .init(
                id: "codex",
                name: "Codex",
                subtitle: "OpenAI coding engine",
                symbolName: "chevron.left.forwardslash.chevron.right",
                tint: .black
            ),
        ])
    }
}
