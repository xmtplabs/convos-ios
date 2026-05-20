@testable import ConvosCore
import Foundation
import Testing

/// Regression guard for `Profile.isAvatarEncrypted` and
/// `Contact.isAvatarEncrypted`. The predicate gates the encrypted-fetch
/// branch in `ImageCache.loadImage`; if it returns `true` while
/// `encryptionKey` (which reads `avatarKey` raw) is missing, the cache's
/// `fetchEncryptedImageInline` silently returns `nil` and the avatar
/// vanishes. The two predicates must stay aligned; this suite covers
/// both.
@Suite("isAvatarEncrypted requires all three of salt, nonce, key")
struct AvatarEncryptionPredicateTests {
    private static let salt32: Data = Data(repeating: 0xAA, count: 32)
    private static let nonce12: Data = Data(repeating: 0xBB, count: 12)
    private static let key32: Data = Data(repeating: 0xCC, count: 32)

    // MARK: - Profile

    @Test("Profile.isAvatarEncrypted is true only when all three fields have the correct lengths")
    func testProfilePredicateRequiresAllThreeFields() {
        #expect(Self.profile(salt: Self.salt32, nonce: Self.nonce12, key: Self.key32).isAvatarEncrypted)
    }

    @Test("Profile.isAvatarEncrypted is false when avatarKey is nil")
    func testProfilePredicateFalseWhenKeyMissing() {
        #expect(!Self.profile(salt: Self.salt32, nonce: Self.nonce12, key: nil).isAvatarEncrypted)
    }

    @Test("Profile.isAvatarEncrypted is false when avatarKey has the wrong length")
    func testProfilePredicateFalseWhenKeyWrongLength() {
        let shortKey = Data(repeating: 0xCC, count: 16)
        #expect(!Self.profile(salt: Self.salt32, nonce: Self.nonce12, key: shortKey).isAvatarEncrypted)
    }

    @Test("Profile.isAvatarEncrypted is false when avatarSalt or avatarNonce are missing or wrong length")
    func testProfilePredicateFalseWhenSaltOrNonceWrong() {
        let shortSalt = Data(repeating: 0xAA, count: 16)
        let shortNonce = Data(repeating: 0xBB, count: 8)
        #expect(!Self.profile(salt: nil, nonce: Self.nonce12, key: Self.key32).isAvatarEncrypted)
        #expect(!Self.profile(salt: Self.salt32, nonce: nil, key: Self.key32).isAvatarEncrypted)
        #expect(!Self.profile(salt: shortSalt, nonce: Self.nonce12, key: Self.key32).isAvatarEncrypted)
        #expect(!Self.profile(salt: Self.salt32, nonce: shortNonce, key: Self.key32).isAvatarEncrypted)
    }

    // MARK: - Contact

    @Test("Contact.isAvatarEncrypted is true only when all three fields have the correct lengths")
    func testContactPredicateRequiresAllThreeFields() {
        #expect(Self.contact(salt: Self.salt32, nonce: Self.nonce12, key: Self.key32).isAvatarEncrypted)
    }

    @Test("Contact.isAvatarEncrypted is false when avatarKey is nil")
    func testContactPredicateFalseWhenKeyMissing() {
        let value = Self.contact(salt: Self.salt32, nonce: Self.nonce12, key: nil)
        #expect(!value.isAvatarEncrypted)
        // ImageCacheable contract: encryptionKey must be non-nil whenever
        // isEncryptedImage is true, otherwise the cache enters the
        // encrypted branch and silently fails.
        #expect(value.isEncryptedImage == false)
        #expect(value.encryptionKey == nil)
    }

    @Test("Contact.isAvatarEncrypted is false when avatarKey has the wrong length")
    func testContactPredicateFalseWhenKeyWrongLength() {
        let shortKey = Data(repeating: 0xCC, count: 16)
        #expect(!Self.contact(salt: Self.salt32, nonce: Self.nonce12, key: shortKey).isAvatarEncrypted)
    }

    // MARK: - Helpers

    private static func profile(salt: Data?, nonce: Data?, key: Data?) -> Profile {
        Profile(
            inboxId: "inbox-1",
            conversationId: "convo-1",
            name: nil,
            avatar: "https://example.com/a.png",
            avatarSalt: salt,
            avatarNonce: nonce,
            avatarKey: key
        )
    }

    private static func contact(salt: Data?, nonce: Data?, key: Data?) -> Contact {
        Contact(
            inboxId: "inbox-1",
            displayName: nil,
            avatarURL: "https://example.com/a.png",
            avatarSalt: salt,
            avatarNonce: nonce,
            avatarKey: key,
            addedAt: Date(),
            addedViaConversationId: nil
        )
    }
}
