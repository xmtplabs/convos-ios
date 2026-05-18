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

/// Snapshot of the current device's XMTP inbox state, surfaced for
/// the debug "Installations" view. The list is sorted oldest-first
/// so the row pinned to the top is the most stable record.
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
