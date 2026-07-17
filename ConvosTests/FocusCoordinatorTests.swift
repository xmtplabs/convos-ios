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

    func testReFocusToSameValueBumpsRefocusNonceWithoutChangingFocus() {
        coordinator.moveFocus(to: .message)
        coordinator.syncFocusState(.message)

        let nonceBefore = coordinator.refocusNonce

        // Re-requesting the field that is already current must not change
        // `currentFocus` (so the value-driven `onChange` syncs stay silent) but
        // must bump `refocusNonce` so observers re-assert `@FocusState`. This is
        // the reply / attachment path when the keyboard was dismissed without
        // SwiftUI clearing focus, leaving the coordinator's value stale.
        coordinator.moveFocus(to: .message)

        XCTAssertEqual(coordinator.currentFocus, .message)
        XCTAssertEqual(coordinator.refocusNonce, nonceBefore + 1)
    }

    func testMoveToNewValueDoesNotBumpRefocusNonce() {
        coordinator.moveFocus(to: .message)
        coordinator.syncFocusState(.message)

        let nonceBefore = coordinator.refocusNonce

        // A genuine focus change is carried by `currentFocus` itself, so the
        // nonce must stay put - otherwise observers would double-apply and
        // bounce `@FocusState` through nil on every ordinary transition.
        coordinator.moveFocus(to: .sideConvoName)

        XCTAssertEqual(coordinator.currentFocus, .sideConvoName)
        XCTAssertEqual(coordinator.refocusNonce, nonceBefore)
    }

    func testReFocusFromNilDoesNotBumpNonceAndUpdatesFocus() {
        // Starting from the dismissed state, focusing the message field is a
        // real value change, not a re-assert, so it flows through `currentFocus`
        // and leaves the nonce untouched.
        XCTAssertNil(coordinator.currentFocus)
        let nonceBefore = coordinator.refocusNonce

        coordinator.moveFocus(to: .message)

        XCTAssertEqual(coordinator.currentFocus, .message)
        XCTAssertEqual(coordinator.refocusNonce, nonceBefore)
    }
}
