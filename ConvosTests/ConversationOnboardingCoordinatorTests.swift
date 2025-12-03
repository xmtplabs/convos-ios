import XCTest
import UserNotifications
@testable import Convos

@MainActor
final class ConversationOnboardingCoordinatorTests: XCTestCase {
    var coordinator: ConversationOnboardingCoordinator!
    var mockNotificationCenter: MockNotificationCenter!
    let testConversationId = "test-conversation-id"

    override func setUp() async throws {
        try await super.setUp()
        mockNotificationCenter = MockNotificationCenter()
        coordinator = ConversationOnboardingCoordinator(notificationCenter: mockNotificationCenter)

        // Clear user defaults before each test
        UserDefaults.standard.removeObject(forKey: "hasShownQuicknameEditor")
        UserDefaults.standard.removeObject(forKey: "hasCompletedConversationOnboarding")
        UserDefaults.standard.removeObject(forKey: "hasSetQuicknameForConversation_\(testConversationId)")
        UserDefaults.standard.removeObject(forKey: "hasSeenAddAsQuickname")
    }

    override func tearDown() async throws {
        coordinator = nil
        mockNotificationCenter = nil

        // Clean up user defaults after each test
        UserDefaults.standard.removeObject(forKey: "hasShownQuicknameEditor")
        UserDefaults.standard.removeObject(forKey: "hasCompletedConversationOnboarding")
        UserDefaults.standard.removeObject(forKey: "hasSetQuicknameForConversation_\(testConversationId)")
        UserDefaults.standard.removeObject(forKey: "hasSeenAddAsQuickname")

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

        // When waiting for invite, should prioritize notifications first
        XCTAssertEqual(coordinator.state, .requestNotifications)
    }

    func testStart_WaitingForInvite_NotificationsGranted_GoesToIdle() async {
        mockNotificationCenter.authStatus = .authorized
        coordinator.isWaitingForInviteAcceptance = true

        await coordinator.start(for: testConversationId)
        XCTAssertTrue(coordinator.isWaitingForInviteAcceptance)

        // When notifications already granted and we're waiting, go to idle state
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testInviteWasAccepted_NotificationsAlreadyGranted_GoesToQuickname() async {
        mockNotificationCenter.authStatus = .authorized

        // Accept the invite while in completed state - should start notification flow
        await coordinator.inviteWasAccepted(for: testConversationId)

        // Since notifications are already granted, should go straight to quickname
        XCTAssertEqual(coordinator.state, .setupQuickname)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_NotificationsNotDetermined_ShowsRequest() async {
        mockNotificationCenter.authStatus = .notDetermined

        // Accept invite while in completed state - should ask for notifications first
        await coordinator.inviteWasAccepted(for: testConversationId)

        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_GrantNotifications_ThenQuickname() async {
        mockNotificationCenter.authStatus = .notDetermined

        // Accept invite while in completed state - should ask for notifications
        await coordinator.inviteWasAccepted(for: testConversationId)
        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)

        // Note: We can't test requestNotificationPermission() as it calls the real PushNotificationRegistrar
        // This test verifies the flow gets to the request state correctly
    }

    func testInviteWasAccepted_NotificationsDenied_ShowsDenied() async {
        mockNotificationCenter.authStatus = .denied

        // Accept invite while in completed state with denied notifications
        await coordinator.inviteWasAccepted(for: testConversationId)

        // Should show denied state
        XCTAssertEqual(coordinator.state, .notificationsDenied)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    // MARK: - Normal Flow Tests (Not Waiting for Invite)

    func testStart_NormalFlow_PrioritizesQuicknameThenNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined

        // Start normal flow (not waiting for invite)
        await coordinator.start(for: testConversationId)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)

        // Should prioritize quickname first
        XCTAssertEqual(coordinator.state, .setupQuickname)

        // Complete quickname
        await coordinator.setupQuicknameDidAutoDismiss()

        // Then should go to notifications
        XCTAssertEqual(coordinator.state, .requestNotifications)
    }

    func testStart_FirstTimeUser_ShowsNonDismissibleSetupQuickname() async {
        await coordinator.start(for: testConversationId)
        XCTAssertEqual(coordinator.state, .setupQuickname)
    }

    func testDidTapSetupQuickname_MarksAsShown() async {
        await coordinator.start(for: testConversationId)
        coordinator.didTapProfilePhoto()

        let hasShown = UserDefaults.standard.bool(forKey: "hasShownQuicknameEditor")
        XCTAssertTrue(hasShown)
    }

    // MARK: - Auto-Dismiss Setup Quickname Tests

    func testStart_HasSeenEditorWithQuickname_ShowsCorrectState() async {
        // Mark as having shown the editor
        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")

        // User's actual quickname settings will determine the state
        await coordinator.start(for: testConversationId)

        // Should show either setupQuickname (auto-dismiss) or addQuickname depending on user's settings
        let quicknameSettings = QuicknameSettings.current()
        if quicknameSettings.isDefault {
            // User has no quickname, should show auto-dismissing setup
            XCTAssertEqual(coordinator.state, .setupQuickname)
        } else {
            // User has a quickname, should show add (pattern match to avoid UIImage comparison)
            if case .addQuickname = coordinator.state {
                XCTAssertTrue(true, "Should show addQuickname for user with configured quickname")
            } else {
                XCTFail("Expected addQuickname state, got \(coordinator.state)")
            }
        }
    }

    func testSetupQuicknameDidAutoDismiss_TransitionsToNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.start(for: testConversationId)
        await coordinator.setupQuicknameDidAutoDismiss()

        XCTAssertEqual(coordinator.state, .requestNotifications)
    }

