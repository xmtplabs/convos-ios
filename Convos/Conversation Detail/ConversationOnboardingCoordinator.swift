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

    /// Track if we're waiting for invite acceptance (can be true alongside other states)
    var isWaitingForInviteAcceptance: Bool = false

    /// Track if we need to show quickname flow after notifications (for invite acceptance flow)
    private var shouldShowQuicknameAfterNotifications: Bool = false
    private var pendingClientId: String?

    // MARK: - Persistence

    private let hasShownQuicknameEditorKey: String = "hasShownQuicknameEditor"
    private let hasCompletedOnboardingKey: String = "hasCompletedConversationOnboarding"
    private let hasSetQuicknamePrefix: String = "hasSetQuicknameForConversation_"
    private let hasSeenAddAsQuicknameKey: String = "hasSeenAddAsQuickname"

    private(set) var shouldAnimateAvatarForQuicknameSetup: Bool = false

    private var hasShownQuicknameEditor: Bool {
        get { UserDefaults.standard.bool(forKey: hasShownQuicknameEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasShownQuicknameEditorKey) }
    }

    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey) }
    }

    private func hasSetQuickname(for clientId: String) -> Bool {
        UserDefaults.standard.bool(forKey: hasSetQuicknamePrefix + clientId)
    }

    private func setHasSetQuickname(_ value: Bool, for clientId: String) {
        UserDefaults.standard.set(value, forKey: hasSetQuicknamePrefix + clientId)
    }

    private var hasSeenAddAsQuickname: Bool {
        get { UserDefaults.standard.bool(forKey: hasSeenAddAsQuicknameKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasSeenAddAsQuicknameKey)}
    }

    // Only used in Debug builds
    func reset() {
        hasSeenAddAsQuickname = false
        hasCompletedOnboarding = false
        hasShownQuicknameEditor = false
    }

    // MARK: - Dependencies

    private let notificationCenter: NotificationCenterProtocol
    @ObservationIgnored
    private var appLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var autodismissTask: Task<Void, Never>?

    init(notificationCenter: NotificationCenterProtocol = SystemNotificationCenter()) {
        self.notificationCenter = notificationCenter
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
        // Get autodismiss duration from state
        guard let duration = state.autodismissDuration else {
            return
        }

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
            case .setupQuickname:
                await setupQuicknameDidAutoDismiss()
            case .addQuickname:
                await addQuicknameDidAutoDismiss()
            case .savedAsQuicknameSuccess:
                await transitionToNotificationState()
            case .notificationsEnabled:
                // Check if we need to continue to quickname flow
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

    /// Initialize the onboarding flow based on current conditions
    func start(for clientId: String) async {
        // Only start if we're in idle state
        guard case .idle = state else {
            return
        }

        // prevent starting again before we know the next state
        state = .started

        if isWaitingForInviteAcceptance {
            // Notifications first, then quickname
            await startNotificationFlow(for: clientId)
        } else {
            // Quickname first, then notifications
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
            // Already granted, skip to quickname
            if !isWaitingForInviteAcceptance {
                await startQuicknameFlow(for: clientId)
            }
            shouldShowQuicknameAfterNotifications = false
            pendingClientId = nil
        @unknown default:
            // Unknown, skip to quickname
            if !isWaitingForInviteAcceptance {
                await startQuicknameFlow(for: clientId)
            }
            shouldShowQuicknameAfterNotifications = false
            pendingClientId = nil
        }
    }

    /// Start or continue the quickname onboarding flow
    private func startQuicknameFlow(for clientId: String) async {
        // Check if we've ever set a quickname for this specific clientId
        let hasSetQuicknameForConversation = hasSetQuickname(for: clientId)
        setHasSetQuickname(true, for: clientId)

        // Determine which quickname state to show
        let quicknameSettings = quicknameViewModel.quicknameSettings

        if !hasShownQuicknameEditor {
            // First time: show non-dismissible setup prompt
            shouldAnimateAvatarForQuicknameSetup = true
            state = .setupQuickname
            handleStateChange()
        } else if quicknameSettings.isDefault && !hasSetQuicknameForConversation {
            // Has seen editor but no quickname: show auto-dismissing setup
            shouldAnimateAvatarForQuicknameSetup = true
            state = .setupQuickname
            handleStateChange()
        } else if !hasSetQuicknameForConversation {
            // Has quickname: show auto-dismissing add name
            let profileImage = quicknameSettings.profileImage
            state = .addQuickname(settings: quicknameSettings, profileImage: profileImage)
            handleStateChange()
        } else {
            // Already set quickname for this conversation, go to notifications
            await transitionToNotificationState()
        }
    }

    /// Call this when the invite has been accepted
    func inviteWasAccepted(for clientId: String) async {
        // No longer waiting for invite
        isWaitingForInviteAcceptance = false

        // If we're not in an active flow, start notification flow
        switch state {
        case .idle, .started:
            // Start notification flow, then quickname
            await startNotificationFlow(for: clientId)
        default:
            break
        }
    }

    /// User tapped to set up their quickname (opens profile editor)
    func didTapProfilePhoto() {
        guard case .setupQuickname = state else {
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

    /// The setup quickname view auto-dismissed
    func setupQuicknameDidAutoDismiss() async {
        hasShownQuicknameEditor = true
        shouldAnimateAvatarForQuicknameSetup = false
        await transitionToNotificationState()
    }

    /// User selected a quickname to use
    func didSelectQuickname() async {
        shouldAnimateAvatarForQuicknameSetup = false
        await transitionToNotificationState()
    }

    func skipAddQuickname() async {
        guard case .addQuickname = state else { return }
        await transitionToNotificationState()
    }

    private func addQuicknameDidAutoDismiss() async {
        await transitionToNotificationState()
    }

    /// Handle when display name editing ends
    /// - Parameters:
    ///   - profile: The current profile
    ///   - didChangeProfile: Whether the profile was actually changed
    ///   - isSavingAsQuickname: Whether the user is saving this as their quickname
    func handleDisplayNameEndedEditing(displayName: String, profileImage: UIImage?) {
        let quicknameSettings = quicknameViewModel.quicknameSettings
        guard state == .settingUpQuickname, quicknameSettings.isDefault else { return }

        // save the first name/photo the user sets as the quickname
        quicknameViewModel.editingDisplayName = displayName
        quicknameViewModel.profileImage = profileImage
        quicknameViewModel.save()
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

    /// Complete the onboarding flow
    func complete() async {
        hasCompletedOnboarding = true
        state = .idle
        handleStateChange()
    }

    /// Skip remaining onboarding steps
    func skip() async {
        await complete()
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
            // Already granted, complete onboarding
            await complete()
        @unknown default:
            // Unknown state, treat as completed
            await complete()
        }
    }
}
