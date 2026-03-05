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

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc")

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

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc")

        await #expect(throws: PairingError.self) {
            try await coordinator.startPairing(inviteURL: "https://convos.org/invite/def")
        }
    }

    @Test("Received join request transitions to waitingForConfirmation")
    func receivedJoinRequest() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc")
        try await coordinator.receivedJoinRequest(pin: "482916", joinerInboxId: "joiner-inbox-1")

        let state = await coordinator.currentState
        if case let .waitingForConfirmation(pin, joinerInboxId) = state {
            #expect(pin == "482916")
            #expect(joinerInboxId == "joiner-inbox-1")
        } else {
            Issue.record("Expected waitingForConfirmation, got \(state)")
        }
    }

    @Test("Confirm pin with wrong code throws invalidConfirmationCode")
    func confirmWrongPin() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc")
        try await coordinator.receivedJoinRequest(pin: "482916", joinerInboxId: "joiner-inbox-1")

        await #expect(throws: PairingError.self) {
            try await coordinator.confirmPin("000000")
        }
    }

    @Test("Cancel resets to idle")
    func cancel() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try GRDB.DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test")
        let coordinator = PairingCoordinator(vaultManager: manager)

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc")
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

        try await coordinator.startPairing(inviteURL: "https://convos.org/invite/abc")

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
