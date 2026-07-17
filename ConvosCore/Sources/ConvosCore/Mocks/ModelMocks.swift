import Foundation
import GRDB

// MARK: - Mock Extensions for Testing and Previews

public extension Conversation {
    static func mock(
        id: String = "mock-conversation-id",
        name: String? = "Mock Conversation",
        members: [ConversationMember]? = nil,
        isUnread: Bool = false,
        isPinned: Bool = false,
        isMuted: Bool = false,
        invite: Invite? = nil,
        lastMessageText: String = "This is a preview of the last message",
        wasCreatedFromAgentBuilder: Bool = false
    ) -> Conversation {
        let mockMembers = members ?? [
            .mock(isCurrentUser: true),
            .mock(isCurrentUser: false)
        ]
        let creator = mockMembers.first(where: { $0.isCurrentUser }) ?? mockMembers.first ?? .mock(isCurrentUser: true)

        return Conversation(
            id: id,
            clientConversationId: "client-\(id)",
            creator: creator,
            createdAt: Date(),
            consent: .allowed,
            kind: mockMembers.count == 2 ? .dm : .group,
            name: name,
            description: "This is a mock conversation for testing",
            members: mockMembers,
            otherMember: mockMembers.first(where: { !$0.isCurrentUser }),
            messages: [],
            isPinned: isPinned,
            isUnread: isUnread,
            isMuted: isMuted,
            pinnedOrder: isPinned ? 0 : nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            lastMessage: isUnread ? MessagePreview(
                text: lastMessageText,
                createdAt: Date()
            ) : nil,
            imageURL: nil,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            includeInfoInPublicPreview: false,
            isDraft: id.hasPrefix("draft-"),
            invite: invite,
            expiresAt: nil,
            debugInfo: ConversationDebugInfo.empty,
            isLocked: false,
            agentJoinStatus: nil,
            hasHadVerifiedAgent: mockMembers.contains(where: \.agentVerification.isConvosAgent),
            wasCreatedFromAgentBuilder: wasCreatedFromAgentBuilder
        )
    }

    static func mockPendingInvite(
        id: String = "draft-pending-invite",
        name: String? = "Pending Convo"
    ) -> Conversation {
        mock(
            id: id,
            name: name,
            members: [.mock(isCurrentUser: false)]
        )
    }

    /// Mock conversation backing the chats-tab empty-state CTA carousel.
    /// Built as a group with two other members so `avatarType` resolves to
    /// the supplied emoji rather than a single member's profile, and the
    /// rendered title is the supplied name. The other members' profiles carry
    /// no avatar because member avatars outrank the conversation emoji in
    /// `avatarType`; a mock avatar would render the CTA as a cluster of
    /// never-loading initials instead of the emoji. `lastMessageText` is
    /// attached whenever present; the pinned-item preview bubble only shows it
    /// once `isUnread` flips true.
    static func emptyStateMock(
        id: String,
        name: String,
        emoji: String,
        isUnread: Bool = false,
        lastMessageText: String? = nil
    ) -> Conversation {
        let avatarlessMember: (String) -> ConversationMember = { inboxId in
            ConversationMember(
                profile: Profile(
                    inboxId: inboxId,
                    conversationId: "client-\(id)",
                    name: "John Doe",
                    avatar: nil
                ),
                role: .member,
                isCurrentUser: false
            )
        }
        let members: [ConversationMember] = [
            .mock(isCurrentUser: true),
            avatarlessMember("empty-state-member-1"),
            avatarlessMember("empty-state-member-2"),
        ]
        let creator: ConversationMember = members.first(where: { $0.isCurrentUser }) ?? .mock(isCurrentUser: true)
        var lastMessage: MessagePreview?
        if let lastMessageText {
            lastMessage = MessagePreview(text: lastMessageText, createdAt: Date())
        }
        return Conversation(
            id: id,
            clientConversationId: "client-\(id)",
            creator: creator,
            createdAt: Date(),
            consent: .allowed,
            kind: .group,
            name: name,
            description: nil,
            members: members,
            otherMember: nil,
            messages: [],
            isPinned: false,
            isUnread: isUnread,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            lastMessage: lastMessage,
            imageURL: nil,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: emoji,
            includeInfoInPublicPreview: false,
            isDraft: false,
            invite: nil,
            expiresAt: nil,
            debugInfo: ConversationDebugInfo.empty,
            isLocked: false,
            agentJoinStatus: nil,
            hasHadVerifiedAgent: false,
            wasCreatedFromAgentBuilder: false
        )
    }

