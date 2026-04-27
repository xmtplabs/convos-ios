@testable import ConvosCore
import Foundation
import Testing

/// Unit coverage for the App Clip → main-app identity handoff contract.
///
/// Because both targets bind `KeychainIdentityStore` to the same
/// app-group-scoped access group (see `AppEnvironment.keychainAccessGroup`),
/// an identity the clip writes is visible to the full app on first launch.
/// These tests exercise that contract against the in-memory mock so the
/// logical shape is pinned; real keychain coverage lives in
/// `KeychainIdentityStoreRealKeychainTests`.
@Suite("App Clip Identity Handoff")
struct AppClipIdentityHandoffTests {
    @Test("Clip-written identity is visible to the main app on next launch")
    func clipWriteVisibleToMainApp() async throws {
        let sharedKeychain = MockKeychainIdentityStore()

        // App Clip: generate and persist the singleton identity.
        let keys = try await sharedKeychain.generateKeys()
        let clipSaved = try await sharedKeychain.save(
            inboxId: "app-clip-inbox",
            clientId: "app-clip-client",
            keys: keys
        )

        // Main app launches later and reads the same access group.
        let mainAppLoaded = try await sharedKeychain.load()
        #expect(mainAppLoaded?.inboxId == clipSaved.inboxId)
        #expect(mainAppLoaded?.clientId == clipSaved.clientId)
        #expect(mainAppLoaded?.keys.databaseKey == clipSaved.keys.databaseKey)
    }

    @Test("Empty keychain triggers a fresh registration path")
    func emptyKeychainSignalsRegistration() async throws {
        let sharedKeychain = MockKeychainIdentityStore()
        // No prior App Clip run.
        let loaded = try await sharedKeychain.load()
        #expect(loaded == nil)
    }

    @Test("Main app never mints a new identity when one is already stored")
    func mainAppReusesExistingIdentity() async throws {
        let sharedKeychain = MockKeychainIdentityStore()
        let clipKeys = try await sharedKeychain.generateKeys()
        _ = try await sharedKeychain.save(
            inboxId: "persisted-inbox",
            clientId: "persisted-client",
            keys: clipKeys
        )

        // Main app launch: load returns the clip's identity.
        let firstLoad = try await sharedKeychain.load()
        #expect(firstLoad?.inboxId == "persisted-inbox")

        // A second main-app launch should observe the same identity —
        // this mirrors `SessionManager.makeService` taking the authorize
        // branch every time instead of overwriting via register.
        let secondLoad = try await sharedKeychain.load()
        #expect(secondLoad?.inboxId == firstLoad?.inboxId)
        #expect(secondLoad?.clientId == firstLoad?.clientId)
        #expect(secondLoad?.keys.databaseKey == firstLoad?.keys.databaseKey)
    }
}
