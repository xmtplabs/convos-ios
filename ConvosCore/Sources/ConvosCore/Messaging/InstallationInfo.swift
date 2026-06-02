import Foundation

/// Lightweight wrapper around an XMTP installation entry. Mirrors
/// `XMTPiOS.Installation` without leaking the SDK type through
/// `XMTPClientProvider` (per the codebase's XMTP abstraction rule).
public struct InstallationInfo: Sendable, Hashable {
    public let id: String
    public let createdAt: Date?

    public init(id: String, createdAt: Date?) {
        self.id = id
        self.createdAt = createdAt
    }
}

/// Snapshot of the current inbox's libxmtp installation set. Used by the
/// "Devices" settings screen to list other devices paired under the same
/// inbox. The list is sorted oldest-first so the row pinned to the top is
/// the most stable record.
public struct InstallationsSnapshot: Sendable {
    public let inboxId: String
    public let currentInstallationId: String
    public let installations: [InstallationInfo]

    public init(inboxId: String, currentInstallationId: String, installations: [InstallationInfo]) {
        self.inboxId = inboxId
        self.currentInstallationId = currentInstallationId
        self.installations = installations
    }
}
