import ConvosCore
import ConvosCoreiOS
import Foundation
import UserNotifications

struct AgentRelayNotificationHandler {
    func handle(_ request: UNNotificationRequest) async -> UNNotificationContent {
        let original = request.content
        guard let payload = AgentRelayPushPayload.parse(original.userInfo) else {
            return original
        }

        do {
            let result = try await collect(payload)
            return AgentRelayNotificationContent.content(
                for: .collected(result),
                original: original,
                provider: payload.provider
            )
        } catch {
            Log.warning("Agent relay notification collection failed: \(error.localizedDescription)")
            return AgentRelayNotificationContent.content(
                for: .failed,
                original: original,
                provider: payload.provider
            )
        }
    }

    private func collect(_ payload: AgentRelayPushPayload.Parsed) async throws -> AgentRelayTurnResult? {
        let environment = try NotificationExtensionEnvironment.getEnvironment()
        ConvosLog.configure(environment: environment)
        let database = try AgentChatDatabase(environment: environment, maximumReaderCount: 1)
        let repository = AgentChatRepository(database: database)
        let writer = AgentChatWriter(database: database)
        let apiClient = ConvosAPIClientFactory.client(
            environment: environment,
            overrideJWTToken: payload.apiJWT
        )
        let client = AgentRelayClient(
            api: AgentRelayHTTPAPI(apiClient: apiClient),
            webhook: AgentWebhookURLSessionTransport(),
            store: writer,
            history: AgentHistoryBuilder(repository: repository)
        )
        return try await withTimeout(seconds: Constant.timeout) {
            try await client.collect(requestId: payload.requestId, provider: payload.provider)
        }
    }

    private enum Constant {
        static let timeout: TimeInterval = 15
    }
}
