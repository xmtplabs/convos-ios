@testable import Convos
import UserNotifications
import XCTest

@MainActor
final class ConversationOnboardingCoordinatorTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    var coordinator: ConversationOnboardingCoordinator!
    // swiftlint:disable:next implicitly_unwrapped_optional
    var mockNotificationCenter: MockNotificationCenter!
    // swiftlint:disable:next explicit_type_interface
    let testConversationId = "test-conversation-id"
    let testAutodismissDuration: CGFloat = 0.05

    func cleanUpUserDefaults(target userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: "hasShownProfileEditor")
        userDefaults.removeObject(forKey: "hasCompletedConversationOnboarding")
        userDefaults.removeObject(forKey: "hasSetProfileForConversation_\(testConversationId)")
        userDefaults.removeObject(forKey: "hasSeenAddAsProfile")
        userDefaults.removeObject(forKey: "hasShownNUXPaywall")
    }

    override func setUp() async throws {
        try await super.setUp()
        mockNotificationCenter = MockNotificationCenter()
        coordinator = ConversationOnboardingCoordinator(
            notificationCenter: mockNotificationCenter,
            autodismissDurationOverride: testAutodismissDuration
        )

        cleanUpUserDefaults()

        // The coordinator reads `ProfileSettingsViewModel.shared` (a
        // singleton); reset it so a non-default profile left by another
        // test can't push `start()` down the auto-apply branch. Mark it
        // loaded so `start()` doesn't wait out the profile-load gate;
        // tests covering the gate set `.loading` explicitly.
        ProfileSettingsViewModel.shared.editingDisplayName = ""
        ProfileSettingsViewModel.shared.profileImage = nil
        ProfileSettingsViewModel.shared.loadState = .loaded
    }

    override func tearDown() async throws {
        coordinator = nil
        mockNotificationCenter = nil

        cleanUpUserDefaults()

        ProfileSettingsViewModel.shared.editingDisplayName = ""
        ProfileSettingsViewModel.shared.profileImage = nil
        ProfileSettingsViewModel.shared.loadState = .loaded

        try await super.tearDown()
    }

    // MARK: - Initial State Tests
    func testInitialState() {
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Waiting for Invite Tests

    func testStart_WaitingForInvite_PrioritizesNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.start(for: testConversationId)
        XCTAssertTrue(coordinator.isWaitingForInviteAcceptance)

        XCTAssertEqual(coordinator.state, .requestNotifications)
    }

    func testStart_WaitingForInvite_NotificationsGranted_GoesToStarted() async {
        mockNotificationCenter.authStatus = .authorized
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.start(for: testConversationId)
        XCTAssertTrue(coordinator.isWaitingForInviteAcceptance)

        XCTAssertEqual(coordinator.state, .started)
    }

    func testInviteWasAccepted_NotificationsAlreadyGranted_CompletesWithoutPrompt() async {
        mockNotificationCenter.authStatus = .authorized
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.inviteWasAccepted(for: testConversationId)

        // Profile setup is owned by the launch Nametag sheet; with
        // notifications already granted the flow completes quietly.
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_NotificationsNotDetermined_ShowsRequest() async {
        mockNotificationCenter.authStatus = .notDetermined
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.inviteWasAccepted(for: testConversationId)

        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_GrantNotifications_ThenProfile() async {
        mockNotificationCenter.authStatus = .notDetermined
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.inviteWasAccepted(for: testConversationId)
        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_NotificationsDenied_ShowsDenied() async {
        mockNotificationCenter.authStatus = .denied
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.inviteWasAccepted(for: testConversationId)

        XCTAssertEqual(coordinator.state, .notificationsDenied)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    // MARK: - Normal Flow Tests (Not Waiting for Invite)

    func testStart_FirstTimeUser_UnsetProfile_ProceedsToNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.start(for: testConversationId)

        // The Nametag sheet owns profile setup; the conversation flow never
        // prompts and moves straight to the notifications step.
        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(testConversationId)"),
            "An unset profile must not preemptively mark the per-conversation flag"
        )
    }

    // MARK: - Auto-Dismiss Setup Profile Tests

    func testStart_HasSeenEditorWithProfile_AutoAppliesAndAdvances() async {
        UserDefaults.standard.set(true, forKey: "hasShownProfileEditor")
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.start(for: testConversationId)

        XCTAssertEqual(coordinator.state, .requestNotifications)
        if !ProfileSettingsViewModel.shared.profileSettings.isDefault {
            XCTAssertTrue(
                UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(testConversationId)"),
                "Auto-apply must mark the per-conversation flag"
            )
        }
    }

    // MARK: - Complete Flow Tests

    func testComplete_MarksAsCompleted() async {
        await coordinator.complete()

        XCTAssertEqual(coordinator.state, .idle)
        let hasCompleted = UserDefaults.standard.bool(forKey: "hasCompletedConversationOnboarding")
        XCTAssertTrue(hasCompleted)
    }

    func testStart_AlreadySetProfileForConversation_GoesToNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined

        UserDefaults.standard.set(true, forKey: "hasShownProfileEditor")
        UserDefaults.standard.set(true, forKey: "hasSetProfileForConversation_\(testConversationId)")

        await coordinator.start(for: testConversationId)
        XCTAssertEqual(coordinator.state, .requestNotifications)
    }

    // MARK: - Skip Tests

    func testSkip_CompletesOnboarding() async {
        await coordinator.start(for: testConversationId)
        XCTAssertNotEqual(coordinator.state, .idle)

        await coordinator.skip()
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Reset Tests

    func testReset_ClearsAllState() async {
        UserDefaults.standard.set(true, forKey: "hasCompletedConversationOnboarding")
        UserDefaults.standard.set(true, forKey: "hasShownProfileEditor")
        UserDefaults.standard.set(true, forKey: "hasShownNUXPaywall")

        coordinator.reset()

        let hasCompleted = UserDefaults.standard.bool(forKey: "hasCompletedConversationOnboarding")
        let hasShown = UserDefaults.standard.bool(forKey: "hasShownProfileEditor")
        let hasShownNUX = UserDefaults.standard.bool(forKey: "hasShownNUXPaywall")

        XCTAssertFalse(hasCompleted)
        XCTAssertFalse(hasShown)
        XCTAssertFalse(hasShownNUX, "reset() must clear hasShownNUXPaywall so the NUX paywall re-appears on the next onboarding pass")
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testReset_WithConversationId_ClearsNUXPaywallFlag() async {
        UserDefaults.standard.set(true, forKey: "hasShownNUXPaywall")

        coordinator.reset(conversationId: testConversationId)

        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "hasShownNUXPaywall"),
            "reset(conversationId:) must clear hasShownNUXPaywall — it's an onboarding-reset path too"
        )
    }

    // MARK: - Per-Conversation Profile Tests

    func testStart_DifferentConversations_TrackedSeparately() async {
        let conversation1 = "conversation-1"
        let conversation2 = "conversation-2"

        UserDefaults.standard.set(true, forKey: "hasShownProfileEditor")
        UserDefaults.standard.set(true, forKey: "hasSetProfileForConversation_\(conversation1)")
        mockNotificationCenter.authStatus = .notDetermined

        coordinator.state = .idle
        await coordinator.start(for: conversation2)

        XCTAssertEqual(coordinator.state, .requestNotifications)

        UserDefaults.standard.removeObject(forKey: "hasSetProfileForConversation_\(conversation1)")
        UserDefaults.standard.removeObject(forKey: "hasSetProfileForConversation_\(conversation2)")
    }

    func testReset_WithConversationId_ClearsConversationFlag() async {
        UserDefaults.standard.set(true, forKey: "hasSetProfileForConversation_\(testConversationId)")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(testConversationId)"))

        coordinator.reset(conversationId: testConversationId)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(testConversationId)"))
    }

    // MARK: - Completed Onboarding Tests

    func testStart_HasCompletedOnboarding_NewConversation_SurfacesProfileOrAutoApplies() async {
        mockNotificationCenter.authStatus = .authorized
        UserDefaults.standard.set(true, forKey: "hasCompletedConversationOnboarding")
        UserDefaults.standard.set(true, forKey: "hasShownProfileEditor")

        let newConversationId = "new-convo-after-onboarding"
        await coordinator.start(for: newConversationId)

        // Notifications already granted, so the flow completes either way;
        // the per-conversation flag is only marked when a profile exists.
        XCTAssertEqual(coordinator.state, .idle)
        let profileSettings = ProfileSettingsViewModel.shared.profileSettings
        XCTAssertEqual(
            UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(newConversationId)"),
            !profileSettings.isDefault,
            "Auto-apply marks the per-conversation flag only when a profile exists"
        )
        UserDefaults.standard.removeObject(forKey: "hasSetProfileForConversation_\(newConversationId)")
    }

    func testStart_HasCompletedOnboarding_ReopensSameConversation_Skips() async {
        mockNotificationCenter.authStatus = .authorized
        UserDefaults.standard.set(true, forKey: "hasCompletedConversationOnboarding")
        UserDefaults.standard.set(true, forKey: "hasShownProfileEditor")

        let conversationId = "convo-seen-before"
        UserDefaults.standard.set(true, forKey: "hasSetProfileForConversation_\(conversationId)")

        await coordinator.start(for: conversationId)

        XCTAssertEqual(coordinator.state, .idle, "Re-opening a convo with the per-conversation flag set must not re-prompt")

        UserDefaults.standard.removeObject(forKey: "hasSetProfileForConversation_\(conversationId)")
    }

    // MARK: - Profile Load Gate Tests

    func testStart_ProfileNotLoaded_TimesOutQuietly() async {
        ProfileSettingsViewModel.shared.loadState = .loading
        let gatedCoordinator = ConversationOnboardingCoordinator(
            notificationCenter: mockNotificationCenter,
            autodismissDurationOverride: testAutodismissDuration,
            profileLoadTimeout: 0.05
        )

        await gatedCoordinator.start(for: testConversationId)

        XCTAssertEqual(
            gatedCoordinator.state, .idle,
            "With the profile state unknown, the coordinator must go quiet instead of prompting"
        )
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "hasShownProfileEditor"),
            "A timed-out start must not mutate onboarding flags"
        )
    }

    func testStart_ProfileLoadsWhileWaiting_AutoAppliesExistingProfile() async {
        ProfileSettingsViewModel.shared.loadState = .loading
        ProfileSettingsViewModel.shared.editingDisplayName = "Alice"
        mockNotificationCenter.authStatus = .notDetermined

        let startTask = Task { await coordinator.start(for: testConversationId) }
        // Let start() reach the profile-load gate before resolving it.
        try? await Task.sleep(for: .milliseconds(20))
        ProfileSettingsViewModel.shared.loadState = .loaded
        await startTask.value

        XCTAssertEqual(
            coordinator.state, .requestNotifications,
            "A profile arriving while the coordinator waits must auto-apply, not prompt"
        )
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(testConversationId)"))
    }

    func testStart_ExistingProfile_EditorFlagUnset_DoesNotPrompt() async {
        // A populated profile with no device-local editor flag is the
        // freshly-paired-device shape (flags are written asynchronously
        // after the identity seed): the profile itself must win.
        ProfileSettingsViewModel.shared.editingDisplayName = "Alice"
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.start(for: testConversationId)

        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "hasShownProfileEditor"),
            "Auto-apply must backfill the editor flag so dependent gates agree a profile exists"
        )
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasSetProfileForConversation_\(testConversationId)"))
    }

    func testStart_ExistingProfile_PerConversationFlagSet_Skips() async {
        ProfileSettingsViewModel.shared.editingDisplayName = "Alice"
        UserDefaults.standard.set(true, forKey: "hasSetProfileForConversation_\(testConversationId)")
        mockNotificationCenter.authStatus = .authorized

        await coordinator.start(for: testConversationId)

        XCTAssertEqual(coordinator.state, .idle, "Known profile + per-conversation flag must skip straight through")
    }

    // MARK: - App Lifecycle Tests

    func testAppBecomesActive_CompletedState_NotificationsDenied_ShowsDeniedState() async {
        await coordinator.complete()
        XCTAssertEqual(coordinator.state, .idle)

        mockNotificationCenter.authStatus = .denied

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(coordinator.state, .notificationsDenied)
    }

    func testAppBecomesActive_DeniedState_NotificationsEnabled_ShowsEnabledThenCompletes() async {
        mockNotificationCenter.authStatus = .denied

        await coordinator.start(for: testConversationId)
        XCTAssertEqual(coordinator.state, .notificationsDenied)

        mockNotificationCenter.authStatus = .authorized

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await waitForState(.notificationsEnabled)

        await waitForAutodismiss()
        await waitForState(.idle)
    }

    func testAppBecomesActive_DeniedState_EnabledAfterInviteFlow_Completes() async {
        mockNotificationCenter.authStatus = .denied
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.inviteWasAccepted(for: testConversationId)
        XCTAssertEqual(coordinator.state, .notificationsDenied)

        mockNotificationCenter.authStatus = .authorized

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await waitForState(.notificationsEnabled)

        await waitForAutodismiss()
        // Profile setup is owned by the Nametag sheet; after the enabled
        // pill autodismisses the flow completes.
        await waitForState(.idle)
    }

    private func waitForState(
        _ expected: ConversationOnboardingState,
        timeout: TimeInterval = 0.3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if coordinator.state == expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTFail(
            "Timed out waiting for state \(expected). Last state: \(coordinator.state)",
            file: file,
            line: line
        )
    }

    private func waitForAutodismiss() async {
        let duration = TimeInterval(testAutodismissDuration)
        let extraMargin = 0.05
        try? await Task.sleep(for: .seconds(duration + extraMargin))
    }
}
