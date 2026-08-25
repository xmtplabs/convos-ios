import ConvosComposer
import ConvosCore
import SwiftUI

/// One access-aware roster for every agent the person can use. Ownership is a
/// permission attribute, never a separate product area: owned Convos agents,
/// connected external agents, and agents shared through a Convo all render in
/// the same list and disclose the same context boundary.
struct ManageAgentsView: View {
    struct Agent: Identifiable {
        struct Place: Identifiable {
            let id: String
            let name: String
            let access: String
            let replyBehavior: String
            let isListening: Bool
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
            places: [Place] = [],
            shareText: String = "Try this agent with me in Convos.",
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
            self.places = places
            self.shareText = shareText
            self.primaryConversationId = primaryConversationId
            self.agentInboxId = agentInboxId
            self.providerRawValue = providerRawValue
        }
    }

    let agents: [Agent]

    private var listeningAgents: [Agent] {
        agents.filter(\.isListening)
    }

    private var availableAgents: [Agent] {
        agents.filter { !$0.isListening }
    }

    var body: some View {
        List {
            Section {
                Text("Every agent you can use—yours, connected, or shared—with the exact context and permissions it has.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
                    .listRowBackground(Color.clear)
            }

            if agents.isEmpty {
                emptyState
            } else {
                if !listeningAgents.isEmpty {
                    Section("Listening continuously") {
                        ForEach(listeningAgents) { agent in
                            agentRow(agent)
                        }
                    }
                }

                if !availableAgents.isEmpty {
                    Section("Available to you") {
                        ForEach(availableAgents) { agent in
                            agentRow(agent)
                        }
                    }
                }
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func agentRow(_ agent: Agent) -> some View {
        NavigationLink {
            AgentAccessDetailView(agent: agent)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: agent.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(agent.tint, in: .circle)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(agent.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)
                    Text(agent.relationship)
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
            Text("Your starter agent is getting ready")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Start or join a Convo, then give an agent continuous Listen access when you are ready.")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step8x) {
                identity
                listeningReceipt
                permissionReceipt
                places
                useAnywhere
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.vertical, DesignConstants.Spacing.step6x)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
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
                Text("Owned by \(agent.owner)")
                    .font(.caption.weight(.medium))
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
            receiptRow("Agent access", detail: agent.permissionSummary, symbol: "lock.shield.fill")
            Divider()
            receiptRow("Cost", detail: agent.billingSummary, symbol: "creditcard.fill")
        }
    }

    @ViewBuilder
    private var places: some View {
        if !agent.places.isEmpty {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                Text("Places")
                    .font(.title2.weight(.bold))
                VStack(spacing: 0) {
                    ForEach(Array(agent.places.enumerated()), id: \.element.id) { index, place in
                        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
                            Image(systemName: place.isListening ? "ear.fill" : "pause.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(place.isListening ? Color.green : Color.colorTextSecondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                                Text(place.name)
                                    .font(.body.weight(.semibold))
                                Text("\(place.access) · \(place.replyBehavior)")
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                            }
                            Spacer(minLength: 0)
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

    private var useAnywhere: some View {
        ShareLink(item: agent.shareText) {
            Label("Share this agent anywhere", systemImage: "square.and.arrow.up")
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
}

#Preview {
    NavigationStack {
        ManageAgentsView(agents: [
            .init(
                id: "quarter-planner",
                name: "Quarter’s Planner",
                subtitle: "Convos Agent",
                symbolName: "sparkles",
                tint: .colorLava,
                relationship: "Shared with you in Toronto Coworking",
                owner: "Quarter",
                accessSummary: "Listening continuously in Toronto Coworking",
                permissionSummary: "Full Convo context · private replies · responds on mention",
                billingSummary: "Quarter pays",
                status: "Listening in 1 Place",
                isListening: true,
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
                subtitle: "OpenAI coding agent",
                symbolName: "chevron.left.forwardslash.chevron.right",
                tint: .black
            ),
        ])
    }
}
