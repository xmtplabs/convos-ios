import ConvosCore
import SwiftUI

/// The group-scoped Agents directory.
///
/// Consumer language stays focused on who can help, who owns each agent, and
/// whether that member has chosen to let the rest of the group use it.
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
                    memberOwnedPower
                    taskInvitation
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
            Text("Every member can bring their own agent")
                .font(.largeTitle.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("Members invite agents to become visible members in the group chat. Each person owns their agent and decides whether its power is private, approval-only, or available to everyone.")
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
                                 ? "Shane’s Convos agent · Group use allowed"
                                 : "Shane’s agent · Private power")
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

    private var memberOwnedPower: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MEMBER-OWNED POWER")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorTextTertiary)

            Text("Your agent. Your power. Your choice.")
                .font(.title2.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("\(groupAgentName) belongs to Shane. He currently lets the group use it, but he can require approval or keep it private without removing it from the Convo.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                powerSettingRow(title: "Owner", value: "Shane", icon: "person.crop.circle")
                Divider()
                    .padding(.leading, 44)
                powerSettingRow(title: "Group access", value: "Allowed", icon: "person.2.fill")
                Divider()
                    .padding(.leading, 44)
                powerSettingRow(title: "Shane’s group limit", value: "$10", icon: "gauge.with.dots.needle.33percent")
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
                    Label("Power my agent", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.colorTextPrimary)

                Button {
                    onAction(.setGroupLimit)
                } label: {
                    Text("Who can use mine")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.colorTextPrimary)
            }

            Text("Every member can bring their own Convos agent or connect the AI service they already use. No one has to depend on someone else’s power.")
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

    private var taskInvitation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THE TASK BECOMES THE INVITATION")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorLava)

            Text("Brent taps “Find 15 more places.”")
                .font(.title3.bold())
                .foregroundStyle(.colorTextPrimaryInverted)

            Text("If Brent cannot use Shane’s agent, Convos asks Brent to add his own or request access. "
                + "His contribution brings new power into the group—and Brent gets the credit for improving the work.")
                .font(.body)
                .foregroundStyle(.colorTextPrimaryInverted.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onAction(.addConvosAgent)
            } label: {
                Label("Add my agent to do this task", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.colorBackgroundSurfaceless)
                    .clipShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.colorTextPrimary)
        .clipShape(.rect(cornerRadius: 24))
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
            Text("INVITE YOUR AGENT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.colorTextTertiary)

            Text("Already use an AI service? Bring it into the Convo.")
                .font(.title3.bold())
                .foregroundStyle(.colorTextPrimary)

            Text("It becomes your visible agent in this group. Its power is private by default. You decide separately whether it can listen, speak, remember, act, or help other members.")
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
                Label("Create my Convos agent", systemImage: "plus")
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
