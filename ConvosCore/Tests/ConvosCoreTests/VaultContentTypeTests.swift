@testable import ConvosCore
import Foundation
import Testing
import XMTPiOS

@Suite("DeviceKeyBundle Codec Tests")
struct DeviceKeyBundleCodecTests {
    let codec: DeviceKeyBundleCodec = DeviceKeyBundleCodec()

    @Test("Content type matches expected value")
    func contentType() {
        let expectedType = ContentTypeID(
            authorityID: "convos.org",
            typeID: "device_key_bundle",
            versionMajor: 1,
            versionMinor: 0
        )
        #expect(codec.contentType == expectedType)
        #expect(codec.contentType == ContentTypeDeviceKeyBundle)
    }

    @Test("Should not push")
    func shouldNotPush() throws {
        let content = DeviceKeyBundleContent(
            keys: [],
            senderInstallationId: "test-install"
        )
        #expect(try codec.shouldPush(content: content) == false)
    }

    @Test("Encode and decode empty bundle")
    func encodeDecodeEmpty() throws {
        let original = DeviceKeyBundleContent(
            keys: [],
            senderInstallationId: "install-123"
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceKeyBundleContent = try codec.decode(content: encoded)

        #expect(decoded.keys.isEmpty)
        #expect(decoded.senderInstallationId == "install-123")
    }

    @Test("Encode and decode with keys")
    func encodeDecodeWithKeys() throws {
        let key1 = DeviceKeyEntry(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([1, 2, 3, 4]),
            databaseKey: Data([5, 6, 7, 8])
        )
        let key2 = DeviceKeyEntry(
            conversationId: "conv-2",
            inboxId: "inbox-2",
            clientId: "client-2",
            privateKeyData: Data([9, 10, 11, 12]),
            databaseKey: Data([13, 14, 15, 16])
        )
        let original = DeviceKeyBundleContent(
            keys: [key1, key2],
            senderInstallationId: "install-456"
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceKeyBundleContent = try codec.decode(content: encoded)

        #expect(decoded.keys.count == 2)
        #expect(decoded.keys[0].conversationId == "conv-1")
        #expect(decoded.keys[0].privateKeyData == Data([1, 2, 3, 4]))
        #expect(decoded.keys[0].databaseKey == Data([5, 6, 7, 8]))
        #expect(decoded.keys[1].conversationId == "conv-2")
        #expect(decoded.keys[1].inboxId == "inbox-2")
        #expect(decoded.senderInstallationId == "install-456")
    }

    @Test("Timestamp preserved")
    func timestampPreserved() throws {
        let original = DeviceKeyBundleContent(
            keys: [],
            senderInstallationId: "install",
            timestamp: Date()
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceKeyBundleContent = try codec.decode(content: encoded)

        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 1.0)
    }

    @Test("Fallback describes key count")
    func fallbackContent() throws {
        let keys = [
            DeviceKeyEntry(conversationId: "c1", inboxId: "i1", clientId: "cl1", privateKeyData: Data(), databaseKey: Data()),
            DeviceKeyEntry(conversationId: "c2", inboxId: "i2", clientId: "cl2", privateKeyData: Data(), databaseKey: Data()),
            DeviceKeyEntry(conversationId: "c3", inboxId: "i3", clientId: "cl3", privateKeyData: Data(), databaseKey: Data()),
        ]
        let content = DeviceKeyBundleContent(keys: keys, senderInstallationId: "install")
        let fallback = try codec.fallback(content: content)
        #expect(fallback == "Shared 3 conversation keys")
    }

    @Test("Empty content throws")
    func emptyContentThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceKeyBundle
        encodedContent.content = Data()

        #expect(throws: DeviceKeyBundleCodecError.emptyContent) {
            _ = try codec.decode(content: encodedContent) as DeviceKeyBundleContent
        }
    }

    @Test("Malformed JSON throws")
    func malformedJSON() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceKeyBundle
        encodedContent.content = Data("not json".utf8)

        #expect(throws: Error.self) {
            _ = try codec.decode(content: encodedContent) as DeviceKeyBundleContent
        }
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = DeviceKeyEntry(conversationId: "c1", inboxId: "i1", clientId: "cl1", privateKeyData: Data([1]), databaseKey: Data([2]))
        let b = DeviceKeyEntry(conversationId: "c1", inboxId: "i1", clientId: "cl1", privateKeyData: Data([1]), databaseKey: Data([2]))
        let c = DeviceKeyEntry(conversationId: "c2", inboxId: "i1", clientId: "cl1", privateKeyData: Data([1]), databaseKey: Data([2]))

        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("DeviceKeyShare Codec Tests")
struct DeviceKeyShareCodecTests {
    let codec: DeviceKeyShareCodec = DeviceKeyShareCodec()

    @Test("Content type matches expected value")
    func contentType() {
        let expectedType = ContentTypeID(
            authorityID: "convos.org",
            typeID: "device_key_share",
            versionMajor: 1,
            versionMinor: 0
        )
        #expect(codec.contentType == expectedType)
        #expect(codec.contentType == ContentTypeDeviceKeyShare)
    }

    @Test("Should not push")
    func shouldNotPush() throws {
        let content = DeviceKeyShareContent(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data(),
            databaseKey: Data(),
            senderInstallationId: "install-1"
        )
        #expect(try codec.shouldPush(content: content) == false)
    }