    static func empty(id: String = "") -> Conversation {
        Conversation(
            id: id,
            clientConversationId: id,
            creator: .empty(isCurrentUser: true),
            createdAt: .distantFuture,
            consent: .allowed,
            kind: .group,
            name: "",
            description: "",
            members: [],
            otherMember: nil,
            messages: [],
            isPinned: false,
            isUnread: false,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            lastMessage: nil,
            imageURL: nil,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            includeInfoInPublicPreview: false,
            isDraft: true,
            invite: nil,
            expiresAt: .distantFuture,
            debugInfo: .empty,
            isLocked: false,
            agentJoinStatus: nil,
            hasHadVerifiedAgent: false,
            wasCreatedFromAgentBuilder: false
        )
    }

    /// Draft placeholder seeded with members. Used by the contacts
    /// picker flow so the chat header renders the contact's name and
    /// avatar from the moment the new-convo sheet opens, instead of
    /// flickering through "New Convo" while the state machine creates
    /// the real conversation. `kind` is always `.group` because the
    /// state machine's `handleCreate` calls `client.prepareConversation()`
    /// which always returns a `Group` - synthesizing `.dm` here would
    /// mean the synthetic briefly renders DM-styled before flipping
    /// to group when the publisher emits the real conversation.
    static func draft(id: String, seededMembers: [ConversationMember]) -> Conversation {
        let creator: ConversationMember = seededMembers.first(where: { $0.isCurrentUser }) ?? .empty(isCurrentUser: true)
        return Conversation(
            id: id,
            clientConversationId: id,
            creator: creator,
            createdAt: .distantFuture,
            consent: .allowed,
            kind: .group,
            name: nil,
            description: nil,
            members: seededMembers,
            otherMember: nil,
            messages: [],
            isPinned: false,
            isUnread: false,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            lastMessage: nil,
            imageURL: nil,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            includeInfoInPublicPreview: false,
            isDraft: true,
            invite: nil,
            expiresAt: .distantFuture,
            debugInfo: .empty,
            isLocked: false,
            agentJoinStatus: nil,
            hasHadVerifiedAgent: false,
            wasCreatedFromAgentBuilder: false
        )
    }
}

public extension ConversationMember {
    static func mock(
        isCurrentUser: Bool = false,
        name: String? = nil,
        role: MemberRole = .member,
        isAgent: Bool = false,
        agentVerification: AgentVerification = .unverified
    ) -> ConversationMember {
        let profile = Profile.mock(
            inboxId: isCurrentUser ? "current-user" : "other-user-\(UUID().uuidString)",
            name: name ?? (isCurrentUser ? "You" : "John Doe")
        )

        return ConversationMember(
            profile: profile,
            role: isCurrentUser ? .admin : role,
            isCurrentUser: isCurrentUser,
            isAgent: isAgent,
            agentVerification: agentVerification
        )
    }

    static func empty(role: MemberRole = .member, isCurrentUser: Bool = false) -> ConversationMember {
        ConversationMember(profile: .empty(), role: role, isCurrentUser: isCurrentUser)
    }
}

public extension Message {
    static func mock(
        text: String = "Mock message",
        sender: ConversationMember? = nil,
        status: MessageStatus = .published,
        date: Date = Date(),
        reactions: [MessageReaction] = []
    ) -> Message {
        let mockSender = sender ?? .mock(isCurrentUser: false)
        let id = "mock-message-\(UUID().uuidString)"

        return Message(
            id: id,
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: status,
            content: .text(text),
            date: date,
            reactions: reactions
        )
    }

