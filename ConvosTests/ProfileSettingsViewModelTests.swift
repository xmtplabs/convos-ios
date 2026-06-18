@testable import Convos
import ConvosCore
import UIKit
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

    /// Regression: editing only the name must not wipe the stored avatar or
    /// global metadata. The old full-row `save(... metadata: nil)` replaced
    /// every field, so a name edit dropped the avatar (when unhydrated) and
    /// always nulled metadata. The field-preserving `update(...)` path keeps them.
    func testSaveAndAwaitPreservesAvatarAndMetadataOnNameOnlyEdit() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let imageData = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
        let metadata: ProfileMetadata = ["emoji": .string("🎯")]
        let initial = MyProfile(
            inboxId: "inbox-1",
            name: "Old Name",
            imageData: imageData,
            imageAssetIdentifier: nil,
            imageContentDigest: nil,
            metadata: metadata,
            updatedAt: Date()
        )
        let writer = MockMyGlobalProfileWriter(stored: initial)
        let repository = MockMyGlobalProfileRepository(initial: initial)
        let session = MockInboxesService(
            mockMessagingService: MockMessagingService(
                myGlobalProfileWriter: writer,
                myGlobalProfileRepository: repository
            )
        )

        let viewModel = ProfileSettingsViewModel.shared
        viewModel.rebind(session: session)
        // bindInternal's synchronous fast path applies the loaded profile.
        XCTAssertEqual(viewModel.editingDisplayName, "Old Name")
        XCTAssertNotNil(viewModel.profileImage)

        viewModel.editingDisplayName = "New Name"
        try await viewModel.saveAndAwait()

        XCTAssertEqual(writer.stored?.name, "New Name")
        XCTAssertNotNil(writer.stored?.imageData, "avatar must survive a name-only edit")
        XCTAssertEqual(writer.stored?.metadata, metadata, "metadata must survive a name-only edit")
    }
}
