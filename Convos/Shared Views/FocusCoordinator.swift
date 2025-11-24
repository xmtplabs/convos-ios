import Foundation
import Observation
import SwiftUI
import UIKit

/// Represents the type of keyboard currently active
enum KeyboardType {
    /// Keyboard type has not been detected yet
    case unknown
    /// Standard on-screen software keyboard
    case standard
    /// External hardware keyboard (e.g., Magic Keyboard, Bluetooth keyboard)
    case external
}

/// Manages focus state, handling hardware keyboard detection
/// and providing smart default focus behavior for iPad vs iPhone
@MainActor
@Observable
final class FocusCoordinator {
    // MARK: - Public Properties

    /// The current focus state - synchronized with SwiftUI's @FocusState
    private(set) var currentFocus: MessagesViewInputFocus?

    /// The type of keyboard currently detected
    private(set) var keyboardType: KeyboardType = .unknown

    var horizontalSizeClass: UserInterfaceSizeClass? {
        didSet {
            // When size class changes, update current focus to match new default if appropriate
            if oldValue != horizontalSizeClass {
                updateFocusForSizeClassChange()
            }
        }
    }

    // MARK: - Private Properties

    /// Tracks whether we're in the middle of a programmatic focus transition
    /// This prevents false positives when detecting manual keyboard dismissal
    private var isProgrammaticTransition: Bool = false

    /// The target focus we're transitioning to (if in a programmatic transition)
    private var transitionTarget: MessagesViewInputFocus?

    /// Tracks whether we're in the middle of a SwiftUI-initiated transition (user tapped a field)
    /// This prevents fighting SwiftUI's natural focus animation
    private(set) var isSwiftUITransition: Bool = false

    /// The target focus for SwiftUI-initiated transitions
    private var swiftUITransitionTarget: MessagesViewInputFocus?

    /// Tracks the focus state before transitioning
    /// Used to return to the previous state when done editing in quickEditor context
    private var previousFocus: MessagesViewInputFocus?

    // MARK: - Initialization

    init(horizontalSizeClass: UserInterfaceSizeClass?) {
        self.horizontalSizeClass = horizontalSizeClass
        setupKeyboardObservation()
    }

    deinit {
        KeyboardListener.shared.remove(delegate: self)
    }

    // MARK: - Public Methods

    /// The default focus state when no field is specifically focused
    /// - On iPad with external keyboard: keeps focus on message field
    /// - Otherwise: nil (allows complete keyboard dismissal)
    var defaultFocus: MessagesViewInputFocus? {
        switch (horizontalSizeClass, keyboardType) {
        case (.regular, .external):
            // iPad with external keyboard - keep focus on message field
            return .message

        case (.regular, .unknown):
            // iPad before keyboard detection - default to nil until we know for sure
            return nil

        default:
            // All other cases: allow complete dismissal (nil)
            // - iPhone (compact size class) with any keyboard
            // - iPad with standard on-screen keyboard
            return nil
        }
    }

    /// Determines the next focus after a field finishes editing
    func nextFocus(after current: MessagesViewInputFocus, context: FocusTransitionContext) -> MessagesViewInputFocus? {
        switch (current, context) {
        case (.displayName, .onboardingQuickname):
            // During onboarding, dismiss keyboard to show onboarding UI
            return nil

        case (.displayName, .quickEditor),
            (.conversationName, .quickEditor):
            // In quickEditor context, return to whatever was focused before
            // If nothing was tracked, fall back to message field or default
            return previousFocus ?? defaultFocus ?? .message

        case (.displayName, .editProfile):
            return .message

        case (.conversationName, .conversationSettings):
            // After editing conversation name in settings, move to message field (or default)
            return defaultFocus ?? .message

        case (.message, .conversation):
            // When sending a message, always re-focus the message field
            return .message

        case (.message, _):
            // Message field ends editing, go to default
            return defaultFocus

        default:
            return defaultFocus
        }
    }

    /// Moves focus to `message` if we're currently focusing the displayName or conversationName
    func dismissQuickEditor() {
        guard currentFocus == .displayName || currentFocus == .conversationName else {
            return
        }

        moveFocus(to: .message)
    }

