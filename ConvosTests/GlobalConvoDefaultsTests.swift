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
        XCTAssertTrue(GlobalConvoDefaults.shared.revealModeEnabled)
        XCTAssertFalse(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }

    func testPersistsUpdatedValues() {
        GlobalConvoDefaults.shared.revealModeEnabled = false
        GlobalConvoDefaults.shared.includeInfoWithInvites = true

        XCTAssertFalse(GlobalConvoDefaults.shared.revealModeEnabled)
        XCTAssertTrue(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }

    func testResetRestoresDefaults() {
        GlobalConvoDefaults.shared.revealModeEnabled = false
        GlobalConvoDefaults.shared.includeInfoWithInvites = true

        GlobalConvoDefaults.shared.reset()

        XCTAssertTrue(GlobalConvoDefaults.shared.revealModeEnabled)
        XCTAssertFalse(GlobalConvoDefaults.shared.includeInfoWithInvites)
    }
}
