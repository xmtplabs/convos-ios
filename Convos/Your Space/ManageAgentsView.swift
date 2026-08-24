import ConvosComposer
import ConvosCore
import SwiftUI

// Pushed from the agent switcher's "Manage" action in the Your Space dock.
// A placeholder surface for managing connected personal agents - it lists the
// agents that are currently connected and is otherwise a mock.
struct ManageAgentsView: View {
    struct Agent: Identifiable {
        let id: String
        let name: String
        let subtitle: String
        let symbolName: String
        let tint: Color
    }

    let agents: [Agent]

    var body: some View {
        List {
            if agents.isEmpty {
                emptyState
            } else {
                Section("Connected") {
                    ForEach(agents) { agent in
                        agentRow(agent)
                    }
                }
            }
        }
        .navigationTitle("Manage agents")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func agentRow(_ agent: Agent) -> some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: agent.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .background(agent.tint, in: .circle)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(agent.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                Text(agent.subtitle)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding(.vertical, DesignConstants.Spacing.stepHalf)
    }

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "powerplug.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.colorTextSecondary)
            Text("No agents connected")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Add an agent from the dock to manage it here.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step8x)
        .listRowBackground(Color.clear)
    }
}

#Preview {
    NavigationStack {
        ManageAgentsView(agents: [
            .init(id: "town", name: "Ray", subtitle: "Town agent", symbolName: "building.2.crop.circle.fill", tint: .green),
            .init(id: "codex", name: "Codex", subtitle: "Open AI", symbolName: "chevron.left.forwardslash.chevron.right", tint: .black),
        ])
    }
}
