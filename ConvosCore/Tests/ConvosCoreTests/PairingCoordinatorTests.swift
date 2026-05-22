import Foundation
import Testing
@testable import ConvosCore

@Suite("PairingCoordinator")
struct PairingCoordinatorTests {
    @Test func pinIsSixDigits() {
        for _ in 0 ..< 100 {
            let pin = PairingCoordinator.generatePin()
            #expect(pin.count == 6)
            let allDigits = pin.allSatisfy { $0.isNumber }
            #expect(allDigits)
        }
    }

    @Test func formatPinSplitsIntoTwoGroups() {
        #expect(PairingCoordinator.formatPin("123456") == "123 456")
    }

    @Test func formatPinReturnsRawWhenWrongLength() {
        #expect(PairingCoordinator.formatPin("12345") == "12345")
        #expect(PairingCoordinator.formatPin("1234567") == "1234567")
    }

    @Test func emojiFingerprintIsOrderIndependent() {
        let a = PairingCoordinator.emojiFingerprint(inboxA: "alpha", inboxB: "bravo", pin: "123456")
        let b = PairingCoordinator.emojiFingerprint(inboxA: "bravo", inboxB: "alpha", pin: "123456")
        #expect(a == b)
        #expect(a.count == 3)
    }

    @Test func emojiFingerprintDiffersByPin() {
        let a = PairingCoordinator.emojiFingerprint(inboxA: "alpha", inboxB: "bravo", pin: "111111")
        let b = PairingCoordinator.emojiFingerprint(inboxA: "alpha", inboxB: "bravo", pin: "222222")
        #expect(a != b)
    }

    @Test func startPairingMovesToWaitingForScan() async throws {
        let service = MockPairingService()
        let coordinator = PairingCoordinator(pairingService: service)
        try await coordinator.startPairing(inviteURL: "https://example/pair/abc", initiatorInboxId: "inbox-a")
        let state = await coordinator.currentState
        guard case let .waitingForScan(url, _) = state else {
            Issue.record("expected waitingForScan, got \(state)")
            return
        }
        #expect(url == "https://example/pair/abc")
    }

    @Test func wrongPinFails() async throws {
        let service = MockPairingService()
        let coordinator = PairingCoordinator(pairingService: service)
        try await coordinator.startPairing(inviteURL: "url", initiatorInboxId: "inbox-a")
        try await coordinator.receivedJoinRequest(joinerInboxId: "inbox-b", deviceName: "iPad")

        await #expect(throws: PairingError.self) {
            try await coordinator.receivedPinEcho("000000", from: "inbox-b")
        }
    }

    @Test func correctPinReachesEmojiConfirmation() async throws {
        let service = MockPairingService()
        let coordinator = PairingCoordinator(pairingService: service)
        try await coordinator.startPairing(inviteURL: "url", initiatorInboxId: "inbox-a")
        try await coordinator.receivedJoinRequest(joinerInboxId: "inbox-b", deviceName: "iPad")

        let postPin = await coordinator.currentState
        guard case let .showingPin(pin, _, _) = postPin else {
            Issue.record("expected showingPin, got \(postPin)")
            return
        }

        try await coordinator.receivedPinEcho(pin, from: "inbox-b")
        let state = await coordinator.currentState
        guard case let .waitingForEmojiConfirmation(emojis, _) = state else {
            Issue.record("expected waitingForEmojiConfirmation, got \(state)")
            return
        }
        #expect(emojis.count == 3)
    }
}

@Suite("IdentityShareCodec")
struct IdentityShareCodecTests {
    @Test func roundtrips() throws {
        let codec = IdentityShareCodec()
        let content = IdentityShareContent(
            privateKeyData: Data(repeating: 0xAB, count: 32),
            inboxId: "inbox-123",
            initiatorDeviceName: "Jarod's iPhone"
        )
        let encoded = try codec.encode(content: content)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == content)
    }

    @Test func rejectsWrongKeyLength() throws {
        let codec = IdentityShareCodec()
        let content = IdentityShareContent(
            privateKeyData: Data(repeating: 0x01, count: 16),
            inboxId: "inbox-123",
            initiatorDeviceName: nil
        )
        #expect(throws: IdentityShareCodecError.self) {
            try codec.encode(content: content)
        }
    }
}

