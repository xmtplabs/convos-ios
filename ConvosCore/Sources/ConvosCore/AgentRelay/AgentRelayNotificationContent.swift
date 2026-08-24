import UserNotifications

public enum AgentRelayNotificationCollectionOutcome {
    case collected(AgentRelayTurnResult?)
    case failed
}

public enum AgentRelayNotificationContent {
    public static func content(
        for outcome: AgentRelayNotificationCollectionOutcome,
        original: UNNotificationContent,
        provider: ExternalAgentProvider?
    ) -> UNNotificationContent {
        switch outcome {
        case .collected(let result):
            guard let result else {
                // Nil is unattributable here without a payload provider or local row; foreground recovery collects it on next launch.
                return original
            }
            let content = original.mutableCopy() as? UNMutableNotificationContent
                ?? UNMutableNotificationContent()
            content.title = provider?.displayName ?? "Agent"
            content.body = String(result.message.prefix(Constant.previewLength))
            content.threadIdentifier = AgentRelayPushPayload.notificationType
            return content
        case .failed:
            return original
        }
    }

    private enum Constant {
        static let previewLength: Int = 120
    }
}
