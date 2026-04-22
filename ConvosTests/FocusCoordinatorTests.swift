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

    func testMoveToSideConvoNamePreservesFocus() {
        coordinator.moveFocus(to: .sideConvoName)
        coordinator.syncFocusState(.sideConvoName)

        XCTAssertEqual(coordinator.currentFocus, .sideConvoName)
    }

    func testEndEditingSideConvoNameReturnsToMessage() {
        coordinator.moveFocus(to: .message)
        coordinator.syncFocusState(.message)

        coordinator.moveFocus(to: .sideConvoName)
        coordinator.syncFocusState(.sideConvoName)

        coordinator.endEditing(for: .sideConvoName, context: .quickEditor)

        XCTAssertEqual(coordinator.currentFocus, .message)
    }

    func testSizeClassChangeDoesNotInterruptSideConvoNameEditing() {
        coordinator.moveFocus(to: .sideConvoName)
        coordinator.syncFocusState(.sideConvoName)

        coordinator.horizontalSizeClass = .regular

        XCTAssertEqual(coordinator.currentFocus, .sideConvoName)
    }

    func testNilSyncWhileEditingSideConvoNameIsIgnored() {
        coordinator.moveFocus(to: .sideConvoName)
        coordinator.syncFocusState(.sideConvoName)

        coordinator.syncFocusState(nil)

        XCTAssertEqual(coordinator.currentFocus, .sideConvoName)
    }

    func testSwiftUIInitiatedFocusToSideConvoNameFromMessagePreservesReturnPath() {
        coordinator.moveFocus(to: .message)
        coordinator.syncFocusState(.message)

        // Simulates a user tap on the side-convo name field that drives focus
        // via SwiftUI's FocusState without going through moveFocus first.
        coordinator.syncFocusState(.sideConvoName)
        XCTAssertEqual(coordinator.currentFocus, .sideConvoName)

        coordinator.endEditing(for: .sideConvoName, context: .quickEditor)

        XCTAssertEqual(coordinator.currentFocus, .message)
    }

    func testDismissQuickEditorFromSideConvoNameMovesToMessage() {
        coordinator.moveFocus(to: .sideConvoName)
        coordinator.syncFocusState(.sideConvoName)

        coordinator.dismissQuickEditor()

        XCTAssertEqual(coordinator.currentFocus, .message)
    }

    func testEndEditingSideConvoNameOutsideQuickEditorFallsThroughToDefault() {
        coordinator.moveFocus(to: .sideConvoName)
        coordinator.syncFocusState(.sideConvoName)

        // A non-quickEditor context should hit the `(.sideConvoName, _)`
        // fallthrough arm in `nextFocus(after:context:)` and land on the
        // default focus rather than the `previousFocus` return path.
        coordinator.endEditing(for: .sideConvoName, context: .conversation)

        // On compact size class the default focus is the message field, so
        // this also ensures the coordinator doesn't get wedged on
        // `.sideConvoName` when a non-quickEditor end-of-edit signal arrives.
        XCTAssertNotEqual(coordinator.currentFocus, .sideConvoName)
    }
}
