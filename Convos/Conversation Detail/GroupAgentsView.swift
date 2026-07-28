import ConvosCore
import SwiftUI

/// The group-scoped Agents directory.
///
/// Consumer language stays focused on who can help and how the group keeps
/// that help powered. Provider and harness details remain available deeper in
/// each profile, but are not required to understand the shared model.
struct GroupAgentsView: View {
    enum Action {
        case openAgent(ConversationMember)
        case addCredits
        case setGroupLimit
        case bringOwnAI(String)
        case addConvosAgent
    }

    let conversation: Conversation
    let onAction: (Action) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    private var agents: [ConversationMember] {
        conversation.members.filter(\.isAgent)
    }

    private var groupAgentName: String {
        agents.first?.profile.displayName ?? "Group Agent"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    introduction
                    agentDirectory
                    sharedPower
                    bringYourOwnAI
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(.colorBackgroundSurfaceless)
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationBackground(.colorBackgroundSurfaceless)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who can help this group")
                .font(.largeTitle.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("Agents join as visible members. Everyone can see who added them, what they can access, and whether they can listen or speak.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentDirectory: some View {
        VStack(spacing: 0) {
            ForEach(Array(agents.enumerated()), id: \.element.profile.inboxId) { index, agent in
                if index > 0 {
                    Divider()
                        .padding(.leading, 58)
                }

                Button {
                    onAction(.openAgent(agent))
                } label: {
                    HStack(spacing: 12) {
                        agentAvatar(agent, isGroupAgent: index == 0)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.profile.displayName)
                                .font(.headline)
                                .foregroundStyle(.colorTextPrimary)

                            Text(index == 0
                                 ? "Available to everyone · Shared group credits"
                                 : "Added to this group · Listen only")
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        Text("Open")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.colorLava)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.colorBorderSubtle, lineWidth: 1)
        )
    }

    private func agentAvatar(_ agent: ConversationMember, isGroupAgent: Bool) -> some View {
        let initial = agent.profile.displayName.first.map(String.init) ?? "A"

        return Circle()
            .fill(.colorTextPrimary)
            .frame(width: 46, height: 46)
            .overlay {
                if isGroupAgent {
                    Image(systemName: "sparkles")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.colorTextPrimaryInverted)
                } else {
                    Text(initial)
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimaryInverted)
                }
            }
    }

    private var sharedPower: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SHARED POWER")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorTextTertiary)

            Text("Everyone can use \(groupAgentName)")
                .font(.title2.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("One shared balance powers the agent for the whole group. Anyone can add credits. Change who can use them or set a group limit anytime.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                powerSettingRow(title: "Who can use it", value: "Everyone", icon: "person.2.fill")
                Divider()
                    .padding(.leading, 44)
                powerSettingRow(title: "Group spending limit", value: "No limit set", icon: "gauge.with.dots.needle.33percent")
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.colorBackgroundSurfaceless)
            )

            HStack(spacing: 10) {
                Button {
                    onAction(.addCredits)
                } label: {
                    Label("Add credits", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.colorTextPrimary)

                Button {
                    onAction(.setGroupLimit)
                } label: {
                    Text("Set a $10 limit")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.colorTextPrimary)
            }

            Text("If power runs out, paid work pauses and the group can decide who wants to help.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.colorFillMinimal)
        )
    }

    private func powerSettingRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 32)

            Text(title)
                .font(.subheadline)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.colorTextPrimary)
        .padding(.vertical, 13)
    }

    private var bringYourOwnAI: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BRING YOUR OWN AI")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorTextTertiary)

            Text("Already use an AI service? Bring its powers to the group.")
                .font(.title3.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("Connect the AI you already pay for as another way to help. It gets a Convos identity, stays visible to everyone, and starts in Listen only mode.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                providerButton("ChatGPT")
                providerButton("Claude")
                providerButton("Hermes")
                providerButton("OpenClaw")
                providerButton("Custom")
            }

            Button {
                onAction(.addConvosAgent)
            } label: {
                Label("Add another Convos agent", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.colorLava)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.colorFillMinimal)
        )
    }

    private func providerButton(_ name: String) -> some View {
        Button {
            onAction(.bringOwnAI(name))
        } label: {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(.colorBorderSubtle)
    }
}