    /// Programmatically move focus to a specific field
    func moveFocus(to focus: MessagesViewInputFocus?) {
        Log.info("moveFocus called with: \(String(describing: focus)), saving previous: \(String(describing: currentFocus))")
        previousFocus = currentFocus
        beginProgrammaticTransition(to: focus)
        currentFocus = focus
    }

    /// Called when a field finishes editing to determine next focus
    func endEditing(for field: MessagesViewInputFocus, context: FocusTransitionContext = .quickEditor) {
        let nextFocus = nextFocus(after: field, context: context)
        Log.info("endEditing called for: \(field), context: \(context), next: \(String(describing: nextFocus))")

        // Skip redundant work if already at target or transitioning to it
        // This prevents duplicate transitions when syncFocusState(nil) has already handled the field submission
        if currentFocus == nextFocus && !isProgrammaticTransition {
            Log.info("Already at target focus \(String(describing: nextFocus)) - skipping endEditing")
            previousFocus = nil
            return
        }

        if isProgrammaticTransition && transitionTarget == nextFocus {
            Log.info("Already transitioning to target focus \(String(describing: nextFocus)) - skipping endEditing")
            previousFocus = nil
            return
        }

        // Clear previousFocus after using it in nextFocus calculation
        previousFocus = nil

        beginProgrammaticTransition(to: nextFocus)
        currentFocus = nextFocus
    }

    /// Called by the view when SwiftUI's @FocusState has updated
    /// This handles all synchronization logic between SwiftUI's focus state and the coordinator
    func syncFocusState(_ newFocus: MessagesViewInputFocus?) {
        Log.info("syncFocusState called with: \(String(describing: newFocus))")

        // First, confirm any active transitions (this may complete a transition)
        confirmFocusTransition(to: newFocus)

        // Then handle any user-initiated changes
        // Skip if we're already in a transition (programmatic or SwiftUI)
        guard !isProgrammaticTransition && !isSwiftUITransition else {
            Log.info("Skipping focus sync - in transition")
            return
        }

        if newFocus == nil && currentFocus != nil {
            // User manually dismissed keyboard
            handleManualDismissal(viewIsAlreadyAt: newFocus)
        } else if newFocus != currentFocus {
            // User manually changed focus (tapped a different field)
            Log.info("User initiated focus change to: \(String(describing: newFocus))")
            beginSwiftUIInitiatedTransition(to: newFocus)
        }
    }

    /// Called by the view when SwiftUI's @FocusState has updated to confirm the transition
    private func confirmFocusTransition(to actualFocus: MessagesViewInputFocus?) {
        let parts = [
            "confirmFocusTransition called with: \(String(describing: actualFocus))",
            "programmaticTarget: \(String(describing: transitionTarget))",
            "swiftUITarget: \(String(describing: swiftUITransitionTarget))",
            "isProgrammatic: \(isProgrammaticTransition)",
            "isSwiftUI: \(isSwiftUITransition)"
        ]
        Log.info(parts.joined(separator: ", "))

        // Check programmatic transitions first
        if isProgrammaticTransition {
            if actualFocus == transitionTarget {
                Log.info("Programmatic transition completed successfully")
                endProgrammaticTransition()
            } else if actualFocus == nil && transitionTarget != nil {
                // Common case: view was replaced/destroyed during transition
                Log.info("Programmatic transition interrupted by view change - will retry")
                // Keep transition active, view will retry on appear
            } else {
                Log.info("Programmatic transition in progress - actual: \(String(describing: actualFocus)) vs target: \(String(describing: transitionTarget))")
            }
        }

        // Check SwiftUI transitions
        if isSwiftUITransition {
            if actualFocus == swiftUITransitionTarget {
                Log.info("SwiftUI transition completed successfully")
                endSwiftUITransition()
            } else if actualFocus == nil && swiftUITransitionTarget != nil {
                // View was replaced during SwiftUI transition
                Log.info("SwiftUI transition interrupted by view change")
                endSwiftUITransition() // Clear it since view is gone
            } else {
                Log.info("SwiftUI transition in progress - actual: \(String(describing: actualFocus)) vs target: \(String(describing: swiftUITransitionTarget))")
            }
        }
    }

