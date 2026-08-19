import Foundation
import GRDB

/// Which conversation a capability approval's grant writes scope to.
///
/// In a plain group the pill's conversation and the grant's conversation are
/// the same. In an agent DM they are not: the backend authorizes tool calls
/// against the agent's primary group, so a grant scoped to the DM's own id
/// authorizes nothing. The DM approval therefore resolves its origin group
/// and scopes every grant-side write there, while the result message stays in
/// the DM. An agent DM whose origin cannot be resolved is an explicit blocked
/// case, never a silent fallthrough to the DM id.
public enum CapabilityGrantScope: Equatable, Sendable {
    /// Not an agent DM: today's exact behavior, scope = the conversation.
    case conversation(String)
    /// Agent DM with a resolved, verified origin group.
    case originGroup(String)
    /// Agent DM whose origin is unknown, missing, or failed the approval-time
    /// consistency check: the approval is blocked.
    case unresolvableOrigin(CapabilityGrantScopeBlockReason)

    /// The conversation id grant-side writes target, or nil when blocked.
    public var grantScopeConversationId: String? {
        switch self {
        case .conversation(let id): return id
        case .originGroup(let id): return id
        case .unresolvableOrigin: return nil
        }
    }
}

/// Why an agent-DM approval is blocked. Drives the sheet copy: a user who
/// left the origin group gets the departed wording; every other case reads
/// as the transient still-syncing form (the dominant blocked population is a
/// reinstalled device whose origin group has not synced yet, and it
/// self-heals -- the pill stays pending and the same tap succeeds later).
public enum CapabilityGrantScopeBlockReason: Equatable, Sendable {
    /// No `agent_dm_origin` row and no readable appData marker.
    case originUnknown
    /// Origin id known but the conversation is not present locally.
    case originNotSynced
    /// The user is no longer a member of the origin group (or has a
    /// recorded departure).
    case userNotInOrigin
    /// The asking agent is no longer a member of the origin group (a rebind
    /// left the DM's recorded origin stale).
    case agentNotInOrigin
    /// The recorded origin is not a group conversation: it names the DM
    /// itself or another agent DM. The marker is member-writable, so this is
    /// treated as untrusted input -- a DM-scoped grant authorizes nothing.
    case originNotAGroup
    /// The origin group's identity could not be derived at all (hydration
    /// failed), so the sheet cannot truthfully disclose which conversation
    /// the grant would scope to. Ordinary unnamed groups do not land here:
    /// their identity derives from the member list, exactly as the rest of
    /// the app names them.
    case originUnidentifiable

    public var userFacingMessage: String {
        switch self {
        case .userNotInOrigin:
            return "This request belongs to a conversation you're no longer in."
        case .originUnidentifiable:
            return "Can't identify the conversation this request belongs to."
        case .originUnknown, .originNotSynced, .agentNotInOrigin, .originNotAGroup:
            return "Can't approve from this chat right now — still syncing. Try again in a moment."
        }
    }

    /// Stable identifier for the blocked-path telemetry counter.
    public var telemetryValue: String {
        switch self {
        case .originUnknown: return "origin_unknown"
        case .originNotSynced: return "origin_not_synced"
        case .userNotInOrigin: return "user_not_in_origin"
        case .agentNotInOrigin: return "agent_not_in_origin"
        case .originNotAGroup: return "origin_not_a_group"
        case .originUnidentifiable: return "origin_unidentifiable"
        }
    }
}

/// A resolved scope plus the display name the approval sheet must show.
/// The named-consent rule: the sheet cannot render its approve control
/// without the resolved name of the conversation the grant will scope to.
public struct CapabilityGrantScopeResolution: Equatable, Sendable {
    public let scope: CapabilityGrantScope
    /// Name of the scope conversation; nil when blocked. Falls back to a
    /// generic noun when the conversation row carries no name, so a resolved
    /// scope always names its target.
    public let scopeDisplayName: String?

    public init(scope: CapabilityGrantScope, scopeDisplayName: String?) {
        self.scope = scope
        self.scopeDisplayName = scopeDisplayName
    }
}

