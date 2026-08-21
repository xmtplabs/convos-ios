import Foundation

/// The coordinator's network seam: raw appData string access for one
/// conversation. The XMTP-backed implementation is the only production code
/// allowed to touch `group.appData()` / `group.updateAppData` - everything
/// else goes through `AppDataCoordinator`.
protocol AppDataSyncSession: Sendable {
    /// The raw appData string from the group; nil or empty when unset.
    func readAppData(conversationId: String) async throws -> String?
    func writeAppData(conversationId: String, appData: String) async throws
}

enum AppDataSyncSessionError: Error {
    /// The conversation cannot be resolved to a group (deleted, never synced,
    /// or a DM). Pending changes for it are dropped, never retried forever.
    case conversationNotFound(conversationId: String)
}
