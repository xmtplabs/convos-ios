import Foundation
import GRDB

// MARK: - Mock Extensions for Testing and Previews

public extension Conversation {
    static func mock(
        id: String = "mock-conversation-id",
        clientId: String = "mock-client-id",
        inboxId: String = "mock-inbox-id",
        name: String? = "Mock Conversation",
        members: [ConversationMember]? = nil,
        isUnread: Bool = false,
        isPinned: Bool = false,
        isMuted: Bool = false,
        lastMessageText: String = "This is a preview of the last message"
    ) -> Conversation {
        let mockMembers = members ?? [
            .mock(isCurrentUser: true),
            .mock(isCurrentUser: false)
        ]
        let creator = mockMembers.first(where: { $0.isCurrentUser }) ?? mockMembers.first ?? .mock(isCurrentUser: true)

        return Conversation(
            id: id,
            clientConversationId: "client-\(id)",
            inboxId: inboxId,
            clientId: clientId,
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
            lastMessage: isUnread ? MessagePreview(
                text: lastMessageText,
                createdAt: Date()
            ) : nil,
            imageURL: nil,
            includeInfoInPublicPreview: false,
            isDraft: id.hasPrefix("draft-"),
            invite: nil,
            expiresAt: nil,
            debugInfo: ConversationDebugInfo.empty,
            isLocked: false
        )
    }

    static func empty(id: String = "", clientId: String = "") -> Conversation {
        Conversation(
            id: id,
            clientConversationId: id,
            inboxId: "",
            clientId: clientId,
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
            lastMessage: nil,
            imageURL: nil,
            includeInfoInPublicPreview: false,
            isDraft: true,
            invite: nil,
            expiresAt: .distantFuture,
            debugInfo: .empty,
            isLocked: false
        )
    }
}

public extension ConversationMember {
    static func mock(
        isCurrentUser: Bool = false,
        name: String? = nil,
        role: MemberRole = .member
    ) -> ConversationMember {
        let profile = Profile.mock(
            inboxId: isCurrentUser ? "current-user" : "other-user-\(UUID().uuidString)",
            name: name ?? (isCurrentUser ? "You" : "John Doe")
        )

        return ConversationMember(
            profile: profile,
            role: isCurrentUser ? .admin : role,
            isCurrentUser: isCurrentUser
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
            conversation: .mock(),
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: status,
            content: .text(text),
            date: date,
            reactions: reactions
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

// Extension moved from MessagesListItemType.swift to keep summary here
public extension ConversationUpdate {
    var summary: String {
        let creatorDisplayName = creator.isCurrentUser ? "You" : creator.profile.displayName
        if !addedMembers.isEmpty && !removedMembers.isEmpty {
            return "\(creatorDisplayName) added and removed members from the convo"
        } else if !addedMembers.isEmpty {
            if addedMembers.count == 1, let member = addedMembers.first,
               member.isCurrentUser {
                let asString = member.profile.name != nil ? "as \(member.profile.displayName)" : "anonymously as \(member.profile.displayName)"
                return "You joined \(asString)"
            }
            return "\(addedMembers.formattedNamesString) joined by invitation"
        } else if let metadataChange = metadataChanges.first,
                  metadataChange.field == .name,
                  let updatedName = metadataChange.newValue {
            return "\(creatorDisplayName) changed the convo name to \"\(updatedName)\""
        } else if let metadataChange = metadataChanges.first,
                  metadataChange.field == .image,
                  metadataChange.newValue != nil {
            return "\(creatorDisplayName) changed the convo photo"
        } else if let metadataChange = metadataChanges.first,
                  metadataChange.field == .description,
                  let newValue = metadataChange.newValue {
            return "\(creatorDisplayName) changed the convo description to \"\(newValue)\""
        } else if !removedMembers.isEmpty {
            return ""
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
