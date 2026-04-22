import SwiftUI
import XCTest
@testable import Convos

@MainActor
final class FocusCoordinatorTests: XCTestCase {
    var coordinator: FocusCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        coordinator = FocusCoordinator(horizontalSizeClass: .compact)
    }

    override func tearDown() async throws {
        coordinator = nil
        try await super.tearDown()
    }

    func testMoveToEditingSideConvoNamePreservesFocus() {
        coordinator.moveFocus(to: .editingSideConvoName)
        coordinator.syncFocusState(.editingSideConvoName)

        XCTAssertEqual(coordinator.currentFocus, .editingSideConvoName)
    }

    func testEndEditingSideConvoNameReturnsToMessage() {
        coordinator.moveFocus(to: .message)
        coordinator.syncFocusState(.message)

        coordinator.moveFocus(to: .editingSideConvoName)
        coordinator.syncFocusState(.editingSideConvoName)

        coordinator.endEditing(for: .editingSideConvoName, context: .quickEditor)

        XCTAssertEqual(coordinator.currentFocus, .message)
    }

    func testSizeClassChangeDoesNotInterruptSideConvoNameEditing() {
        coordinator.moveFocus(to: .editingSideConvoName)
        coordinator.syncFocusState(.editingSideConvoName)

        coordinator.horizontalSizeClass = .regular

        XCTAssertEqual(coordinator.currentFocus, .editingSideConvoName)
    }

    func testNilSyncWhileEditingSideConvoNameIsIgnored() {
        coordinator.moveFocus(to: .editingSideConvoName)
        coordinator.syncFocusState(.editingSideConvoName)

        coordinator.syncFocusState(nil)

        XCTAssertEqual(coordinator.currentFocus, .editingSideConvoName)
    }
}
