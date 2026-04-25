import XCTest
@testable import Convos

@MainActor
final class GlobalConvoDefaultsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalConvoDefaults.shared.reset()
    }

    override func tearDown() {
        GlobalConvoDefaults.shared.reset()
        super.tearDown()
    }

    func testDefaultValuesWhenUnset() {
        // autoRevealPhotos defaults to false (blur incoming photos by default).
        // includeInfoWithInvites defaults to true (invites carry name/description
        // unless the user opts out per-invite).
        XCTAssertFalse(GlobalConvoDefaults.shared.autoRevealPhotos)
        XCTAssertTrue(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }

    func testPersistsUpdatedValues() {
        GlobalConvoDefaults.shared.autoRevealPhotos = true
        GlobalConvoDefaults.shared.includeInfoWithInvites = true

        XCTAssertTrue(GlobalConvoDefaults.shared.autoRevealPhotos)
        XCTAssertTrue(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }

    func testResetRestoresDefaults() {
        GlobalConvoDefaults.shared.autoRevealPhotos = true
        GlobalConvoDefaults.shared.includeInfoWithInvites = false

        GlobalConvoDefaults.shared.reset()

        XCTAssertFalse(GlobalConvoDefaults.shared.autoRevealPhotos)
        XCTAssertTrue(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }
}