    // MARK: - Notification Permission Tests

    // Note: requestNotificationPermission() calls PushNotificationRegistrar which we can't mock
    // These tests verify the flow leading up to and after notification states

    func testTransitionToNotifications_AlreadyAuthorized_Completes() async {
        mockNotificationCenter.authStatus = .authorized

        await coordinator.start(for: testConversationId)
        await coordinator.setupQuicknameDidAutoDismiss()

        // Should skip to completed since already authorized
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Complete Flow Tests

    func testComplete_MarksAsCompleted() async {
        await coordinator.complete()

        XCTAssertEqual(coordinator.state, .idle)
        let hasCompleted = UserDefaults.standard.bool(forKey: "hasCompletedConversationOnboarding")
        XCTAssertTrue(hasCompleted)
    }

    func testStart_AlreadySetQuicknameForConversation_GoesToNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined

        // Manually mark as having set quickname for this conversation
        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")
        UserDefaults.standard.set(true, forKey: "hasSetQuicknameForConversation_\(testConversationId)")

        // Starting should skip quickname and go straight to notifications
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
        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")

        coordinator.reset()

        let hasCompleted = UserDefaults.standard.bool(forKey: "hasCompletedConversationOnboarding")
        let hasShown = UserDefaults.standard.bool(forKey: "hasShownQuicknameEditor")

        XCTAssertFalse(hasCompleted)
        XCTAssertFalse(hasShown)
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Per-Conversation Quickname Tests

    func testDidSelectQuickname_TransitionsToNotifications() async {
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.start(for: testConversationId)
        XCTAssertEqual(coordinator.state, .setupQuickname)

        await coordinator.didSelectQuickname()

        XCTAssertEqual(coordinator.state, .requestNotifications)
    }

    func testStart_DifferentConversations_TrackedSeparately() async {
        let conversation1 = "conversation-1"
        let conversation2 = "conversation-2"

        // Mark as having shown editor and set quickname for conversation1
        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")
        UserDefaults.standard.set(true, forKey: "hasSetQuicknameForConversation_\(conversation1)")
        mockNotificationCenter.authStatus = .notDetermined

        // Start for conversation2 should still show a quickname prompt (not go to notifications)
        coordinator.state = .idle // Reset state to completed for new conversation
        await coordinator.start(for: conversation2)

        // Should show some quickname state for conversation2 (not notifications or completed)
        switch coordinator.state {
        case .setupQuickname, .addQuickname:
            XCTAssertTrue(true, "Should show a quickname state for new conversation")
        case .started:
            XCTFail("Should be in started state")
        case .presentingProfileSettings:
            XCTFail("Should not present settings here")
        case .savedAsQuicknameSuccess:
            XCTFail("Should not skip to saved state")
        case .quicknameLearnMore:
            XCTFail("Should not skip to learn more")
        case .requestNotifications, .notificationsEnabled, .notificationsDenied:
            XCTFail("Should not skip to notifications for new conversation")
        case .idle:
            XCTFail("Should not be idle for new conversation")
        case .settingUpQuickname:
            XCTFail("Should not be setting up for new conversation")
        case .saveAsQuickname:
            XCTAssertTrue(true, "SaveAsQuickname is also a valid quickname state")
        }

        // Clean up
        UserDefaults.standard.removeObject(forKey: "hasSetQuicknameForConversation_\(conversation1)")
        UserDefaults.standard.removeObject(forKey: "hasSetQuicknameForConversation_\(conversation2)")
    }

    func testReset_WithConversationId_ClearsConversationFlag() async {
        // Set the quickname for this conversation manually
        UserDefaults.standard.set(true, forKey: "hasSetQuicknameForConversation_\(testConversationId)")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasSetQuicknameForConversation_\(testConversationId)"))

        // Reset with conversationId
        coordinator.reset(conversationId: testConversationId)

        // Conversation flag should be cleared
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasSetQuicknameForConversation_\(testConversationId)"))
    }

    // MARK: - App Lifecycle Tests

    func testAppBecomesActive_CompletedState_NotificationsDenied_ShowsDeniedState() async {
        // Complete onboarding
        await coordinator.complete()
        XCTAssertEqual(coordinator.state, .idle)

        // User disables notifications in iOS Settings
        mockNotificationCenter.authStatus = .denied

        // Simulate app becoming active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        // Give it time to process
        try? await Task.sleep(for: .milliseconds(100))

        // Should transition to denied state
        XCTAssertEqual(coordinator.state, .notificationsDenied)
    }

    func testAppBecomesActive_DeniedState_NotificationsEnabled_ShowsEnabledThenCompletes() async {
        mockNotificationCenter.authStatus = .denied

        // Start in denied state
        await coordinator.start(for: testConversationId)
        await coordinator.setupQuicknameDidAutoDismiss()
        XCTAssertEqual(coordinator.state, .notificationsDenied)

        // User enables notifications in iOS Settings
        mockNotificationCenter.authStatus = .authorized

        // Simulate app becoming active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        // Give it time to process
        try? await Task.sleep(for: .milliseconds(100))

        // Should show success state
        XCTAssertEqual(coordinator.state, .notificationsEnabled)

        // After delay, should complete
        try? await Task.sleep(for: .seconds(2.1))
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testAppBecomesActive_DeniedState_EnabledAfterInviteFlow_ContinuesToQuickname() async {
        mockNotificationCenter.authStatus = .denied

        // Accept invite with denied notifications - should show denied state
        await coordinator.inviteWasAccepted(for: testConversationId)
        XCTAssertEqual(coordinator.state, .notificationsDenied)

        // User enables notifications in iOS Settings
        mockNotificationCenter.authStatus = .authorized

        // Simulate app becoming active
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        // Give it time to process
        try? await Task.sleep(for: .milliseconds(100))

        // Should show success state
        XCTAssertEqual(coordinator.state, .notificationsEnabled)

        // After delay, should go to quickname (not complete, because invite flow)
        try? await Task.sleep(for: .seconds(2.1))
        XCTAssertEqual(coordinator.state, .setupQuickname)
    }
}
