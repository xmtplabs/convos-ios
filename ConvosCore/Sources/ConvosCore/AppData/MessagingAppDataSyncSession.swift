import Foundation
@preconcurrency import XMTPiOS

/// The XMTP-backed `AppDataSyncSession`: the only production code that reads or
/// writes the raw `appData` blob on a group. Everything else goes through
/// `AppDataCoordinator`, which owns merge, verification, the 8 KiB cap,
/// backoff, and durability - so this session carries none of that. It resolves
/// a conversation id to its group and does one read or one write.
///
/// This is boundary code (it uses XMTP types directly, like the writers), so it
/// has no meaningful unit test; it is verified via integration and manual runs.
struct MessagingAppDataSyncSession: AppDataSyncSession {
    private let sessionStateManager: any SessionStateManagerProtocol

    init(sessionStateManager: any SessionStateManagerProtocol) {
        self.sessionStateManager = sessionStateManager
    }

    private func group(for conversationId: String) async throws -> XMTPiOS.Group {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw AppDataSyncSessionError.conversationNotFound(conversationId: conversationId)
        }
        return group
    }

    func readAppData(conversationId: String) async throws -> String? {
        let group = try await group(for: conversationId)
        return try group.appData()
    }

    func writeAppData(conversationId: String, appData: String) async throws {
        let group = try await group(for: conversationId)
        try await group.updateAppData(appData: appData)
    }
}
