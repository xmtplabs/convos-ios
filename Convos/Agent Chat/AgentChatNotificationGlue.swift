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

    init(
        database: AgentChatDatabase,
        connectionStore: AgentConnectionStore,
        client: AgentRelayClient,
        mcpURL: URL
    ) {
        let repository = AgentChatRepository(database: database)
        let writer = AgentChatWriter(database: database)
        self.database = database
        self.repository = repository
        self.writer = writer
        self.connectionStore = connectionStore
        self.client = client
        self.recoveryCoordinator = AgentRelayRecoveryCoordinator(
            client: client,
            repository: repository,
            writer: writer
        )
        self.mcpURL = mcpURL
    }

    func collectForegroundPush(
        _ payload: AgentRelayPushPayload.Parsed,
        session: any SessionManagerProtocol
    ) async {
        guard await waitForAuthenticatedSession(session) else { return }
        do {
            let result = try await client.collect(requestId: payload.requestId, provider: payload.provider)
            guard result != nil else { return }
            ConvosAppDelegate.removeDeliveredAgentRelayNotification(requestId: payload.requestId)
        } catch {
            Log.warning("Agent relay foreground collection failed: \(error.localizedDescription)")
        }
    }

    func recoverOnLaunch(session: any SessionManagerProtocol) async {
        guard await waitForAuthenticatedSession(session) else { return }
        await recoveryCoordinator.runOnLaunch()
        removeNotificationsForCompletedTurns()
    }

    func recoverOnForeground(session: any SessionManagerProtocol) async {
        guard await waitForAuthenticatedSession(session) else { return }
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

    private func waitForAuthenticatedSession(_ session: any SessionManagerProtocol) async -> Bool {
        do {
            _ = try await session.messagingService().sessionStateManager.waitForInboxReadyResult()
            return true
        } catch {
            Log.warning("Agent relay work skipped because the authenticated session is unavailable")
            return false
        }
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

/// Reads the provider a tapped agent notification (or an in-chat agent
/// switch) names. The shell routes it onto the Agents tab's navigation path;
/// there is no sheet, because the Agents tab is where an agent chat lives.
enum AgentRelayNotificationRoute {
    @MainActor
    static func provider(
        from notification: Notification,
        dependencies: AgentRelayDependencies?
    ) -> ExternalAgentProvider {
        let rawProvider: String? = notification.userInfo?["provider"] as? String
        let pushedProvider: ExternalAgentProvider? = rawProvider.flatMap(ExternalAgentProvider.init(rawValue:))
        return pushedProvider ?? dependencies?.connectionStore.activeProvider ?? .town
    }
}

enum AgentChatVisibility {
    @MainActor static var visibleProvider: ExternalAgentProvider?
}

enum AgentRelayNotificationPresentation {
    static func shouldSuppress(
        visibleProvider: ExternalAgentProvider?,
        notificationProvider: ExternalAgentProvider?
    ) -> Bool {
        guard let notificationProvider else { return false }
        return visibleProvider == notificationProvider
    }
}

extension ExternalAgentProvider: @retroactive Identifiable {
    public var id: String { rawValue }
}