    @Test("Encode and decode")
    func encodeDecode() throws {
        let original = DeviceKeyShareContent(
            conversationId: "conv-abc",
            inboxId: "inbox-def",
            clientId: "client-ghi",
            privateKeyData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            databaseKey: Data([0xCA, 0xFE, 0xBA, 0xBE]),
            senderInstallationId: "install-xyz"
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceKeyShareContent = try codec.decode(content: encoded)

        #expect(decoded.conversationId == "conv-abc")
        #expect(decoded.inboxId == "inbox-def")
        #expect(decoded.clientId == "client-ghi")
        #expect(decoded.privateKeyData == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(decoded.databaseKey == Data([0xCA, 0xFE, 0xBA, 0xBE]))
        #expect(decoded.senderInstallationId == "install-xyz")
    }

    @Test("Timestamp preserved")
    func timestampPreserved() throws {
        let original = DeviceKeyShareContent(
            conversationId: "c",
            inboxId: "i",
            clientId: "cl",
            privateKeyData: Data(),
            databaseKey: Data(),
            senderInstallationId: "install"
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceKeyShareContent = try codec.decode(content: encoded)

        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 1.0)
    }

    @Test("Fallback includes conversation ID")
    func fallbackContent() throws {
        let content = DeviceKeyShareContent(
            conversationId: "my-conv-id",
            inboxId: "i",
            clientId: "cl",
            privateKeyData: Data(),
            databaseKey: Data(),
            senderInstallationId: "install"
        )
        let fallback = try codec.fallback(content: content)
        #expect(fallback == "Shared key for conversation my-conv-id")
    }

    @Test("Empty content throws")
    func emptyContentThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceKeyShare
        encodedContent.content = Data()

        #expect(throws: DeviceKeyShareCodecError.emptyContent) {
            _ = try codec.decode(content: encodedContent) as DeviceKeyShareContent
        }
    }
}

@Suite("DeviceRemoved Codec Tests")
struct DeviceRemovedCodecTests {
    let codec: DeviceRemovedCodec = DeviceRemovedCodec()

    @Test("Content type matches expected value")
    func contentType() {
        let expectedType = ContentTypeID(
            authorityID: "convos.org",
            typeID: "device_removed",
            versionMajor: 1,
            versionMinor: 0
        )
        #expect(codec.contentType == expectedType)
        #expect(codec.contentType == ContentTypeDeviceRemoved)
    }

    @Test("Should not push")
    func shouldNotPush() throws {
        let content = DeviceRemovedContent(
            removedInboxId: "inbox-123",
            reason: .userRemoved
        )
        #expect(try codec.shouldPush(content: content) == false)
    }

    @Test("Encode and decode userRemoved")
    func encodeDecodeUserRemoved() throws {
        let original = DeviceRemovedContent(
            removedInboxId: "inbox-abc",
            reason: .userRemoved
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceRemovedContent = try codec.decode(content: encoded)

        #expect(decoded.removedInboxId == "inbox-abc")
        #expect(decoded.reason == .userRemoved)
    }

    @Test("Encode and decode lostDevice")
    func encodeDecodeLostDevice() throws {
        let original = DeviceRemovedContent(
            removedInboxId: "inbox-def",
            reason: .lostDevice
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceRemovedContent = try codec.decode(content: encoded)

        #expect(decoded.removedInboxId == "inbox-def")
        #expect(decoded.reason == .lostDevice)
    }

    @Test("Forward compatibility with unknown reason")
    func forwardCompatibilityUnknownReason() throws {
        let original = DeviceRemovedContent(
            removedInboxId: "inbox-xyz",
            reason: .unknown("future_reason")
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceRemovedContent = try codec.decode(content: encoded)

        #expect(decoded.reason == .unknown("future_reason"))
    }

    @Test("Timestamp preserved")
    func timestampPreserved() throws {
        let original = DeviceRemovedContent(
            removedInboxId: "inbox",
            reason: .userRemoved
        )

        let encoded = try codec.encode(content: original)
        let decoded: DeviceRemovedContent = try codec.decode(content: encoded)

        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 1.0)
    }

    @Test("Fallback content")
    func fallbackContent() throws {
        let content = DeviceRemovedContent(
            removedInboxId: "inbox",
            reason: .userRemoved
        )
        let fallback = try codec.fallback(content: content)
        #expect(fallback == "Device removed")
    }

    @Test("Empty content throws")
    func emptyContentThrows() {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeDeviceRemoved
        encodedContent.content = Data()

        #expect(throws: DeviceRemovedCodecError.emptyContent) {
            _ = try codec.decode(content: encodedContent) as DeviceRemovedContent
        }
    }

    @Test("Reason rawValue")
    func reasonRawValue() {
        #expect(DeviceRemovedReason.userRemoved.rawValue == "user_removed")
        #expect(DeviceRemovedReason.lostDevice.rawValue == "lost_device")
        #expect(DeviceRemovedReason.unknown("custom").rawValue == "custom")
    }

    @Test("Reason equatable")
    func reasonEquatable() {
        #expect(DeviceRemovedReason.userRemoved == .userRemoved)
        #expect(DeviceRemovedReason.lostDevice == .lostDevice)
        #expect(DeviceRemovedReason.unknown("a") == .unknown("a"))
        #expect(DeviceRemovedReason.unknown("a") != .unknown("b"))
        #expect(DeviceRemovedReason.userRemoved != .lostDevice)
    }
}
