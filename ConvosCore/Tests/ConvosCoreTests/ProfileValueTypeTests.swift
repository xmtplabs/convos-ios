@testable import ConvosCore
import Foundation
import Testing

@Suite("Avatar value type")
struct AvatarTests {
    private let updatedAt: Date = .init(timeIntervalSince1970: 1)

    @Test("nil or empty url yields no avatar")
    func emptyURLIsNil() {
        #expect(Avatar.from(url: nil, salt: nil, nonce: nil, key: nil, updatedAt: updatedAt) == nil)
        #expect(Avatar.from(url: "", salt: nil, nonce: nil, key: nil, updatedAt: updatedAt) == nil)
    }

    @Test("url with no crypto material is plain")
    func plainAvatar() {
        let avatar = Avatar.from(url: "https://e.com/a.jpg", salt: nil, nonce: nil, key: nil, updatedAt: updatedAt)
        #expect(avatar == .plain(url: "https://e.com/a.jpg", updatedAt: updatedAt))
        #expect(avatar?.isEncrypted == false)
        #expect(avatar?.url == "https://e.com/a.jpg")
    }

    @Test("correctly sized crypto material yields encrypted")
    func encryptedAvatar() {
        let salt = Data(repeating: 1, count: 32)
        let nonce = Data(repeating: 2, count: 12)
        let key = Data(repeating: 3, count: 32)
        let avatar = Avatar.from(url: "https://e.com/a.enc", salt: salt, nonce: nonce, key: key, updatedAt: updatedAt)
        #expect(avatar == .encrypted(url: "https://e.com/a.enc", salt: salt, nonce: nonce, key: key, updatedAt: updatedAt))
        #expect(avatar?.isEncrypted == true)
    }

    @Test("wrong-sized crypto material falls back to plain")
    func wrongSizedCryptoFallsBackToPlain() {
        let badSalt = Data(repeating: 1, count: 16)
        let nonce = Data(repeating: 2, count: 12)
        let key = Data(repeating: 3, count: 32)
        let avatar = Avatar.from(url: "https://e.com/a.enc", salt: badSalt, nonce: nonce, key: key, updatedAt: updatedAt)
        #expect(avatar?.isEncrypted == false)
        #expect(avatar?.url == "https://e.com/a.enc")
    }

    @Test("partial crypto material falls back to plain")
    func partialCryptoFallsBackToPlain() {
        let salt = Data(repeating: 1, count: 32)
        let avatar = Avatar.from(url: "https://e.com/a.enc", salt: salt, nonce: nil, key: nil, updatedAt: updatedAt)
        #expect(avatar?.isEncrypted == false)
    }
}

@Suite("ProfileSource precedence")
struct ProfileSourceTests {
    @Test("orders from contact lowest to profileUpdate highest")
    func ordering() {
        #expect(ProfileSource.contact < .appData)
        #expect(ProfileSource.appData < .profileSnapshot)
        #expect(ProfileSource.profileSnapshot < .profileUpdate)
        #expect(ProfileSource.profileUpdate > .contact)
    }

    @Test("max of a set is the highest precedence")
    func maxPrecedence() {
        let sources: [ProfileSource] = [.contact, .profileSnapshot, .appData]
        #expect(sources.max() == .profileSnapshot)
    }

    @Test("round-trips through its raw value")
    func rawValueRoundTrip() {
        for source in ProfileSource.allCases {
            #expect(ProfileSource(rawValue: source.rawValue) == source)
        }
    }
}
