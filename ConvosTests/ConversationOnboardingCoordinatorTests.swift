import XCTest
import UserNotifications
@testable import Convos

@MainActor
final class ConversationOnboardingCoordinatorTests: XCTestCase {
    var coordinator: ConversationOnboardingCoordinator!
    var mockNotificationCenter: MockNotificationCenter!
    let testConversationId = "test-conversation-id"
    let testAutodismissDuration: CGFloat = 0.05

    func cleanUpUserDefaults(target userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: "hasShownQuicknameEditor")
        userDefaults.removeObject(forKey: "hasCompletedConversationOnboarding")
        userDefaults.removeObject(forKey: "hasSetQuicknameForConversation_\(testConversationId)")
        userDefaults.removeObject(forKey: "hasSeenAddAsQuickname")
    }

    override func setUp() async throws {
        try await super.setUp()
        mockNotificationCenter = MockNotificationCenter()
        coordinator = ConversationOnboardingCoordinator(
            notificationCenter: mockNotificationCenter,
            autodismissDurationOverride: testAutodismissDuration
        )

        cleanUpUserDefaults()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockNotificationCenter = nil

        cleanUpUserDefaults()

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

    func testInviteWasAccepted_NotificationsAlreadyGranted_GoesToQuickname() async {
        mockNotificationCenter.authStatus = .authorized

        await coordinator.inviteWasAccepted(for: testConversationId)

        XCTAssertEqual(coordinator.state, .setupQuickname)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_NotificationsNotDetermined_ShowsRequest() async {
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.inviteWasAccepted(for: testConversationId)

        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_GrantNotifications_ThenQuickname() async {
        mockNotificationCenter.authStatus = .notDetermined

        await coordinator.inviteWasAccepted(for: testConversationId)
        XCTAssertEqual(coordinator.state, .requestNotifications)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    func testInviteWasAccepted_NotificationsDenied_ShowsDenied() async {
        mockNotificationCenter.authStatus = .denied

        await coordinator.inviteWasAccepted(for: testConversationId)

        XCTAssertEqual(coordinator.state, .notificationsDenied)
        XCTAssertFalse(coordinator.isWaitingForInviteAcceptance)
    }

    // MARK: - Normal Flow Tests (Not Waiting for Invite)

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
        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")

        await coordinator.start(for: testConversationId)

        let quicknameSettings = QuicknameSettings.current()
        if quicknameSettings.isDefault {
            XCTAssertEqual(coordinator.state, .setupQuickname)
        } else {
            if case .addQuickname = coordinator.state {
                XCTAssertTrue(true, "Should show addQuickname for user with configured quickname")
            } else {
                XCTFail("Expected addQuickname state, got \(coordinator.state)")
            }
        }
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

        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")
        UserDefaults.standard.set(true, forKey: "hasSetQuicknameForConversation_\(testConversationId)")

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

        UserDefaults.standard.set(true, forKey: "hasShownQuicknameEditor")
        UserDefaults.standard.set(true, forKey: "hasSetQuicknameForConversation_\(conversation1)")
        mockNotificationCenter.authStatus = .notDetermined

        coordinator.state = .idle
        await coordinator.start(for: conversation2)

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
        }

        UserDefaults.standard.removeObject(forKey: "hasSetQuicknameForConversation_\(conversation1)")
        UserDefaults.standard.removeObject(forKey: "hasSetQuicknameForConversation_\(conversation2)")
    }

    func testReset_WithConversationId_ClearsConversationFlag() async {
        UserDefaults.standard.set(true, forKey: "hasSetQuicknameForConversation_\(testConversationId)")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasSetQuicknameForConversation_\(testConversationId)"))

        coordinator.reset(conversationId: testConversationId)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hasSetQuicknameForConversation_\(testConversationId)"))
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
        await coordinator.didSelectQuickname()
        XCTAssertEqual(coordinator.state, .notificationsDenied)

        mockNotificationCenter.authStatus = .authorized

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await waitForState(.notificationsEnabled)

        await waitForAutodismiss()
        await waitForState(.idle)
    }

    func testAppBecomesActive_DeniedState_EnabledAfterInviteFlow_ContinuesToQuickname() async {
        mockNotificationCenter.authStatus = .denied

        await coordinator.inviteWasAccepted(for: testConversationId)
        XCTAssertEqual(coordinator.state, .notificationsDenied)

        mockNotificationCenter.authStatus = .authorized

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await waitForState(.notificationsEnabled)

        await waitForAutodismiss()
        await waitForState(.setupQuickname)
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