    /// Called by the view when user initiates a focus change (taps a field)
    func beginSwiftUIInitiatedTransition(to target: MessagesViewInputFocus?) {
        // Clear any existing programmatic transition before starting a SwiftUI one
        if isProgrammaticTransition {
            Log.info("Clearing programmatic transition before starting SwiftUI transition")
            endProgrammaticTransition()
        }

        // Save previous focus to allow returning to it after editing
        previousFocus = currentFocus
        Log.info("Beginning SwiftUI-initiated transition from \(String(describing: previousFocus)) to \(String(describing: target))")

        isSwiftUITransition = true
        swiftUITransitionTarget = target
        currentFocus = target
    }

    /// Called when user manually dismisses keyboard - should return to default or stay nil
    func handleManualDismissal(viewIsAlreadyAt viewFocus: MessagesViewInputFocus? = nil) {
        // Ignore if we're in the middle of ANY transition
        // This prevents false positives when SwiftUI temporarily sets focus to nil
        // while transitioning between text fields
        guard !isProgrammaticTransition && !isSwiftUITransition else {
            Log.info("Ignoring manual dismissal during transition (programmatic: \(isProgrammaticTransition), swiftUI: \(isSwiftUITransition))")
            return
        }

        Log.info("Handling manual dismissal - setting focus to default: \(String(describing: defaultFocus))")

        // If there's a default focus (iPad with hardware keyboard), go back to it
        // Otherwise, stay at nil (allow dismissal on iPhone/iPad without hardware keyboard)
        currentFocus = defaultFocus

        // Only begin a transition if we're not already at the target
        // This prevents stuck transitions when dismissing to nil (which is already the view state)
        if defaultFocus != viewFocus && defaultFocus != nil {
            // We have a default focus that's different from the current view state
            beginProgrammaticTransition(to: defaultFocus)
        }
    }

    // MARK: - Private Methods

    private func setupKeyboardObservation() {
        KeyboardListener.shared.add(delegate: self)
    }

    private func updateFocusForSizeClassChange() {
        // Only auto-adjust if we're currently at nil or .message
        // Don't interrupt active editing of displayName or conversationName
        guard currentFocus == nil || currentFocus == .message else {
            return
        }

        Log.info("Updating focus for size class change: \(String(describing: horizontalSizeClass))")

        // Update to the new default based on new size class
        let newDefault = defaultFocus
        if currentFocus != newDefault {
            beginProgrammaticTransition(to: newDefault)
            currentFocus = newDefault
        }
    }

    private func beginProgrammaticTransition(to target: MessagesViewInputFocus?) {
        // Clear any existing transitions before starting a new one
        if isSwiftUITransition {
            Log.info("Clearing SwiftUI transition before starting programmatic transition")
            endSwiftUITransition()
        }

        isProgrammaticTransition = true
        transitionTarget = target
        Log.info("Beginning programmatic transition to: \(String(describing: target))")
    }

    private func endProgrammaticTransition() {
        isProgrammaticTransition = false
        transitionTarget = nil
        Log.info("Ended programmatic transition")
    }

    private func endSwiftUITransition() {
        isSwiftUITransition = false
        swiftUITransitionTarget = nil
        Log.info("Ended SwiftUI transition")
    }

    /// Reset any stale transition state
    private func resetTransitionState() {
        if isProgrammaticTransition || isSwiftUITransition {
            Log.warning("Resetting stale transition state - programmatic: \(isProgrammaticTransition), swiftUI: \(isSwiftUITransition)")
            isProgrammaticTransition = false
            isSwiftUITransition = false
            transitionTarget = nil
            swiftUITransitionTarget = nil
        }
    }

    /// Reset all transitions and set focus to default
    /// Used when conversation changes or view is replaced
    func resetAndSetDefault() {
        Log.info("Resetting transitions and setting default focus: \(String(describing: defaultFocus))")

        // Clear any stuck transitions
        if isProgrammaticTransition || isSwiftUITransition {
            resetTransitionState()
        }

        // Set focus directly without transition tracking
        // This is safe because we're in a fresh view state
        currentFocus = defaultFocus
    }

