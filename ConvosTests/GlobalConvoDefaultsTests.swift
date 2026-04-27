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
        XCTAssertTrue(GlobalConvoDefaults.shared.autoRevealPhotos)
        XCTAssertFalse(GlobalConvoDefaults.shared.includeInfoWithInvites)
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

        XCTAssertTrue(GlobalConvoDefaults.shared.autoRevealPhotos)
        XCTAssertFalse(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }
}
