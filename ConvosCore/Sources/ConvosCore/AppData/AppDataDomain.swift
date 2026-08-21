import Foundation

/// One independently-owned sub-field of the conversation's appData blob. Each
/// domain has exactly one `AppDataUpdater` merge rule; a pending local change
/// is stored per (conversation, domain, scopeKey).
///
/// Fields with no domain (`spaceUrl`, server-enriched `agentDm` sub-fields)
/// are read-only authority fields: with no updater registered they always ride
/// the fresh network blob and a client can never carry a stale copy of them
/// over a network write.
public enum AppDataDomain: String, CaseIterable, Codable, Sendable {
    /// The invite tag (`tag`): seeded at creation, rotated on lock/unlock,
    /// restored by self-healing.
    case inviteTag = "invite_tag"
    /// One member's entry in `profiles`, scoped by inbox id (`scopeKey`).
    case profile
    /// `participationMode` for agents in the conversation.
    case participation
    /// `expiresAtUnix`.
    case expiry
    /// `emoji`, with ensure-if-absent semantics (a peer's value wins).
    case emoji
    /// The `agentDm` marker, written once by the DM's creator.
    case agentDm = "agent_dm"
    /// Clearing a legacy `encryptedGroupImage` ref after a plain image upload.
    case legacyImageCleanup = "legacy_image_cleanup"
}
