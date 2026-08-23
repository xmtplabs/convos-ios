#if canImport(UIKit)
@testable import ConvosComposer
import CoreGraphics
import SwiftUI
import Testing

/// Regression coverage for the composer focus/keyboard spin: opening the agent
/// composer's `+` menu on an iPhone (compact) triggered an input-accessory
/// relayout storm whose frame-change notifications re-entered
/// `FocusCoordinator`, which kept re-deriving the keyboard type and re-beginning
/// a no-op programmatic transition. Assigning `currentFocus` the value it
/// already held still triggered Observation, re-rendering the composer and
/// relaying out the accessory - a tight main-thread spin that ate the
/// "Connections" tap. These tests drive the screen-free core of the state
/// machine directly and assert the coordinator ignores self-induced, no-op
/// events.
@MainActor
@Suite("FocusCoordinator keyboard spin")
struct FocusCoordinatorSpinTests {
    private let screenHeight: CGFloat = 852
    // Software keyboard up: on-screen, substantial height.
    private let onScreen = CGRect(x: 0, y: 512, width: 393, height: 340)
    // Momentarily reported off-screen while the accessory view re-lays-out.
    private let offScreen = CGRect(x: 0, y: 852, width: 393, height: 340)

    @Test("compact composer does not spin on a relayout frame-change storm")
    func doesNotSpinOnFrameChangeStorm() {
        let coordinator = FocusCoordinator(horizontalSizeClass: .compact)

        coordinator.updateKeyboardState(screenHeight: screenHeight, frame: onScreen, isShowEvent: true, isFrameChange: false)
        #expect(coordinator.keyboardType == .standard)
        #expect(coordinator.currentFocus == nil)
        #expect(coordinator.isProgrammaticTransition == false)

        // A single relayout frame-change reporting the keyboard "down" must not
        // reset the latched type (fix 3) nor begin a transition (fix 1). This is
        // the sharpest mutation detector: reverting either guard fails here.
        coordinator.updateKeyboardState(screenHeight: screenHeight, frame: offScreen, isShowEvent: false, isFrameChange: true)
        #expect(coordinator.keyboardType == .standard)
        #expect(coordinator.isProgrammaticTransition == false)

        // The full storm: dozens of hide/show frame-change pairs.
        for _ in 0..<50 {
            coordinator.updateKeyboardState(screenHeight: screenHeight, frame: offScreen, isShowEvent: false, isFrameChange: true)
            coordinator.updateKeyboardState(screenHeight: screenHeight, frame: onScreen, isShowEvent: true, isFrameChange: true)
        }
        #expect(coordinator.keyboardType == .standard)
        #expect(coordinator.currentFocus == nil)
        #expect(coordinator.isProgrammaticTransition == false)
    }

    @Test("a genuine hide still resets the latched keyboard type")
    func genuineHideStillResets() {
        let coordinator = FocusCoordinator(horizontalSizeClass: .compact)

        coordinator.updateKeyboardState(screenHeight: screenHeight, frame: onScreen, isShowEvent: true, isFrameChange: false)
        #expect(coordinator.keyboardType == .standard)

        // A real keyboardWillHide (not a frame change) must downgrade so the next
        // appearance is re-detected - the frame-change latch must not swallow it.
        coordinator.updateKeyboardState(screenHeight: screenHeight, frame: offScreen, isShowEvent: false, isFrameChange: false)
        #expect(coordinator.keyboardType == .unknown)
    }

    @Test("an external keyboard on iPad still adopts the message default")
    func externalKeyboardStillFocusesMessageOnRegular() {
        let coordinator = FocusCoordinator(horizontalSizeClass: .regular)

        // External keyboard reports an off-screen (or tiny) frame on a show event.
        coordinator.updateKeyboardState(screenHeight: screenHeight, frame: offScreen, isShowEvent: true, isFrameChange: false)
        #expect(coordinator.keyboardType == .external)
        // Regular width + external keeps focus on the message field (default),
        // so the idempotency guard must not suppress this real transition.
        #expect(coordinator.currentFocus == .message)
    }
}
#endif