    private func updateKeyboardState(frame: CGRect, isShowEvent: Bool, screen: UIScreen) {
        // Get screen bounds to determine if keyboard is actually visible
        // Use the screen from the notification, or fall back to main screen
        let screenHeight = screen.bounds.height

        // Check if keyboard frame is on screen
        let keyboardBottomY = frame.origin.y + frame.size.height
        let isKeyboardOnScreen = frame.origin.y < screenHeight && keyboardBottomY > 0

        let newKeyboardType: KeyboardType

        if isShowEvent {
            // During show events, we can reliably detect keyboard type
            if !isKeyboardOnScreen {
                // Keyboard is off-screen during a show event - indicates external keyboard
                newKeyboardType = .external
            } else if frame.size.height < 100 {
                // Keyboard is on-screen but very small (< 100pt) - input accessory bar only
                // This indicates external keyboard with just the accessory view
                newKeyboardType = .external
            } else {
                // Keyboard is on-screen and substantial height - software keyboard
                newKeyboardType = .standard
            }
        } else {
            // During hide events, we can't distinguish between:
            // 1. Software keyboard being dismissed
            // 2. External keyboard being connected
            // So we set to unknown if we were in standard state
            if keyboardType == .standard {
                newKeyboardType = .unknown
            } else {
                // If we're already external or unknown, keep current state
                // (don't change external -> unknown on hide, as external is definitive)
                return
            }
        }

        // Only react if keyboard type actually changed
        guard keyboardType != newKeyboardType else { return }

        let previousKeyboardType = keyboardType
        keyboardType = newKeyboardType

        guard !isProgrammaticTransition && !isSwiftUITransition else {
            Log.info("Skipping keyboard type changed focus sync, in transition...")
            return
        }

        // If keyboard type changed, update current focus to match new default
        // Only do this if we're currently at nil
        // Don't interrupt active editing of displayName or conversationName
        guard currentFocus == nil else { return }
        let newDefault = defaultFocus

        Log.info("Keyboard type changed: \(previousKeyboardType) → \(newKeyboardType), updating focus to: \(String(describing: newDefault))")
        beginProgrammaticTransition(to: newDefault)
        currentFocus = newDefault
    }
}

// MARK: - KeyboardListenerDelegate

extension FocusCoordinator: KeyboardListenerDelegate {
    nonisolated func keyboardWillShow(info: KeyboardInfo) {
        guard let screen = info.screen else { return }
        Task { @MainActor in
            updateKeyboardState(frame: info.frameEnd, isShowEvent: true, screen: screen)
        }
    }

    nonisolated func keyboardDidShow(info: KeyboardInfo) {
        guard let screen = info.screen else { return }
        Task { @MainActor in
            updateKeyboardState(frame: info.frameEnd, isShowEvent: true, screen: screen)
        }
    }

    func keyboardWillHide(info: KeyboardInfo) {
        guard let screen = info.screen else { return }
        // During hide events, we can't distinguish between software keyboard dismissal
        // and external keyboard connection, so set to unknown if we were in standard state
        Task { @MainActor in
            updateKeyboardState(frame: info.frameEnd, isShowEvent: false, screen: screen)
        }
    }

    func keyboardDidHide(info: KeyboardInfo) {
        guard let screen = info.screen else { return }
        // During hide events, we can't distinguish between software keyboard dismissal
        // and external keyboard connection, so set to unknown if we were in standard state
        Task { @MainActor in
            updateKeyboardState(frame: info.frameEnd, isShowEvent: false, screen: screen)
        }
    }

    nonisolated func keyboardWillChangeFrame(info: KeyboardInfo) {
        guard let screen = info.screen else { return }
        Task { @MainActor in
            // Frame changes could be show or hide, detect based on position
            // Use the screen from the notification, or fall back to main screen
            let screenHeight = screen.bounds.height
            let isShowingKeyboard = info.frameEnd.origin.y < screenHeight
            updateKeyboardState(frame: info.frameEnd, isShowEvent: isShowingKeyboard, screen: screen)
        }
    }

    nonisolated func keyboardDidChangeFrame(info: KeyboardInfo) {
        guard let screen = info.screen else { return }
        Task { @MainActor in
            // Frame changes could be show or hide, detect based on position
            // Use the screen from the notification, or fall back to main screen
            let screenHeight = screen.bounds.height
            let isShowingKeyboard = info.frameEnd.origin.y < screenHeight
            updateKeyboardState(frame: info.frameEnd, isShowEvent: isShowingKeyboard, screen: screen)
        }
    }
}

// MARK: - Supporting Types

/// Context for focus transitions to make smart decisions about next focus
enum FocusTransitionContext {
    case onboardingQuickname
    case quickEditor
    case editProfile
    case conversation
    case conversationSettings
}
