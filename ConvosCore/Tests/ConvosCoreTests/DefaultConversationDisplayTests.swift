@testable import ConvosCore
import Foundation
import Testing

@Suite("Default Conversation Display Tests")
struct DefaultConversationDisplayTests {
    // MARK: - EmojiSelector Tests

    @Test("EmojiSelector returns consistent emoji for same identifier")
    func emojiSelectorConsistency() {
        let identifier = "test-conversation-id"
        let emoji1 = EmojiSelector.emoji(for: identifier)
        let emoji2 = EmojiSelector.emoji(for: identifier)
        #expect(emoji1 == emoji2)
    }

    @Test("EmojiSelector returns different emojis for different identifiers")
    func emojiSelectorDifferentIdentifiers() {
        let identifiers = ["id-1", "id-2", "id-3", "id-4", "id-5"]
        let emojis = Set(identifiers.map { EmojiSelector.emoji(for: $0) })
        #expect(emojis.count > 1)
    }

    @Test("EmojiSelector returns emoji from predefined list")
    func emojiSelectorFromPredefinedList() {
        let testIdentifiers = ["abc", "xyz", "123", "test", "conversation"]
        for identifier in testIdentifiers {
            let emoji = EmojiSelector.emoji(for: identifier)
            #expect(EmojiSelector.emojis.contains(emoji))
        }
    }

    @Test("EmojiSelector handles empty identifier")
    func emojiSelectorEmptyIdentifier() {
        let emoji = EmojiSelector.emoji(for: "")
        #expect(EmojiSelector.emojis.contains(emoji))
    }

    @Test("EmojiSelector handles unicode identifiers")
    func emojiSelectorUnicodeIdentifier() {
        let emoji = EmojiSelector.emoji(for: "日本語テスト")
        #expect(EmojiSelector.emojis.contains(emoji))
    }

    // MARK: - Profile Array formattedNamesString Tests

    @Test("Empty array returns empty string")
    func emptyArrayReturnsEmptyString() {
        let profiles: [Profile] = []
        #expect(profiles.formattedNamesString == "")
    }

    @Test("Single named profile returns name")
    func singleNamedProfile() {
        let profiles = [Profile.mock(name: "Alice")]
        #expect(profiles.formattedNamesString == "Alice")
    }

    @Test("Single anonymous profile returns Somebody")
    func singleAnonymousProfile() {
        let profiles = [Profile.empty(inboxId: "1")]
        #expect(profiles.formattedNamesString == "Somebody")
    }

