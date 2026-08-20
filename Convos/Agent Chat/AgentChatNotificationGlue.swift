import ConvosCore
import Foundation
import SwiftUI

extension Notification.Name {
    static let agentRelayNotificationTapped: Notification.Name = Notification.Name("agentRelayNotificationTapped")
}

@MainActor
final class AgentRelayDependencies {
    let database: AgentChatDatabase
    let repository: AgentChatRepository
    let writer: AgentChatWriter
    let connectionStore: AgentConnectionStore
    let client: AgentRelayClient
    let recoveryCoordinator: AgentRelayRecoveryCoordinator
    let mcpURL: URL

    init(environment: AppEnvironment) throws {
        let database = try AgentChatDatabase(environment: environment)
        let repository = AgentChatRepository(database: database)
        let writer = AgentChatWriter(database: database)
        let apiClient = ConvosAPIClientFactory.client(environment: environment)
        let api = AgentRelayHTTPAPI(apiClient: apiClient)
        let history = AgentHistoryBuilder(repository: repository)
        let client = AgentRelayClient(
            api: api,
            webhook: AgentWebhookURLSessionTransport(),
            store: writer,
            history: history
        )
        self.database = database
        self.repository = repository
        self.writer = writer
        self.connectionStore = AgentConnectionStore(environment: environment)
        self.client = client
        self.recoveryCoordinator = AgentRelayRecoveryCoordinator(
            client: client,
            repository: repository,
            writer: writer
        )
        self.mcpURL = try Self.makeMCPURL(environment: environment)
    }

    func collectForegroundPush(_ payload: AgentRelayPushPayload.Parsed) async {
        do {
            let result = try await client.collect(requestId: payload.requestId, provider: payload.provider)
            guard result != nil else { return }
            ConvosAppDelegate.removeDeliveredAgentRelayNotification(requestId: payload.requestId)
        } catch {
            Log.warning("Agent relay foreground collection failed: \(error.localizedDescription)")
        }
    }

    func recoverOnLaunch() async {
        await recoveryCoordinator.runOnLaunch()
        removeNotificationsForCompletedTurns()
    }

    func recoverOnForeground() async {
        await recoveryCoordinator.runOnForeground()
        removeNotificationsForCompletedTurns()
    }

    func removeNotificationsForCompletedTurns() {
        let turns: [AgentTurn] = (try? repository.turns(limit: 200)) ?? []
        turns.filter { $0.status == .completed }.forEach { turn in
            ConvosAppDelegate.removeDeliveredAgentRelayNotification(requestId: turn.requestId)
        }
    }

    private static func makeMCPURL(environment: AppEnvironment) throws -> URL {
        let apiBaseURL = SharedAppConfiguration(environment: environment).apiBaseURL
        guard let baseURL = URL(string: apiBaseURL) else {
            throw URLError(.badURL)
        }
        return baseURL.appending(path: "v2/agent-relay/mcp")
    }
}

private struct AgentRelayDependenciesKey: EnvironmentKey {
    static let defaultValue: AgentRelayDependencies? = nil
}

extension EnvironmentValues {
    var agentRelayDependencies: AgentRelayDependencies? {
        get { self[AgentRelayDependenciesKey.self] }
        set { self[AgentRelayDependenciesKey.self] = newValue }
    }
}

struct AgentChatDraft: Identifiable {
    let id: UUID = UUID()
    let provider: ExternalAgentProvider
    let text: String
}

struct AgentRelayNotificationPresentationModifier: ViewModifier {
    let dependencies: AgentRelayDependencies?
    let session: any SessionManagerProtocol
    @State private var presentedProvider: ExternalAgentProvider?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .agentRelayNotificationTapped)) { notification in
                presentAgentChat(notification)
            }
            .sheet(item: $presentedProvider) { provider in
                if let dependencies {
                    NavigationStack {
                        AgentChatView(
                            provider: provider,
                            dependencies: dependencies,
                            session: session
                        )
                    }
                }
            }
    }

    private func presentAgentChat(_ notification: Notification) {
        let rawProvider: String? = notification.userInfo?["provider"] as? String
        let pushedProvider: ExternalAgentProvider? = rawProvider.flatMap(ExternalAgentProvider.init(rawValue:))
        let provider: ExternalAgentProvider = pushedProvider ?? dependencies?.connectionStore.activeProvider ?? .town
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            presentedProvider = provider
        }
    }
}

extension View {
    func agentRelayNotificationPresentation(
        dependencies: AgentRelayDependencies?,
        session: any SessionManagerProtocol
    ) -> some View {
        modifier(AgentRelayNotificationPresentationModifier(dependencies: dependencies, session: session))
    }
}

enum AgentChatVisibility {
    @MainActor static var isVisible: Bool = false
}

extension ExternalAgentProvider: @retroactive Identifiable {
    public var id: String { rawValue }
}
