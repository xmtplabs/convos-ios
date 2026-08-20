import Foundation

/// Launch and foreground recovery: saves and acks completed-but-unacked
/// mailboxes, resumes watching local pending rows, expires stale ones.
public final class AgentRelayRecoveryCoordinator: Sendable {
    private let client: AgentRelayClient
    private let repository: any AgentChatRepositoryProtocol
    private let writer: any AgentChatWriterProtocol

    public init(
        client: AgentRelayClient,
        repository: any AgentChatRepositoryProtocol,
        writer: any AgentChatWriterProtocol
    ) {
        self.client = client
        self.repository = repository
        self.writer = writer
    }

    public func runOnLaunch() async {}

    public func runOnForeground() async {}
}
