@testable import ConvosCore
import Foundation
import Testing

/// Covers the identity-provisioning gate: while an account-deletion record
/// is active, an empty keychain must not auto-register a fresh identity.
@Suite("Account Deletion Provisioning Gate")
struct AccountDeletionProvisioningGateTests {
    private func makeStore() throws -> AccountDeletionStateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-deletion-gate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return AccountDeletionStateStore(directoryURL: url)
    }

    @Test("Empty keychain with an active deletion record yields the gated error service, not a registration")
    func gateHoldsProvisioning() async throws {
        let store = try makeStore()
        try await store.begin(AccountDeletionRecord(
            operationId: UUID(),
            inboxId: "inbox-1",
            clientId: "client-1",
            ethAddress: "0xabc",
            deviceId: "device-1"
        ))
        try await store.advance(to: .backendConfirmed)
        try await store.advance(to: .localWipePending)

        let databaseManager = MockDatabaseManager.makeTestDatabase()
        // Clip-bootstrap mode: no launch-time initialization task, so the
        // gate is exercised in isolation (no recovery, no device
        // registration).
        let manager = SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock,
            mode: .clipBootstrap,
            accountDeletionStore: store
        )

        let service = manager.messagingService()
        guard case .error(let error) = service.sessionStateManager.currentState else {
            Issue.record("Expected gated error state, got \(service.sessionStateManager.currentState)")
            return
        }
        #expect(error is AccountDeletionInProgressError)

        // Repeated access returns the cached gated service (no rebuild
        // thrash, still no registration).
        let second = manager.messagingService()
        guard case .error(let secondError) = second.sessionStateManager.currentState else {
            Issue.record("Expected gated error state on second access")
            return
        }
        #expect(secondError is AccountDeletionInProgressError)
    }
}
