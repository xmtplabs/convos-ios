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
        ProfileSettingsViewModel.shared.editingDisplayName = ""
        ProfileSettingsViewModel.shared.profileImage = nil
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
}
