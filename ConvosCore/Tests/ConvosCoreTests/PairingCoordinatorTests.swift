@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("PairingCoordinator Tests")
struct PairingCoordinatorTests {
    @Test("Generate pin produces 6 digits")
    func generatePin() {
        let pin = PairingCoordinator.generatePin()
        #expect(pin.count == 6)
        let allDigits = pin.allSatisfy { $0.isNumber }
        #expect(allDigits)
    }

    @Test("Generate pin produces different values")
    func generatePinUniqueness() {
        let pins = (0 ..< 10).map { _ in PairingCoordinator.generatePin() }
        let unique = Set(pins)
        #expect(unique.count > 1)
    }

    @Test("Format pin adds space in middle")
    func formatPin() {
        #expect(PairingCoordinator.formatPin("123456") == "123 456")
        #expect(PairingCoordinator.formatPin("000000") == "000 000")
    }

    @Test("Format pin handles short input")
    func formatPinShort() {
        #expect(PairingCoordinator.formatPin("123") == "123")
    }

    @Test("Start pairing transitions to waitingForScan")
    func startPairing() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")

        let state = await coordinator.currentState
        if case let .waitingForScan(url, expiresAt) = state {
            #expect(url == "https://convos.org/invite/abc")
            #expect(expiresAt > Date())
        } else {
            Issue.record("Expected waitingForScan, got \(state)")
        }
    }

    @Test("Start pairing twice throws alreadyPairing")
    func startPairingTwice() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")

        await #expect(throws: PairingError.self) {
            try await coordinator.startPairing(inviteURL: "https://convos.org/invite/def", initiatorInboxId: "initiator-inbox")
        }
    }

    @Test("Received join request transitions to showingPin")
    func receivedJoinRequest() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")
        try await coordinator.receivedJoinRequest(joinerInboxId: "joiner-inbox-1", deviceName: "iPad")

        let state = await coordinator.currentState
        if case let .showingPin(pin, deviceName, joinerInboxId) = state {
            #expect(pin.count == 6)
            #expect(deviceName == "iPad")
            #expect(joinerInboxId == "joiner-inbox-1")
        } else {
            Issue.record("Expected showingPin, got \(state)")
        }
    }

    @Test("Pin echo with wrong code throws invalidConfirmationCode")
    func pinEchoWrongCode() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")
        try await coordinator.receivedJoinRequest(joinerInboxId: "joiner-inbox-1", deviceName: "iPad")

        await #expect(throws: PairingError.self) {
            try await coordinator.receivedPinEcho("000000", from: "joiner-inbox-1")
        }
    }

    @Test("Pin echo with correct code transitions to emojiConfirmation")
    func pinEchoCorrectCode() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")
        try await coordinator.receivedJoinRequest(joinerInboxId: "joiner-inbox-1", deviceName: "iPad")

        let state = await coordinator.currentState
        guard case let .showingPin(pin, _, _) = state else {
            Issue.record("Expected showingPin")
            return
        }

        try await coordinator.receivedPinEcho(pin, from: "joiner-inbox-1")

        let newState = await coordinator.currentState
        if case let .waitingForEmojiConfirmation(emojis, joinerInboxId) = newState {
            #expect(emojis.count == 3)
            #expect(joinerInboxId == "joiner-inbox-1")
        } else {
            Issue.record("Expected waitingForEmojiConfirmation, got \(newState)")
        }
    }

    @Test("Emoji fingerprint is deterministic and order-independent")
    func emojiFingerprint() {
        let emojis1 = PairingCoordinator.emojiFingerprint(inboxA: "inbox-a", inboxB: "inbox-b", pin: "123456")
        let emojis2 = PairingCoordinator.emojiFingerprint(inboxA: "inbox-a", inboxB: "inbox-b", pin: "123456")
        let emojis3 = PairingCoordinator.emojiFingerprint(inboxA: "inbox-b", inboxB: "inbox-a", pin: "123456")

        #expect(emojis1 == emojis2)
        #expect(emojis1 == emojis3)
        #expect(emojis1.count == 3)
    }

    @Test("Emoji fingerprint differs with different inputs")
    func emojiFingerprintDiffers() {
        let emojis1 = PairingCoordinator.emojiFingerprint(inboxA: "inbox-a", inboxB: "inbox-b", pin: "123456")
        let emojis2 = PairingCoordinator.emojiFingerprint(inboxA: "inbox-a", inboxB: "inbox-c", pin: "123456")
        let emojis3 = PairingCoordinator.emojiFingerprint(inboxA: "inbox-a", inboxB: "inbox-b", pin: "654321")

        #expect(emojis1 != emojis2)
        #expect(emojis1 != emojis3)
    }

    @Test("Cancel resets to idle")
    func cancel() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")
        await coordinator.cancel()

        let state = await coordinator.currentState
        #expect(state == .idle)
    }

    @Test("Expiration fires after timeout")
    func expiration() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager, timeoutInterval: 1)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc", initiatorInboxId: "initiator-inbox")

        for _ in 0 ..< 30 {
            try await Task.sleep(for: .milliseconds(200))
            let state = await coordinator.currentState
            if state == .expired { return }
        }

        let finalState = await coordinator.currentState
        #expect(finalState == .expired)
    }

    @Test("PairingState equatable")
    func pairingStateEquatable() {
        #expect(PairingState.idle == PairingState.idle)
        #expect(PairingState.expired == PairingState.expired)
        #expect(PairingState.completed(deviceCount: 2) == PairingState.completed(deviceCount: 2))
        #expect(PairingState.completed(deviceCount: 2) != PairingState.completed(deviceCount: 3))
        #expect(PairingState.idle != PairingState.expired)
    }

    @Test("PairingError equatable")
    func pairingErrorEquatable() {
        #expect(PairingError.notConnected == PairingError.notConnected)
        #expect(PairingError.invalidConfirmationCode == PairingError.invalidConfirmationCode)
        #expect(PairingError.notConnected != PairingError.pairingTimeout)
    }
}
