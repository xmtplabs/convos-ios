import ConvosCore
import Foundation
import UIKit
import UserNotifications

// MARK: - Notification Center Protocol

/// Protocol defining the notification center interface needed by ConversationOnboardingCoordinator
protocol NotificationCenterProtocol: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
}

/// Real implementation that wraps UNUserNotificationCenter
final class SystemNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus
    }
}

/// For SwiftUI previews
@MainActor
final class MockNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    var authStatus: UNAuthorizationStatus = .notDetermined
    var shouldGrantPermission: Bool = false
    var deniedStatus: UNAuthorizationStatus = .denied

    nonisolated func authorizationStatus() async -> UNAuthorizationStatus {
        await MainActor.run { authStatus }
    }
}

// MARK: - Notification Permission State

enum NotificationPermissionState {
    case request
    case enabled
    case denied
}

// MARK: - Conversation Onboarding State

/// Represents the current state of the conversation onboarding flow
enum ConversationOnboardingState: Equatable {
    /// Idle - no onboarding flow active
    case idle

    case started

    /// Show "Tap to add your name for this convo" prompt
    case setupQuickname

    case settingUpQuickname

    case quicknameLearnMore

    /// Waiting to see if the user saves a quickname
    case presentingProfileSettings

    /// Autodismissed success state after saving first Quickname
    case savedAsQuicknameSuccess

    /// Show "Tap to chat as [Name]" with the user's quickname
    case addQuickname(settings: QuicknameSettings, profileImage: UIImage?)

    /// Ask user to allow notifications (undetermined state)
    case requestNotifications

    /// Notifications enabled, showing success state
    case notificationsEnabled

    /// Notifications denied, prompt to change in settings
    case notificationsDenied

    static let addQuicknameViewDuration: CGFloat = 8.0
    static let savedAsQuicknameSuccessDuration: CGFloat = 3.0
    static let notificationsEnabledSuccessDuration: CGFloat = 3.0
    // how long we wait before showing the description string
    static let waitingForInviteAcceptanceDelay: CGFloat = 3.0

    /// Returns the autodismiss duration for this state, or nil if autodismiss is not enabled
    var autodismissDuration: CGFloat? {
        switch self {
        case .addQuickname:
            return Self.addQuicknameViewDuration
        case .savedAsQuicknameSuccess:
            return Self.savedAsQuicknameSuccessDuration
        case .notificationsEnabled:
            return Self.notificationsEnabledSuccessDuration
        default:
            return nil
        }
    }
}

/// Manages the onboarding flow state machine for a conversation
@MainActor
@Observable
final class ConversationOnboardingCoordinator {
    // MARK: - State

    var state: ConversationOnboardingState = .idle

    private var quicknameViewModel: QuicknameSettingsViewModel = .shared

    var isSettingUpQuickname: Bool {
        switch state {
        case .settingUpQuickname,
                .quicknameLearnMore,
                .presentingProfileSettings:
            return true
        default:
            return false
        }
    }

    var showOnboardingView: Bool {
        inProgress || isWaitingForInviteAcceptance
    }

    var inProgress: Bool {
        switch state {
        case .idle:
            return false
        default:
            return true
        }
    }

    var isWaitingForInviteAcceptance: Bool = false

    private var shouldShowQuicknameAfterNotifications: Bool = false
    private var pendingClientId: String?
    private var currentClientId: String?
    private var isConversationCreator: Bool = false

    // MARK: - Persistence

    private static let hasShownQuicknameEditorKey: String = "hasShownQuicknameEditor"
    private static let hasCompletedOnboardingKey: String = "hasCompletedConversationOnboarding"
    private static let hasSetQuicknamePrefix: String = "hasSetQuicknameForConversation_"
    private static let hasSeenAddAsQuicknameKey: String = "hasSeenAddAsQuickname"
    static func markQuicknameEditorShown() {
        UserDefaults.standard.set(true, forKey: hasShownQuicknameEditorKey)
    }

