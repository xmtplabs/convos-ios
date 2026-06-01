import ConvosInvites
import Foundation
import GRDB

/// Resolves whether the current user already belongs to the conversation an
/// invite points to, and that conversation's member count. The in-chat invite
/// card uses this to show "N members" instead of "Tap to join" once the user
/// has joined the linked conversation.
public protocol InviteMembershipResolving: Sendable {
    /// The member count of the local conversation this invite slug points to,
    /// but only when the current user is already a member. Returns nil when the
    /// user has not joined (or the conversation isn't stored locally), in which
    /// case the card keeps its "Tap to join" call to action.
    func memberCount(forInviteSlug inviteSlug: String) async -> Int?
}

/// Stand-in resolver for previews / tests where no session is wired. Always
/// reports "not a member" so the card renders its default state.
public struct NoopInviteMembershipResolver: InviteMembershipResolving {
    public init() {}

    public func memberCount(forInviteSlug inviteSlug: String) async -> Int? {
        nil
    }
}

/// GRDB-backed resolver. Maps an invite slug to a local conversation via the
/// invite payload's stable `tag` (matched against `DBConversation.inviteTag`),
/// mirroring `ConversationStateMachine`'s join lookup. The slug itself
/// (`DBInvite.urlSlug`) only exists for conversations the current user created,
/// whereas `inviteTag` is present for joined conversations too, so it's the
/// reliable link for both cases.
public struct DatabaseInviteMembershipResolver: InviteMembershipResolving {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func memberCount(forInviteSlug inviteSlug: String) async -> Int? {
        guard let signedInvite = try? SignedInvite.fromInviteCode(inviteSlug) else {
            return nil
        }
        let inviteTag = signedInvite.invitePayload.tag
        guard !inviteTag.isEmpty else { return nil }

        let currentInboxId = MessagesRepository.currentInboxId(from: databaseReader)
        do {
            let conversation: Conversation? = try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.inviteTag == inviteTag)
                    .detailedConversationQuery()
                    .fetchOne(db)?
                    .hydrateConversation(currentInboxId: currentInboxId)
            }
            guard let conversation, conversation.hasJoined else { return nil }
            return conversation.members.count
        } catch {
            Log.error("Failed to resolve invite membership for slug: \(error)")
            return nil
        }
    }
}