    @Test("Two named profiles joined with ampersand")
    func twoNamedProfiles() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob")
        ]
        #expect(profiles.formattedNamesString == "Alice & Bob")
    }

    @Test("Two anonymous profiles returns Somebodies")
    func twoAnonymousProfiles() {
        let profiles = [
            Profile.empty(inboxId: "1"),
            Profile.empty(inboxId: "2")
        ]
        #expect(profiles.formattedNamesString == "Somebodies")
    }

    @Test("Three named profiles joined with commas")
    func threeNamedProfiles() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob"),
            Profile.mock(name: "Charlie")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob, Charlie")
    }

    @Test("Named profiles sorted alphabetically")
    func namedProfilesSortedAlphabetically() {
        let profiles = [
            Profile.mock(name: "Zoe"),
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Mike")
        ]
        #expect(profiles.formattedNamesString == "Alice, Mike, Zoe")
    }

    @Test("Mixed named and one anonymous")
    func mixedNamedAndOneAnonymous() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.empty(inboxId: "anon"),
            Profile.mock(name: "Bob")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob, Somebody")
    }

    @Test("Mixed named and multiple anonymous exceeding limit")
    func mixedNamedAndMultipleAnonymous() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.empty(inboxId: "anon1"),
            Profile.empty(inboxId: "anon2"),
            Profile.mock(name: "Bob")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob and 2 others")
    }

    @Test("One named and one anonymous joined with ampersand")
    func oneNamedOneAnonymous() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.empty(inboxId: "anon")
        ]
        #expect(profiles.formattedNamesString == "Alice & Somebody")
    }

    // MARK: - Profile Array Helper Tests

    @Test("hasAnyNamedProfile returns true when named profile exists")
    func hasAnyNamedProfileTrue() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.empty(inboxId: "anon")
        ]
        #expect(profiles.hasAnyNamedProfile == true)
    }

    @Test("hasAnyNamedProfile returns false when all anonymous")
    func hasAnyNamedProfileFalse() {
        let profiles = [
            Profile.empty(inboxId: "anon1"),
            Profile.empty(inboxId: "anon2")
        ]
        #expect(profiles.hasAnyNamedProfile == false)
    }

    @Test("hasAnyAvatar returns true when profile has avatar")
    func hasAnyAvatarTrue() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.empty(inboxId: "anon")
        ]
        #expect(profiles.hasAnyAvatar == true)
    }

    @Test("hasAnyAvatar returns false when no avatars")
    func hasAnyAvatarFalse() {
        let profiles = [
            Profile.empty(inboxId: "anon1"),
            Profile.empty(inboxId: "anon2")
        ]
        #expect(profiles.hasAnyAvatar == false)
    }

    // MARK: - Conversation computedDisplayName Tests

    @Test("Conversation with custom name uses custom name")
    func conversationCustomName() {
        let conversation = Conversation.mock(name: "My Custom Name")
        #expect(conversation.computedDisplayName == "My Custom Name")
    }

    @Test("Conversation without name computes from members")
    func conversationComputedFromMembers() {
        let members = [
            ConversationMember.mock(isCurrentUser: true, name: "You"),
            ConversationMember.mock(isCurrentUser: false, name: "Alice")
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        #expect(conversation.computedDisplayName == "Alice")
    }

    @Test("Empty conversation shows New Convo")
    func emptyConversationShowsNewConvo() {
        let members = [ConversationMember.mock(isCurrentUser: true, name: "You")]
        let conversation = Conversation.mock(name: nil, members: members)
        #expect(conversation.computedDisplayName == "New Convo")
    }

    // MARK: - Conversation isFullyAnonymous Tests

    @Test("isFullyAnonymous true when all other members have no name")
    func isFullyAnonymousTrue() {
        let members = [
            ConversationMember.mock(isCurrentUser: true, name: "You"),
            ConversationMember(
                profile: Profile.empty(inboxId: "anon1"),
                role: .member,
                isCurrentUser: false
            ),
            ConversationMember(
                profile: Profile.empty(inboxId: "anon2"),
                role: .member,
                isCurrentUser: false
            )
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        #expect(conversation.isFullyAnonymous == true)
    }

    @Test("isFullyAnonymous false when any other member has name")
    func isFullyAnonymousFalse() {
        let members = [
            ConversationMember.mock(isCurrentUser: true, name: "You"),
            ConversationMember.mock(isCurrentUser: false, name: "Alice"),
            ConversationMember(
                profile: Profile.empty(inboxId: "anon"),
                role: .member,
                isCurrentUser: false
            )
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        #expect(conversation.isFullyAnonymous == false)
    }

    @Test("isFullyAnonymous false when no other members")
    func isFullyAnonymousFalseNoOtherMembers() {
        let members = [ConversationMember.mock(isCurrentUser: true, name: "You")]
        let conversation = Conversation.mock(name: nil, members: members)
        #expect(conversation.isFullyAnonymous == false)
    }

    // MARK: - Conversation defaultEmoji Tests

    @Test("defaultEmoji is deterministic")
    func defaultEmojiDeterministic() {
        let conversation = Conversation.mock(id: "test-id")
        let emoji1 = conversation.defaultEmoji
        let emoji2 = conversation.defaultEmoji
        #expect(emoji1 == emoji2)
    }

    @Test("defaultEmoji different for different conversations")
    func defaultEmojiDifferentConversations() {
        let conv1 = Conversation.mock(id: "id-1")
        let conv2 = Conversation.mock(id: "id-2")
        let conv3 = Conversation.mock(id: "id-3")
        let emojis = Set([conv1.defaultEmoji, conv2.defaultEmoji, conv3.defaultEmoji])
        #expect(emojis.count > 1)
    }

    // MARK: - Conversation avatarType Tests

    @Test("avatarType returns customImage when imageURL exists")
    func avatarTypeCustomImage() {
        let conversation = Conversation(
            id: "test",
            clientConversationId: "client-test",
            inboxId: "inbox",
            clientId: "client",
            creator: .mock(isCurrentUser: true),
            createdAt: Date(),
            consent: .allowed,
            kind: .group,
            name: nil,
            description: nil,
            members: [.mock(isCurrentUser: true)],
            otherMember: nil,
            messages: [],
            isPinned: false,
            isUnread: false,
            isMuted: false,
            pinnedOrder: nil,
            lastMessage: nil,
            imageURL: URL(string: "https://example.com/image.jpg"),
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            includeInfoInPublicPreview: false,
            isDraft: false,
            invite: nil,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false
        )
        #expect(conversation.avatarType == .customImage)
    }

    @Test("avatarType returns emoji for fully anonymous group")
    func avatarTypeEmojiForAnonymous() {
        let members = [
            ConversationMember.mock(isCurrentUser: true, name: "You"),
            ConversationMember(
                profile: Profile.empty(inboxId: "anon1"),
                role: .member,
                isCurrentUser: false
            ),
            ConversationMember(
                profile: Profile.empty(inboxId: "anon2"),
                role: .member,
                isCurrentUser: false
            )
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        if case .emoji = conversation.avatarType {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected emoji avatar type")
        }
    }

    @Test("avatarType returns emoji for empty group")
    func avatarTypeEmojiForEmptyGroup() {
        let members = [
            ConversationMember(
                profile: Profile.empty(inboxId: "current"),
                role: .member,
                isCurrentUser: true
            )
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        if case .emoji = conversation.avatarType {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected emoji avatar type")
        }
    }

    @Test("avatarType returns emoji for empty group even when creator has avatar")
    func avatarTypeEmojiForEmptyGroupWithCreatorAvatar() {
        let members = [
            ConversationMember(
                profile: Profile.mock(inboxId: "current", name: "Me"),
                role: .member,
                isCurrentUser: true
            )
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        if case .emoji = conversation.avatarType {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected emoji avatar type, not creator's profile photo")
        }
    }

    @Test("avatarType returns emoji when other members have no avatars")
    func avatarTypeEmojiWhenOtherMembersHaveNoAvatars() {
        let members = [
            ConversationMember.mock(isCurrentUser: true, name: "You"),
            ConversationMember(
                profile: Profile(inboxId: "other1", name: "Alice", avatar: nil),
                role: .member,
                isCurrentUser: false
            ),
            ConversationMember(
                profile: Profile(inboxId: "other2", name: "Bob", avatar: nil),
                role: .member,
                isCurrentUser: false
            )
        ]
        let conversation = Conversation.mock(name: nil, members: members)
        if case .emoji = conversation.avatarType {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected emoji avatar type when no other members have avatars")
        }
    }

    // MARK: - Member Name Limiting Tests

    @Test("Four named profiles shows three and 1 other")
    func fourNamedProfilesShowsThreeAndOneOther() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob"),
            Profile.mock(name: "Charlie"),
            Profile.mock(name: "David")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob, Charlie and 1 other")
    }

    @Test("Five named profiles shows three and 2 others")
    func fiveNamedProfilesShowsThreeAndTwoOthers() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob"),
            Profile.mock(name: "Charlie"),
            Profile.mock(name: "David"),
            Profile.mock(name: "Eve")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob, Charlie and 2 others")
    }

    @Test("Ten named profiles shows three and 7 others")
    func tenNamedProfilesShowsThreeAndSevenOthers() {
        let profiles = (1...10).map { Profile.mock(name: "User\($0)") }
        #expect(profiles.formattedNamesString == "User1, User10, User2 and 7 others")
    }

    @Test("Two named with three anonymous shows names and others")
    func twoNamedThreeAnonymousShowsNamesAndOthers() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob"),
            Profile.empty(inboxId: "anon1"),
            Profile.empty(inboxId: "anon2"),
            Profile.empty(inboxId: "anon3")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob and 3 others")
    }

    @Test("One named with four anonymous shows name and others")
    func oneNamedFourAnonymousShowsNameAndOthers() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.empty(inboxId: "anon1"),
            Profile.empty(inboxId: "anon2"),
            Profile.empty(inboxId: "anon3"),
            Profile.empty(inboxId: "anon4")
        ]
        #expect(profiles.formattedNamesString == "Alice and 4 others")
    }

    @Test("Five anonymous profiles shows Somebodies")
    func fiveAnonymousProfilesShowsSomebodies() {
        let profiles = (1...5).map { Profile.empty(inboxId: "anon\($0)") }
        #expect(profiles.formattedNamesString == "Somebodies")
    }

    @Test("Three named with one anonymous within limit")
    func threeNamedOneAnonymousWithinLimit() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob"),
            Profile.empty(inboxId: "anon")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob, Somebody")
    }

    @Test("Three named with two anonymous exceeds limit")
    func threeNamedTwoAnonymousExceedsLimit() {
        let profiles = [
            Profile.mock(name: "Alice"),
            Profile.mock(name: "Bob"),
            Profile.mock(name: "Charlie"),
            Profile.empty(inboxId: "anon1"),
            Profile.empty(inboxId: "anon2")
        ]
        #expect(profiles.formattedNamesString == "Alice, Bob, Charlie and 2 others")
    }
}