    static func mock(
        content: MessageContent,
        sender: ConversationMember? = nil,
        status: MessageStatus = .published,
        date: Date = Date(),
        reactions: [MessageReaction] = []
    ) -> Message {
        let mockSender = sender ?? .mock(isCurrentUser: false)
        let id = "mock-message-\(UUID().uuidString)"

        return Message(
            id: id,
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: status,
            content: content,
            date: date,
            reactions: reactions
        )
    }

    static func mockWithAttachment(
        url: URL,
        sender: ConversationMember? = nil,
        status: MessageStatus = .published,
        date: Date = Date()
    ) -> Message {
        let mockSender = sender ?? .mock(isCurrentUser: false)
        let id = "mock-message-\(UUID().uuidString)"

        return Message(
            id: id,
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: status,
            content: .attachment(HydratedAttachment(key: url.absoluteString)),
            date: date,
            reactions: []
        )
    }

    static func mockWithAttachments(
        urls: [URL],
        sender: ConversationMember? = nil,
        status: MessageStatus = .published,
        date: Date = Date()
    ) -> Message {
        let mockSender = sender ?? .mock(isCurrentUser: false)
        let id = "mock-message-\(UUID().uuidString)"

        return Message(
            id: id,
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: status,
            content: .attachments(urls.map { HydratedAttachment(key: $0.absoluteString) }),
            date: date,
            reactions: []
        )
    }
}

public extension ConversationUpdate {
    static func mock(
        creator: ConversationMember? = nil,
        addedMembers: [ConversationMember] = [],
        removedMembers: [ConversationMember] = []
    ) -> ConversationUpdate {
        ConversationUpdate(
            creator: creator ?? .mock(isCurrentUser: false, name: "Alice"),
            addedMembers: addedMembers.isEmpty ? [.mock(isCurrentUser: false, name: "Bob")] : addedMembers,
            removedMembers: removedMembers,
            metadataChanges: []
        )
    }
}

/// Resolves a member's rendered display name with the precedence:
/// contact-list override, then per-conversation profile name, then
/// "Agent" for known agents or "Somebody" for unnamed humans.
/// `isCurrentUser` always renders as "You" for system messages.
///
/// Hoisted to file scope so its branches don't count against
/// `ConversationUpdate.summary(memberNameOverride:)`'s cyclomatic
/// complexity score.
private func resolvedMemberDisplayName(
    _ member: ConversationMember,
    memberNameOverride: (String) -> String?
) -> String {
    if member.isCurrentUser { return "You" }
    // Contact-name override wins over per-conversation profile name.
    // Contact list is the user's deliberate naming choice and should
    // appear consistently across every member-name surface.
    if let overridden = memberNameOverride(member.profile.inboxId), !overridden.isEmpty {
        return overridden
    }
    if let name = member.profile.name, !name.isEmpty { return name }
    // Mirror `Profile.displayName`: known agents read as "Agent",
    // unknown / human profiles read as "Somebody".
    return member.isAgent ? "Agent" : "Somebody"
}

private func summaryFromFirstMetadataChange(
    metadataChanges: [ConversationUpdate.MetadataChange],
    creatorDisplayName: String
) -> String? {
    guard let metadataChange = metadataChanges.first else { return nil }
    switch metadataChange.field {
    case .name:
        guard let updatedName = metadataChange.newValue else { return nil }
        if updatedName.isEmpty {
            return "\(creatorDisplayName) removed the convo name"
        }
        return "\(creatorDisplayName) changed the convo name to \"\(updatedName)\""
    case .image:
        guard metadataChange.newValue != nil else { return nil }
        return "\(creatorDisplayName) changed the convo photo"
    case .description:
        guard let newValue = metadataChange.newValue else { return nil }
        if newValue.isEmpty {
            return "\(creatorDisplayName) removed the convo description"
        }
        return "\(creatorDisplayName) changed the convo description to \"\(newValue)\""
    case .expiresAt:
        guard metadataChange.newValue != nil else { return nil }
        if let duration = metadataChange.oldValue {
            return "\(creatorDisplayName) set this convo to explode in \(duration)"
        }
        return "\(creatorDisplayName) set this convo to explode"
    case .metadata, .unknown:
        return nil
    }
}

