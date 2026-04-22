@testable import ConvosCore
import Foundation
import Testing

/// Contract for `SessionManager.pauseForRestore()` / `resumeAfterRestore()`
/// — the seam `RestoreManager` will drive in CP3c.
///
/// Covers the invariants laid out in the plan's
/// §"Throwaway XMTP client for archive import":
/// 1. The app-group flag is strict on set (NSE would otherwise open
///    the DB mid-swap).
/// 2. While paused, `messagingService()` returns a frozen placeholder
///    whose state is `.error(RestoreInProgressError)`. Repeated calls
///    return the same cached instance — no rebuild thrash.
/// 3. `resumeAfterRestore` clears both flags and allows the next
///    `messagingService()` call to build a real service.
/// Serialized: all tests share the app-group `UserDefaults` suite
/// that `RestoreInProgressFlag` lives in, so parallel execution
/// would race on flag reads/writes between tests that pause and
/// tests that resume.
@Suite("SessionManager restore lifecycle", .serialized)
struct SessionManagerRestoreTests {
    @Test("pauseForRestore sets the app-group flag; resume clears it")
    func testFlagLifecycle() async throws {
        let session = makeSession()
        // Baseline: flag is not set before any restore.
        clearFlag()
        #expect(!RestoreInProgressFlag.isSet(environment: .tests))

        try await session.pauseForRestore()
        #expect(RestoreInProgressFlag.isSet(environment: .tests))

        await session.resumeAfterRestore()
        #expect(!RestoreInProgressFlag.isSet(environment: .tests))
    }

    @Test("messagingService() returns a RestoreInProgressError placeholder while paused")
    func testPlaceholderDuringPause() async throws {
        let session = makeSession()
        clearFlag()

        try await session.pauseForRestore()
        let service = session.messagingService()
        let state = service.sessionStateManager.currentState
        guard case let .error(error) = state else {
            Issue.record("expected .error state, got \(state)")
            return
        }
        #expect(error is RestoreInProgressError)

        await session.resumeAfterRestore()
    }

    @Test("placeholder is cached — repeated calls return the same instance")
    func testPlaceholderCached() async throws {
        let session = makeSession()
        clearFlag()

        try await session.pauseForRestore()
        let first = session.messagingService()
        let second = session.messagingService()
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))

        await session.resumeAfterRestore()
    }

    @Test("resumeAfterRestore evicts placeholder so next call can build a real service")
    func testResumeEvictsPlaceholder() async throws {
        let session = makeSession()
        clearFlag()

        try await session.pauseForRestore()
        let placeholder = session.messagingService()

        await session.resumeAfterRestore()
        // After resume, next messagingService() call must rebuild — it
        // will hit the normal auth path and either authorize the
        // restored identity or register. Either way, the new service
        // is a *different* object from the placeholder.
        let rebuilt = session.messagingService()
        #expect(ObjectIdentifier(rebuilt) != ObjectIdentifier(placeholder),
                "post-resume rebuild must return a fresh service, not the paused placeholder")
    }

    // MARK: - Helpers

    private func makeSession() -> SessionManager {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        return SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock
        )
    }

    /// Clear the app-group flag before each test so no prior run's
    /// state leaks into the current one. Safe to call even if the
    /// suite doesn't yet exist.
    private func clearFlag() {
        // `set(false, ...)` is the public way to clear; an unset flag
        // and an explicit-false flag read as the same `false`, so this
        // just normalizes both cases.
        try? RestoreInProgressFlag.set(false, environment: .tests)
    }
}