@Suite("DeviceRemovedCodec")
struct DeviceRemovedCodecTests {
    @Test func roundtrips() throws {
        let codec = DeviceRemovedCodec()
        let content = DeviceRemovedContent(
            revokedInstallationId: "abcdef1234567890",
            removedAt: 1_700_000_000
        )
        let encoded = try codec.encode(content: content)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == content)
    }

    @Test func shouldNotPush() throws {
        let codec = DeviceRemovedCodec()
        let push = try codec.shouldPush(content: DeviceRemovedContent(revokedInstallationId: "x"))
        #expect(push == false)
    }
}

@Suite("PairingJoinRequestCodec")
struct PairingJoinRequestCodecTests {
    @Test func roundtrips() throws {
        let codec = PairingJoinRequestCodec()
        let content = PairingJoinRequestContent(
            slug: "test-slug",
            joinerInboxId: "joiner-inbox",
            deviceName: "iPhone 13"
        )
        let encoded = try codec.encode(content: content)
        let decoded = try codec.decode(content: encoded)
        #expect(decoded == content)
    }
}

@Suite("PairingMessageCodec")
struct PairingMessageCodecTests {
    @Test func pinRoundtrip() throws {
        let codec = PairingMessageCodec()
        let encoded = try codec.encode(content: .pin("123456"))
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.type == .pin)
        #expect(decoded.payload == "123456")
    }

    @Test func pinEchoRoundtrip() throws {
        let codec = PairingMessageCodec()
        let encoded = try codec.encode(content: .pinEcho("654321"))
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.type == .pinEcho)
        #expect(decoded.payload == "654321")
    }

    @Test func errorRoundtrip() throws {
        let codec = PairingMessageCodec()
        let encoded = try codec.encode(content: .error("nope"))
        let decoded = try codec.decode(content: encoded)
        #expect(decoded.type == .error)
        #expect(decoded.payload == "nope")
    }
}

@Suite("PairedDeviceNameStore")
struct PairedDeviceNameStoreTests {
    // Per-test unique app group so the suite stays self-contained even on
    // a shared simulator UserDefaults backing store.
    private static func testAppGroup() -> String {
        "group.convos.test.\(UUID().uuidString)"
    }

    @Test func setAndReadByInstallationId() {
        let appGroup = Self.testAppGroup()
        PairedDeviceNameStore.setName("Jarod's iPad", forInstallationId: "inst-a", appGroup: appGroup)
        #expect(PairedDeviceNameStore.name(forInstallationId: "inst-a", appGroup: appGroup) == "Jarod's iPad")
        #expect(PairedDeviceNameStore.name(forInstallationId: "inst-other", appGroup: appGroup) == nil)
    }

    @Test func pendingConsumedOnce() {
        let appGroup = Self.testAppGroup()
        PairedDeviceNameStore.setPending("iPhone 17", appGroup: appGroup)
        #expect(PairedDeviceNameStore.consumePending(appGroup: appGroup) == "iPhone 17")
        #expect(PairedDeviceNameStore.consumePending(appGroup: appGroup) == nil)
    }

    @Test func pendingDoesNotInterfereWithKeyed() {
        let appGroup = Self.testAppGroup()
        PairedDeviceNameStore.setName("Named device", forInstallationId: "inst-a", appGroup: appGroup)
        PairedDeviceNameStore.setPending("Pending device", appGroup: appGroup)
        #expect(PairedDeviceNameStore.name(forInstallationId: "inst-a", appGroup: appGroup) == "Named device")
        #expect(PairedDeviceNameStore.consumePending(appGroup: appGroup) == "Pending device")
        #expect(PairedDeviceNameStore.name(forInstallationId: "inst-a", appGroup: appGroup) == "Named device")
    }
}

@Suite("PairingInvite")
struct PairingInviteTests {
    @Test func slugRoundtripsBeforeExpiry() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let invite = PairingInvite(
            initiatorInboxId: "inbox-a",
            initiatorAddress: "0xabc",
            nonce: Data(repeating: 0xFF, count: 16),
            issuedAt: now,
            expiresAt: now + 60,
            signature: Data(repeating: 0x01, count: 65)
        )
        let slug = try invite.toURLSafeSlug()
        let decoded = try PairingInvite.fromURLSafeSlug(slug)
        #expect(decoded == invite)
    }

    @Test func expiredSlugRejected() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let invite = PairingInvite(
            initiatorInboxId: "inbox-a",
            initiatorAddress: "0xabc",
            nonce: Data(repeating: 0xFF, count: 16),
            issuedAt: now - 120,
            expiresAt: now - 60,
            signature: Data(repeating: 0x01, count: 65)
        )
        let slug = try invite.toURLSafeSlug()
        #expect(throws: PairingInviteError.self) {
            _ = try PairingInvite.fromURLSafeSlug(slug)
        }
    }
}