// Extension moved from MessagesListItemType.swift to keep summary here
public extension ConversationUpdate {
    var summary: String {
        summary(memberNameOverride: { _ in nil })
    }

    /// `summary` with an inbox → contact-name override applied to every
    /// member name in the rendered string. The override **wins** over the
    /// per-conversation profile name when present — contact-list names
    /// are the user's deliberate naming choice and should appear
    /// consistently across every surface. Pass `{ _ in nil }` (or use the
    /// default `summary` getter) for legacy behavior with no override.
    func summary(memberNameOverride: (String) -> String?) -> String {
        // Creator label is rendered as "You" for self per the original
        // logic; for non-self callers the same precedence applies. The
        // member-name resolution is hoisted to the free file-scope
        // `resolvedMemberDisplayName` so its branches don't inflate this
        // function's cyclomatic complexity score.
        let creatorDisplayName: String = creator.isCurrentUser
            ? "You"
            : resolvedMemberDisplayName(creator, memberNameOverride: memberNameOverride)

        if !addedMembers.isEmpty && !removedMembers.isEmpty {
            return "\(creatorDisplayName) added and removed members from the convo"
        } else if !addedMembers.isEmpty {
            if addedMembers.count == 1, let member = addedMembers.first,
               member.isCurrentUser {
                let asString = "as \(member.profile.displayName)"
                return "You joined \(asString)"
            }
            if addedMembers.count == 1, let member = addedMembers.first {
                return "\(resolvedMemberDisplayName(member, memberNameOverride: memberNameOverride)) joined · Invited by \(creatorDisplayName)"
            }
            let added = addedMembers.formattedNamesString(memberNameOverride: memberNameOverride)
            return "\(added) joined · Invited by \(creatorDisplayName)"
        } else if let metaSummary = summaryFromFirstMetadataChange(
            metadataChanges: metadataChanges,
            creatorDisplayName: creatorDisplayName
        ) {
            return metaSummary
        } else if !removedMembers.isEmpty {
            if removedMembers.count == 1, let member = removedMembers.first {
                // A self-leave stores the leaver as both initiator and removed
                // member (see the leave-request ingest); anything else is an
                // admin-initiated removal and credits the remover.
                let isSelfLeave = member.profile.inboxId == creator.profile.inboxId
                if member.isCurrentUser {
                    return isSelfLeave ? "You left the convo" : "You were removed from the convo"
                }
                let memberName = resolvedMemberDisplayName(member, memberNameOverride: memberNameOverride)
                if isSelfLeave {
                    return "\(memberName) left"
                }
                return "\(memberName) left · Removed by \(creatorDisplayName)"
            }
            let removed = removedMembers.formattedNamesString(memberNameOverride: memberNameOverride)
            return "\(removed) left"
        } else {
            return ""
        }
    }
}

public extension Invite {
    static func mock(
        conversationId: String = "mock-conversation-id"
    ) -> Invite {
        Invite(
            conversationId: conversationId,
            urlSlug: "mock-invite-slug",
            expiresAt: nil,
            expiresAfterUse: false
        )
    }
}

public extension MessageReply {
    static func mock(
        text: String = "This is a reply",
        sender: ConversationMember? = nil,
        replyContent: MessageContent? = nil,
        parentText: String = "Original message that was replied to",
        parentContent: MessageContent? = nil,
        parentSender: ConversationMember? = nil,
        status: MessageStatus = .published,
        date: Date = Date(),
        reactions: [MessageReaction] = []
    ) -> MessageReply {
        let mockSender = sender ?? .mock(isCurrentUser: true)
        let mockParentSender = parentSender ?? .mock(isCurrentUser: false, name: "Jane")

        let parentMessage = Message(
            id: "parent-\(UUID().uuidString)",
            sender: mockParentSender,
            source: mockParentSender.isCurrentUser ? .outgoing : .incoming,
            status: .published,
            content: parentContent ?? .text(parentText),
            date: date.addingTimeInterval(-60),
            reactions: []
        )

        return MessageReply(
            id: "reply-\(UUID().uuidString)",
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: status,
            content: replyContent ?? .text(text),
            date: date,
            parentMessage: parentMessage,
            reactions: reactions
        )
    }
}
