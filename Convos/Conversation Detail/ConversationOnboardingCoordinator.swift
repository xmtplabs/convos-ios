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
    case setupProfile

    case settingUpProfile

    /// Waiting to see if the user saves a profile
    case presentingProfileSettings

    /// Autodismissed success state after saving first Profile
    case savedProfileSuccess

    /// Ask user to allow notifications (undetermined state)
    case requestNotifications

    /// Notifications enabled, showing success state
    case notificationsEnabled

    /// Notifications denied, prompt to change in settings
    case notificationsDenied

    static let savedProfileSuccessDuration: CGFloat = 3.0
    static let notificationsEnabledSuccessDuration: CGFloat = 3.0
    // how long we wait before showing the description string
    static let waitingForInviteAcceptanceDelay: CGFloat = 3.0

    /// Returns the autodismiss duration for this state, or nil if autodismiss is not enabled
    var autodismissDuration: CGFloat? {
        switch self {
        case .savedProfileSuccess:
            return Self.savedProfileSuccessDuration
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

    private var profileSettingsViewModel: ProfileSettingsViewModel = .shared

    var isSettingUpProfile: Bool {
        switch state {
        case .settingUpProfile,
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

    private var shouldShowProfileSetupAfterNotifications: Bool = false
    private var pendingConversationId: String?
    private var currentConversationId: String?
    private var isConversationCreator: Bool = false

    // MARK: - Persistence

    private static let hasShownProfileEditorKey: String = "hasShownProfileEditor"
    private static let hasCompletedOnboardingKey: String = "hasCompletedConversationOnboarding"
    private static let hasSetProfilePrefix: String = "hasSetProfileForConversation_"
    private static let hasSeenAddAsProfileKey: String = "hasSeenAddAsProfile"
    static func markProfileEditorShown() {
        UserDefaults.standard.set(true, forKey: hasShownProfileEditorKey)
    }

    static func resetUserDefaults() {
        UserDefaults.standard.removeObject(forKey: hasShownProfileEditorKey)
        UserDefaults.standard.removeObject(forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: hasSeenAddAsProfileKey)

        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(hasSetProfilePrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private(set) var shouldAnimateAvatarForProfileSetup: Bool = false

    private var hasShownProfileEditor: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownProfileEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownProfileEditorKey) }
    }

    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasCompletedOnboardingKey) }
    }

    private func hasSetProfile(for conversationId: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.hasSetProfilePrefix + conversationId)
    }

    private func setHasSetProfile(_ value: Bool, for conversationId: String) {
        UserDefaults.standard.set(value, forKey: Self.hasSetProfilePrefix + conversationId)
    }

    private var hasSeenAddAsProfile: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasSeenAddAsProfileKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasSeenAddAsProfileKey) }
    }

    func reset() {
        state = .idle
        profileSettingsViewModel.delete()
        hasSeenAddAsProfile = false
        hasCompletedOnboarding = false
        hasShownProfileEditor = false
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
            case .savedProfileSuccess:
                await transitionAfterProfileSetup()
            case .notificationsEnabled:
                if shouldShowProfileSetupAfterNotifications, let conversationId = pendingConversationId {
                    await startProfileSetupFlow(for: conversationId)
                    shouldShowProfileSetupAfterNotifications = false
                    pendingConversationId = nil
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

    func start(for conversationId: String, isConversationCreator: Bool = false) async {
        guard case .idle = state else {
            return
        }

        self.currentConversationId = conversationId
        self.isConversationCreator = isConversationCreator

        state = .started

        if isWaitingForInviteAcceptance {
            await startNotificationFlow(for: conversationId)
        } else {
            await startProfileSetupFlow(for: conversationId)
        }
    }

    /// Start the notification flow (used when coming from invite acceptance)
    private func startNotificationFlow(for conversationId: String) async {
        shouldShowProfileSetupAfterNotifications = true
        pendingConversationId = conversationId

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
                await startProfileSetupFlow(for: conversationId)
            }
            shouldShowProfileSetupAfterNotifications = false
            pendingConversationId = nil
        @unknown default:
            if !isWaitingForInviteAcceptance {
                await startProfileSetupFlow(for: conversationId)
            }
            shouldShowProfileSetupAfterNotifications = false
            pendingConversationId = nil
        }
    }

    /// Start or continue the profile onboarding flow
    private func startProfileSetupFlow(for conversationId: String) async {
        let hasSetProfileForConversation = hasSetProfile(for: conversationId)

        let profileSettings = profileSettingsViewModel.profileSettings

        if !hasShownProfileEditor {
            shouldAnimateAvatarForProfileSetup = true
            state = .setupProfile
            QAEvent.emit(.onboarding, "setup_profile", ["reason": "first_time"])
            handleStateChange()
        } else if profileSettings.isDefault && !hasSetProfileForConversation {
            shouldAnimateAvatarForProfileSetup = true
            state = .setupProfile
            QAEvent.emit(.onboarding, "setup_profile", ["reason": "no_profile"])
            handleStateChange()
        } else {
            if !hasSetProfileForConversation {
                setHasSetProfile(true, for: conversationId)
                QAEvent.emit(.onboarding, "profile_auto_applied", ["name": profileSettings.profile.displayName])
            } else {
                QAEvent.emit(.onboarding, "profile_skipped", ["reason": "already_set"])
            }
            await transitionAfterProfileSetup()
        }
    }

    /// Call this when the invite has been accepted
    func inviteWasAccepted(for conversationId: String) async {
        guard isWaitingForInviteAcceptance else {
            return
        }
        isWaitingForInviteAcceptance = false

        switch state {
        case .idle, .started:
            await startNotificationFlow(for: conversationId)
        default:
            break
        }
    }

    /// User tapped to set up their profile (opens profile editor)
    func didTapProfilePhoto() {
        guard case .setupProfile = state else { return }
        hasShownProfileEditor = true
        shouldAnimateAvatarForProfileSetup = false
        state = .settingUpProfile
        handleStateChange()
    }

    func didSelectProfile() async {
        QAEvent.emit(.onboarding, "profile_applied")
        shouldAnimateAvatarForProfileSetup = false
        if let conversationId = currentConversationId {
            setHasSetProfile(true, for: conversationId)
        }
        await transitionAfterProfileSetup()
    }

    /// Handle when display name editing ends
    /// - Parameters:
    ///   - profile: The current profile
    ///   - didChangeProfile: Whether the profile was actually changed
    ///   - isSavingAsProfile: Whether the user is saving this as their profile
    func handleDisplayNameEndedEditing(displayName: String, profileImage: UIImage?) {
        let profileSettings = profileSettingsViewModel.profileSettings
        guard state == .settingUpProfile, profileSettings.isDefault else { return }

        profileSettingsViewModel.editingDisplayName = displayName
        profileSettingsViewModel.profileImage = profileImage
        profileSettingsViewModel.save()
        QAEvent.emit(.onboarding, "profile_saved", ["name": displayName])
        state = .savedProfileSuccess
        handleStateChange()
    }

    /// Request notification permission from the user
    func requestNotificationPermission() async -> Bool {
        let granted = await PushNotificationRegistrar.requestNotificationAuthorizationIfNeeded()

        if granted {
            state = .notificationsEnabled
            handleStateChange()

            // Check if we need to show profile flow next (from invite acceptance)
            if shouldShowProfileSetupAfterNotifications,
               !isWaitingForInviteAcceptance,
               let conversationId = pendingConversationId {
                await startProfileSetupFlow(for: conversationId)
                shouldShowProfileSetupAfterNotifications = false
                pendingConversationId = nil
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

    private func transitionAfterProfileSetup() async {
        await transitionToNotificationState()
    }

    /// Reset onboarding state (useful for testing)
    func reset(conversationId: String? = nil) {
        hasCompletedOnboarding = false
        hasShownProfileEditor = false
        state = .idle

        // If conversationId provided, clear that specific conversation's profile flag
        if let conversationId = conversationId {
            setHasSetProfile(false, for: conversationId)
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
