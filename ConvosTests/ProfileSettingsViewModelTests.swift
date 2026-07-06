@testable import Convos
import ConvosCore
import XCTest

/// Regression coverage for the race condition where setting a profile in
/// Settings -> My info, then immediately joining a group, still surfaced the
/// "Add your name and pic" prompt. The synchronous write side of `save()`
/// must land the `hasShownProfileEditor` flag before the async writer Task
/// completes, so the onboarding coordinator sees a populated profile when
/// the user navigates to the next screen.
@MainActor
final class ProfileSettingsViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hasShownProfileEditor")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hasShownProfileEditor")
        MainActor.assumeIsolated {
            ProfileSettingsViewModel.shared.editingDisplayName = ""
            ProfileSettingsViewModel.shared.profileImage = nil
        }
        super.tearDown()
    }

    func testSaveSynchronouslyMarksProfileEditorShownWhenNameSet() {
        let viewModel = ProfileSettingsViewModel.shared
        viewModel.editingDisplayName = "Cameron"

        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasShownProfileEditor"))

        viewModel.save()

        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "hasShownProfileEditor"),
            "save() must set hasShownProfileEditor synchronously so the onboarding " +
            "coordinator sees the flag even if the user navigates before the async " +
            "writer Task completes"
        )
    }

    func testSaveDoesNotMarkShownWhenBothNameAndImageAreEmpty() {
        let viewModel = ProfileSettingsViewModel.shared
        viewModel.editingDisplayName = ""
        viewModel.profileImage = nil

        viewModel.save()

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "hasShownProfileEditor"),
            "save() with an empty profile must not flip the flag; the user has not " +
            "actually set anything"
        )
    }

    func testSaveTrimsWhitespaceBeforeDecidingWhetherToMark() {
        let viewModel = ProfileSettingsViewModel.shared
        viewModel.editingDisplayName = "   "

        viewModel.save()

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "hasShownProfileEditor"),
            "Whitespace-only names should be treated as empty"
        )
    }

    // MARK: - Rebind after Delete all data

    /// `rebind` must re-point the singleton's writer at the new session, so a
    /// save after rebind lands in the new inbox's writer and not the stale one.
    /// This is the core of the "profile not saving after Delete all data" fix:
    /// delete-all registers a fresh inbox, and the singleton must follow it.
    func testRebindRoutesSavesToTheNewSessionsWriter() async throws {
        let oldWriter = MockMyGlobalProfileWriter()
        let newWriter = MockMyGlobalProfileWriter()
        let oldSession = MockInboxesService(
            mockMessagingService: MockMessagingService(myGlobalProfileWriter: oldWriter)
        )
        let newSession = MockInboxesService(
            mockMessagingService: MockMessagingService(myGlobalProfileWriter: newWriter)
        )

        let viewModel = ProfileSettingsViewModel.shared

        viewModel.rebind(session: oldSession)
        viewModel.editingDisplayName = "Alice"
        try await viewModel.saveAndAwait()
        XCTAssertEqual(oldWriter.stored?.name, "Alice")

        // Simulate "Delete all data": the singleton is rebound to a fresh
        // session backed by a new inbox/writer.
        viewModel.rebind(session: newSession)
        viewModel.editingDisplayName = "Bob"
        try await viewModel.saveAndAwait()

        XCTAssertEqual(
            newWriter.stored?.name, "Bob",
            "After rebind, a save must target the new session's writer"
        )
        XCTAssertEqual(
            oldWriter.stored?.name, "Alice",
            "The pre-rebind (stale) writer must not receive saves after rebind"
        )
    }

    /// End-to-end: `AppSettingsViewModel.deleteAllData` must rebind the profile
    /// singleton to the new session, so a later "My Info" save reaches the new
    /// inbox instead of the dead one (the reported bug).
    func testDeleteAllDataRebindsProfileSettingsToTheNewSession() async {
        // The singleton starts bound to a stale session (the pre-delete inbox) -
        // the state that, before the fix, survived "Delete all data" and
        // swallowed later saves.
        let staleWriter = MockMyGlobalProfileWriter()
        ProfileSettingsViewModel.shared.rebind(
            session: MockInboxesService(
                mockMessagingService: MockMessagingService(myGlobalProfileWriter: staleWriter)
            )
        )

        // The session AppSettings holds; after delete-all its messaging service
        // is the freshly-built one. Model that with a distinct writer.
        let newWriter = MockMyGlobalProfileWriter()
        let session = MockInboxesService(
            mockMessagingService: MockMessagingService(myGlobalProfileWriter: newWriter)
        )
        let appSettings = AppSettingsViewModel(session: session)

        let done = expectation(description: "delete-all complete")
        appSettings.deleteAllData { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        // A "My Info" save after delete-all must reach the new session's writer.
        ProfileSettingsViewModel.shared.editingDisplayName = "Cameron"
        try? await ProfileSettingsViewModel.shared.saveAndAwait()

        XCTAssertEqual(
            newWriter.stored?.name, "Cameron",
            "After Delete all data, a My Info save must target the freshly-bound session"
        )
        XCTAssertNil(
            staleWriter.stored?.name,
            "Saves must not reach the pre-delete session's writer"
        )
    }
}
