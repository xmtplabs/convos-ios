import ConvosCore
import SwiftUI

struct AgentProvidersView: View {
    let dependencies: AgentRelayDependencies
    let session: any SessionManagerProtocol
    @State private var connectedProviders: Set<ExternalAgentProvider> = []

    var body: some View {
        List {
            Section {
                ForEach(ExternalAgentProvider.allCases) { provider in
                    NavigationLink {
                        destination(for: provider)
                    } label: {
                        providerRow(provider)
                    }
                }
            } footer: {
                Text("Use an agent you already set up on its own platform.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadConnections() }
    }

    @ViewBuilder
    private func destination(for provider: ExternalAgentProvider) -> some View {
        if connectedProviders.contains(provider) {
            AgentChatView(provider: provider, dependencies: dependencies, session: session)
        } else {
            switch provider {
            case .town:
                TownSetupView(dependencies: dependencies, session: session)
            case .tasklet:
                TaskletSetupView(dependencies: dependencies, session: session)
            }
        }
    }

    private func providerRow(_ provider: ExternalAgentProvider) -> some View {
        let isConnected: Bool = connectedProviders.contains(provider)
        return HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: provider.symbolName)
                .foregroundStyle(isConnected ? .green : .colorTextPrimary)
                .frame(width: DesignConstants.Spacing.step8x)
            Text(provider.displayName)
                .foregroundStyle(.colorTextPrimary)
            Spacer()
            Text(isConnected ? "Connected" : "Set up")
                .font(.subheadline)
                .foregroundStyle(isConnected ? .green : .colorTextSecondary)
        }
    }

    private func reloadConnections() {
        connectedProviders = Set(ExternalAgentProvider.allCases.filter { provider in
            (try? dependencies.connectionStore.load(provider: provider)) != nil
        })
    }
}