extension CapabilityGrantScopeResolution {
    /// Database-driven resolution. `liveMarkerOrigin` is consulted only when
    /// the mirror row is absent: it reads the DM's own XMTP appData marker,
    /// the authoritative source the row mirrors (covers a failed mirror write
    /// and a reinstalled device whose row has not been rebuilt yet).
    static func resolve(
        conversationId: String,
        isAgentDm: Bool,
        askerInboxId: String,
        viewerInboxId: String,
        dbReader: any DatabaseReader,
        liveMarkerOrigin: @Sendable () async -> String?
    ) async -> CapabilityGrantScopeResolution {
        guard isAgentDm else {
            // A nameless plain group keeps a nil name: the view model falls
            // back to the conversation's own user-facing display name, which
            // the user is already looking at -- never a generic noun.
            let name: String? = try? await dbReader.read { db in
                try DBConversation.fetchOne(db, id: conversationId)?.name
            }
            return CapabilityGrantScopeResolution(
                scope: .conversation(conversationId),
                scopeDisplayName: (name?.isEmpty == false) ? name : nil
            )
        }

        let mirroredOrigin: String? = try? await dbReader.read { db in
            try DBAgentDmOrigin.originConversationId(for: conversationId, in: db)
        }
        var originId: String? = mirroredOrigin
        if originId == nil {
            originId = await liveMarkerOrigin()
        }
        guard let originId, !originId.isEmpty else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.originUnknown), scopeDisplayName: nil)
        }
        // The marker is member-writable: an origin naming the DM itself is
        // untrusted input steering the grant back into the DM scope.
        guard originId != conversationId else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.originNotAGroup), scopeDisplayName: nil)
        }

        let check: OriginConsistencyCheck? = try? await dbReader.read { db in
            let origin = try DBConversation.fetchOne(db, id: originId)
            let userIsMember = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == originId)
                .filter(DBConversationMember.Columns.inboxId == viewerInboxId)
                .fetchCount(db) > 0
            let userDeparted = try DBMemberDeparture
                .filter(DBMemberDeparture.Columns.conversationId == originId)
                .filter(DBMemberDeparture.Columns.inboxId == viewerInboxId)
                .fetchCount(db) > 0
            let agentIsMember = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == originId)
                .filter(DBConversationMember.Columns.inboxId == askerInboxId)
                .fetchCount(db) > 0
            return OriginConsistencyCheck(
                origin: origin,
                userIsMember: userIsMember,
                userDeparted: userDeparted,
                agentIsMember: agentIsMember
            )
        }
        guard let check, let origin = check.origin else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.originNotSynced), scopeDisplayName: nil)
        }
        guard check.userIsMember, !check.userDeparted else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.userNotInOrigin), scopeDisplayName: nil)
        }
        guard check.agentIsMember else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.agentNotInOrigin), scopeDisplayName: nil)
        }
        // An origin that is itself an agent DM can never back a grant; the
        // membership checks pass trivially for any DM the viewer and agent
        // share, so this guard is what stops a steered marker.
        guard !origin.isAgentDm else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.originNotAGroup), scopeDisplayName: nil)
        }
        // Named consent requires the origin's real identity. An explicit
        // name is returned verbatim; an unnamed group derives its title from
        // the member list -- the same derivation every other surface uses to
        // name it -- so ordinary unnamed groups approve normally. Only a
        // group whose identity cannot be derived at all blocks.
        let originDisplayName: String? = try? await dbReader.read { db in
            let details = try DBConversation
                .filter(DBConversation.Columns.id == originId)
                .detailedConversationQuery()
                .fetchOne(db)
            let currentInboxId = try DBInbox.currentInboxId(db) ?? viewerInboxId
            return details?.hydrateConversation(currentInboxId: currentInboxId).displayName
        }
        guard let originDisplayName, !originDisplayName.isEmpty else {
            return CapabilityGrantScopeResolution(scope: .unresolvableOrigin(.originUnidentifiable), scopeDisplayName: nil)
        }
        return CapabilityGrantScopeResolution(scope: .originGroup(originId), scopeDisplayName: originDisplayName)
    }

    private struct OriginConsistencyCheck {
        let origin: DBConversation?
        let userIsMember: Bool
        let userDeparted: Bool
        let agentIsMember: Bool
    }
}