    static func resetUserDefaults() {
        UserDefaults.standard.removeObject(forKey: hasShownQuicknameEditorKey)
        UserDefaults.standard.removeObject(forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: hasSeenAddAsQuicknameKey)

        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(hasSetQuicknamePrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private(set) var shouldAnimateAvatarForQuicknameSetup: Bool = false

    private var hasShownQuicknameEditor: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownQuicknameEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownQuicknameEditorKey) }
    }

    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasCompletedOnboardingKey) }
    }

    private func hasSetQuickname(for clientId: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.hasSetQuicknamePrefix + clientId)
    }

    private func setHasSetQuickname(_ value: Bool, for clientId: String) {
        UserDefaults.standard.set(value, forKey: Self.hasSetQuicknamePrefix + clientId)
    }

    private var hasSeenAddAsQuickname: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasSeenAddAsQuicknameKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasSeenAddAsQuicknameKey) }
    }

    func reset() {
        state = .idle
        quicknameViewModel.delete()
        hasSeenAddAsQuickname = false
        hasCompletedOnboarding = false
        hasShownQuicknameEditor = false
    }

    // MARK: - Dependencies

    private let notificationCenter: NotificationCenterProtocol
    private let autodismissDurationOverride: CGFloat?
    @ObservationIgnored
    private var appLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var autodismissTask: Task<Void, Never>?

    init(
        notificationCenter: NotificationCenterProtocol = SystemNotificationCenter(),
        autodismissDurationOverride: CGFloat? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.autodismissDurationOverride = autodismissDurationOverride
        observeAppLifecycle()
    }

    deinit {
        appLifecycleTask?.cancel()
        autodismissTask?.cancel()
    }

    // MARK: - App Lifecycle

    private func observeAppLifecycle() {
        appLifecycleTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                await self?.handleAppDidBecomeActive()
            }
        }
    }

    // MARK: - State Observation

    /// Call this after changing state to manage autodismiss tasks
    private func handleStateChange() {
        // Cancel any existing autodismiss task (user may have manually progressed)
        autodismissTask?.cancel()

        // Start new autodismiss task if needed
        startAutodismissIfNeeded()
    }

    private func startAutodismissIfNeeded() {
        guard let stateDuration = state.autodismissDuration else {
            return
        }
        let duration = autodismissDurationOverride ?? stateDuration

        // Capture the current state to verify we're still in it after sleep
        let expectedState = state

        // Start autodismiss task
        autodismissTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .seconds(duration))

            // Check if task was cancelled (user manually progressed)
            guard !Task.isCancelled else { return }

            // Verify we're still in the expected state (state might have changed)
            guard state == expectedState else { return }

            // Transition to next state based on current state
            switch state {
            case .addQuickname:
                await addQuicknameDidAutoDismiss()
            case .savedAsQuicknameSuccess:
                await transitionAfterQuickname()
            case .notificationsEnabled:
                if shouldShowQuicknameAfterNotifications, let clientId = pendingClientId {
                    await startQuicknameFlow(for: clientId)
                    shouldShowQuicknameAfterNotifications = false
                    pendingClientId = nil
                } else {
                    await complete()
                }
            default:
                break
            }
        }
    }

    private func handleAppDidBecomeActive() async {
        let authStatus = await notificationCenter.authorizationStatus()

        switch state {
        case .idle:
            // If onboarding is idle but notifications are now disabled, restart notification flow
            if authStatus == .denied {
                state = .notificationsDenied
                handleStateChange()
            }

        case .notificationsDenied:
            // If we're in denied state and user has now enabled permissions
            switch authStatus {
            case .authorized, .provisional, .ephemeral:
                // Show success briefly
                state = .notificationsEnabled
                handleStateChange()
            default:
                break
            }

        default:
            // For other states, don't do anything on app becoming active
            break
        }
    }

    // MARK: - State Transitions

    func start(for clientId: String, isConversationCreator: Bool = false) async {
        guard case .idle = state else {
            return
        }

        self.currentClientId = clientId
        self.isConversationCreator = isConversationCreator

        state = .started

        if isWaitingForInviteAcceptance {
            await startNotificationFlow(for: clientId)
        } else {
            await startQuicknameFlow(for: clientId)
        }
    }

    /// Start the notification flow (used when coming from invite acceptance)
    private func startNotificationFlow(for clientId: String) async {
        shouldShowQuicknameAfterNotifications = true
        pendingClientId = clientId

        let authStatus = await notificationCenter.authorizationStatus()

        switch authStatus {
        case .notDetermined:
            state = .requestNotifications
            handleStateChange()
        case .denied:
            state = .notificationsDenied
            handleStateChange()
        case .authorized, .provisional, .ephemeral:
            if !isWaitingForInviteAcceptance {
                await startQuicknameFlow(for: clientId)
            }
            shouldShowQuicknameAfterNotifications = false
            pendingClientId = nil
        @unknown default:
            if !isWaitingForInviteAcceptance {
                await startQuicknameFlow(for: clientId)
            }
            shouldShowQuicknameAfterNotifications = false
            pendingClientId = nil
        }
    }

    /// Start or continue the quickname onboarding flow
    private func startQuicknameFlow(for clientId: String) async {
        // Once the user finishes onboarding, the quickname prompts stop running
        // in subsequent conversations. Notification nudges still run via the
        // shared path below, but no setupQuickname or addQuickname state is
        // surfaced per new conversation.
        guard !hasCompletedOnboarding else {
            QAEvent.emit(.onboarding, "quickname_skipped", ["reason": "already_completed"])
            await transitionAfterQuickname()
            return
        }

        let hasSetQuicknameForConversation = hasSetQuickname(for: clientId)
        setHasSetQuickname(true, for: clientId)

        let quicknameSettings = quicknameViewModel.quicknameSettings

        if !hasShownQuicknameEditor {
            shouldAnimateAvatarForQuicknameSetup = true
            state = .setupQuickname
            QAEvent.emit(.onboarding, "setup_quickname", ["reason": "first_time"])
            handleStateChange()
        } else if quicknameSettings.isDefault && !hasSetQuicknameForConversation {
            shouldAnimateAvatarForQuicknameSetup = true
            state = .setupQuickname
            QAEvent.emit(.onboarding, "setup_quickname", ["reason": "no_quickname"])
            handleStateChange()
        } else if !hasSetQuicknameForConversation {
            let profileImage = quicknameSettings.profileImage
            state = .addQuickname(settings: quicknameSettings, profileImage: profileImage)
            QAEvent.emit(.onboarding, "add_quickname", ["name": quicknameSettings.profile.displayName])
            handleStateChange()
        } else {
            QAEvent.emit(.onboarding, "quickname_skipped", ["reason": "already_set"])
            await transitionAfterQuickname()
        }
    }

    /// Call this when the invite has been accepted
    func inviteWasAccepted(for clientId: String) async {
        guard isWaitingForInviteAcceptance else {
            return
        }
        isWaitingForInviteAcceptance = false

        switch state {
        case .idle, .started:
            await startNotificationFlow(for: clientId)
        default:
            break
        }
    }

    /// User tapped to set up their quickname (opens profile editor)
    func didTapProfilePhoto() {
        guard case .setupQuickname = state else {
            skipAddQuickname()
            return
        }
        hasShownQuicknameEditor = true
        shouldAnimateAvatarForQuicknameSetup = false
        state = .settingUpQuickname
        handleStateChange()
    }

    func presentWhatIsQuickname() {
        state = .quicknameLearnMore
        handleStateChange()
    }

    func onContinueFromWhatIsQuickname() {
        state = .savedAsQuicknameSuccess
        handleStateChange()
    }

    func didSelectQuickname() async {
        QAEvent.emit(.onboarding, "quickname_applied")
        shouldAnimateAvatarForQuicknameSetup = false
        await transitionAfterQuickname()
    }

    func skipAddQuickname() {
        guard case .addQuickname = state else { return }
        QAEvent.emit(.onboarding, "quickname_dismissed", ["reason": "user"])
        Task {
            await transitionAfterQuickname()
        }
    }

    private func addQuicknameDidAutoDismiss() async {
        QAEvent.emit(.onboarding, "quickname_dismissed", ["reason": "auto"])
        await transitionAfterQuickname()
    }

    /// Handle when display name editing ends
    /// - Parameters:
    ///   - profile: The current profile
    ///   - didChangeProfile: Whether the profile was actually changed
    ///   - isSavingAsQuickname: Whether the user is saving this as their quickname
    func handleDisplayNameEndedEditing(displayName: String, profileImage: UIImage?) {
        let quicknameSettings = quicknameViewModel.quicknameSettings
        guard state == .settingUpQuickname, quicknameSettings.isDefault else { return }

        quicknameViewModel.editingDisplayName = displayName
        quicknameViewModel.profileImage = profileImage
        quicknameViewModel.save()
        QAEvent.emit(.onboarding, "quickname_saved", ["name": displayName])
        state = .quicknameLearnMore
        handleStateChange()
    }

    /// Request notification permission from the user
    func requestNotificationPermission() async -> Bool {
        let granted = await PushNotificationRegistrar.requestNotificationAuthorizationIfNeeded()

        if granted {
            state = .notificationsEnabled
            handleStateChange()

            // Check if we need to show quickname flow next (from invite acceptance)
            if shouldShowQuicknameAfterNotifications,
               !isWaitingForInviteAcceptance,
               let clientId = pendingClientId {
                await startQuicknameFlow(for: clientId)
                shouldShowQuicknameAfterNotifications = false
                pendingClientId = nil
            }
        } else {
            // Check if it was denied or just not determined
            let authStatus = await notificationCenter.authorizationStatus()
            if authStatus == .denied {
                state = .notificationsDenied
                handleStateChange()
            } else {
                // If still undetermined (shouldn't happen), stay on request state
                state = .requestNotifications
                handleStateChange()
            }
        }

        return granted
    }

    /// Open iOS Settings for the app
    func openSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl)
        }
    }

    func complete() async {
        hasCompletedOnboarding = true
        state = .idle
        handleStateChange()
    }

    func skip() async {
        await complete()
    }

    private func transitionAfterQuickname() async {
        await transitionToNotificationState()
    }

    /// Reset onboarding state (useful for testing)
    func reset(conversationId: String? = nil) {
        hasCompletedOnboarding = false
        hasShownQuicknameEditor = false
        state = .idle

        // If conversationId provided, clear that specific conversation's quickname flag
        if let conversationId = conversationId {
            setHasSetQuickname(false, for: conversationId)
        }
    }

    // MARK: - Public Helpers

    /// Get the current notification permission state
    func notificationPermissionState() async -> NotificationPermissionState {
        let authStatus = await notificationCenter.authorizationStatus()

        switch authStatus {
        case .notDetermined:
            return .request
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .enabled
        @unknown default:
            return .enabled
        }
    }

    // MARK: - Private Helpers

    private func transitionToNotificationState() async {
        let authStatus = await notificationCenter.authorizationStatus()

        switch authStatus {
        case .notDetermined:
            state = .requestNotifications
            handleStateChange()
        case .denied:
            state = .notificationsDenied
            handleStateChange()
        case .authorized, .provisional, .ephemeral:
            await complete()
        @unknown default:
            await complete()
        }
    }
}
