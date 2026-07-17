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

/// Represents the current state of the conversation onboarding flow.
/// Profile setup is owned by the launch Nametag sheet
/// (`ProfileSetupSheet`); this flow only auto-applies an existing global
/// profile to the conversation and runs the notifications step.
enum ConversationOnboardingState: Equatable {
    /// Idle - no onboarding flow active
    case idle

    case started

    /// One-time paywall step shown after the first profile setup.
    /// User must subscribe or claim the 7-day trial to proceed.
    case presentingPaywall

    /// Ask user to allow notifications (undetermined state)
    case requestNotifications

    /// Notifications enabled, showing success state
    case notificationsEnabled

    /// Notifications denied, prompt to change in settings
    case notificationsDenied

    static let notificationsEnabledSuccessDuration: CGFloat = 3.0
    // how long we wait before showing the description string
    static let waitingForInviteAcceptanceDelay: CGFloat = 3.0

    /// Returns the autodismiss duration for this state, or nil if autodismiss is not enabled
    var autodismissDuration: CGFloat? {
        switch self {
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

    private let profileSettingsViewModel: ProfileSettingsViewModel

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
    /// Prior name of `hasSetProfilePrefix` from the Quickname era. Read-only fallback
    /// during the user's first launch on the renamed flow so users who already completed
    /// setup before the rename don't get a redundant profile prompt.
    private static let legacyHasSetQuicknamePrefix: String = "hasSetQuicknameForConversation_"
    private static let hasSeenAddAsProfileKey: String = "hasSeenAddAsProfile"
    private static let hasShownNUXPaywallKey: String = "hasShownNUXPaywall"
    /// Legacy shown-once latch for the launch profile sheet. The sheet now
    /// gates purely on the global profile being unset (see
    /// `ConversationsViewModel.presentFirstLaunchProfileSetupIfNeeded`);
    /// the key is only kept so resets clear installs that wrote it.
    private static let hasShownFirstLaunchProfileSheetKey: String = "hasShownFirstLaunchProfileSheet"

    static func markProfileEditorShown() {
        UserDefaults.standard.set(true, forKey: hasShownProfileEditorKey)
    }

    /// Marks the global onboarding flags as completed so the in-conversation
    /// "set up your name / pic" prompts are skipped. Used by the pairing
    /// flow on the joiner side — the joiner just adopted the initiator's
    /// fully-onboarded identity, so they shouldn't be asked to set up a
    /// profile again. Per-conversation flags (the `hasSetProfilePrefix`
    /// keys) are intentionally left alone — those track whether the user
    /// has chosen *what* profile to expose in a specific conversation,
    /// which is a separate decision from "have I ever set a profile."
    static func markCompletedForPairedDevice() {
        UserDefaults.standard.set(true, forKey: hasShownProfileEditorKey)
        UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(true, forKey: hasSeenAddAsProfileKey)
    }

    static func resetUserDefaults() {
        UserDefaults.standard.removeObject(forKey: hasShownProfileEditorKey)
        UserDefaults.standard.removeObject(forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.removeObject(forKey: hasSeenAddAsProfileKey)
        UserDefaults.standard.removeObject(forKey: hasShownNUXPaywallKey)
        UserDefaults.standard.removeObject(forKey: hasShownFirstLaunchProfileSheetKey)

        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(hasSetProfilePrefix) || key.hasPrefix(legacyHasSetQuicknamePrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private var hasShownProfileEditor: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownProfileEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownProfileEditorKey) }
    }

    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasCompletedOnboardingKey) }
    }

    private var hasShownNUXPaywall: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasShownNUXPaywallKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasShownNUXPaywallKey) }
    }

    private var shouldShowNUXPaywall: Bool {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
        return !hasShownNUXPaywall
    }

    private func hasSetProfile(for conversationId: String) -> Bool {
        let defaults = UserDefaults.standard
        let key = Self.hasSetProfilePrefix + conversationId
        if defaults.bool(forKey: key) { return true }
        // Lazy migration: if the user completed setup under the legacy Quickname key,
        // promote it to the new key on first read so subsequent calls hit the fast path
        // and a single-key reset (e.g. account deletion) clears it cleanly.
        let legacyKey = Self.legacyHasSetQuicknamePrefix + conversationId
        if defaults.bool(forKey: legacyKey) {
            defaults.set(true, forKey: key)
            defaults.removeObject(forKey: legacyKey)
            return true
        }
        return false
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
        hasShownNUXPaywall = false
    }

    // MARK: - Dependencies

    private let notificationCenter: NotificationCenterProtocol
    private let autodismissDurationOverride: CGFloat?
    /// How long `startProfileSetupFlow` waits for the global profile to load
    /// before giving up. On timeout the coordinator goes quiet rather than
    /// guess: prompting an already-onboarded user is worse than prompting a
    /// new user one conversation-open late.
    private let profileLoadTimeout: TimeInterval
    @ObservationIgnored
    private var appLifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var autodismissTask: Task<Void, Never>?

    init(
        notificationCenter: NotificationCenterProtocol = SystemNotificationCenter(),
        autodismissDurationOverride: CGFloat? = nil,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        profileLoadTimeout: TimeInterval = 10
    ) {
        self.notificationCenter = notificationCenter
        self.autodismissDurationOverride = autodismissDurationOverride
        self.profileSettingsViewModel = profileSettingsViewModel
        self.profileLoadTimeout = profileLoadTimeout
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

    /// Apply the global profile to this conversation (when one exists) and
    /// continue to the notifications step. Profile setup itself is owned by
    /// the launch Nametag sheet — this flow never prompts.
    private func startProfileSetupFlow(for conversationId: String) async {
        // Don't decide on an unloaded snapshot: at cold launch (and right
        // after pairing adoption) the shared profile view model still holds
        // default values even for a fully-onboarded user, because the global
        // profile only arrives once the inbox is ready. `.started` renders
        // nothing, so waiting here shows no UI either way.
        let profileLoaded = await profileSettingsViewModel.waitForProfileLoad(timeout: profileLoadTimeout)
        guard profileLoaded else {
            QAEvent.emit(.onboarding, "profile_load_timeout")
            state = .idle
            handleStateChange()
            return
        }

        let hasSetProfileForConversation = hasSetProfile(for: conversationId)

        let profileSettings = profileSettingsViewModel.profileSettings

        if !profileSettings.isDefault {
            // A profile already exists — regardless of the device-local
            // editor flag, which can lag the profile (e.g. it is set
            // asynchronously on a freshly paired device). Backfill it so
            // related gates (like the input bar's "Chat as Somebody") agree.
            hasShownProfileEditor = true
            if !hasSetProfileForConversation {
                setHasSetProfile(true, for: conversationId)
                QAEvent.emit(.onboarding, "profile_auto_applied", ["name": profileSettings.profile.displayName])
            } else {
                QAEvent.emit(.onboarding, "profile_skipped", ["reason": "already_set"])
            }
        } else {
            // No profile set: the launch Nametag sheet re-offers until one
            // exists, so the conversation flow proceeds without prompting.
            QAEvent.emit(.onboarding, "profile_skipped", ["reason": "unset_owned_by_nametag"])
        }
        await transitionAfterProfileSetup()
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

    /// Called by the NUX paywall view after the user either subscribes or
    /// claims the 7-day trial. Idempotent — extra calls after the state
    /// already moved on are no-ops.
    func userDidCompleteNUXPaywall() async {
        guard case .presentingPaywall = state else { return }
        hasShownNUXPaywall = true
        await transitionToNotificationState()
    }

    /// Reset onboarding state (useful for testing)
    func reset(conversationId: String? = nil) {
        hasCompletedOnboarding = false
        hasShownProfileEditor = false
        hasShownNUXPaywall = false
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
