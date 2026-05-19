import ConvosCore
import SwiftUI

/// A view that displays the appropriate onboarding content based on the coordinator's state
struct ConversationOnboardingView: View {
    @Bindable var coordinator: ConversationOnboardingCoordinator
    let focusCoordinator: FocusCoordinator
    let scrollOverscrollAmount: CGFloat
    let onTapSetupProfile: () -> Void
    let onUseProfile: (Profile, UIImage?) -> Void
    let onPresentProfileSettings: () -> Void

    private var permissionState: NotificationPermissionState? {
        switch coordinator.state {
        case .requestNotifications:
                .request
        case .notificationsDenied:
                .denied
        case .notificationsEnabled:
                .enabled
        default:
            nil
        }
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            // Show "Invite accepted" message if waiting for invite
            if coordinator.isWaitingForInviteAcceptance {
                InviteAcceptedView()
            }

            // Show the current onboarding state
            switch coordinator.state {
            case .idle, .started, .settingUpProfile, .presentingProfileSettings, .presentingPaywall:
                EmptyView()

            case .setupProfile:
                SetupProfileView {
                    onTapSetupProfile()
                }
                .transition(.blurReplace)

            case .savedProfileSuccess:
                SetupProfileSuccessView()
                    .transition(.blurReplace)

            case .requestNotifications,
                    .notificationsEnabled,
                    .notificationsDenied:
                if let permissionState {
                    RequestPushNotificationsView(
                        isWaitingForInviteAcceptance: coordinator.isWaitingForInviteAcceptance,
                        permissionState: permissionState,
                        enableNotifications: {
                            Task {
                                await coordinator.requestNotificationPermission()
                            }
                        },
                        openSettings: {
                            coordinator.openSettings()
                        }
                    )
                    .transition(.blurReplace)
                    .padding(.vertical, DesignConstants.Spacing.step4x)
                } else {
                    EmptyView()
                }
            }
        }
        .transition(.blurReplace)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: coordinator.state)
        .sheet(isPresented: nuxPaywallPresented) {
            nuxPaywallSheetContent
        }
    }

    private var nuxPaywallPresented: Binding<Bool> {
        Binding(
            get: { coordinator.state == .presentingPaywall },
            set: { newValue in
                // External dismissal (close X or swipe-down): advance the
                // coordinator so the NUX sheet doesn't re-present on the next
                // conversation. No trial granted on this path — the user has
                // to tap the explicit Skip-to-trial button to claim it.
                if !newValue, coordinator.state == .presentingPaywall {
                    Task { await coordinator.userDidCompleteNUXPaywall() }
                }
            }
        )
    }

    @ViewBuilder
    private var nuxPaywallSheetContent: some View {
        let paywallViewModel = PaywallViewModel(subscriptionService: SubscriptionServices.shared)
        let onPurchaseSucceeded: () -> Void = {
            Task { await coordinator.userDidCompleteNUXPaywall() }
        }
        let nuxSkipAction = {
            // Mock trial grant. When the backend `POST /v2/credits/me/redeem-trial`
            // route lands, replace this with the real HTTP call.
            MockCreditsService.shared.setPreset(.trialActive)
            MockSubscriptionService.shared.setPreset(.trialActive)
            Task { await coordinator.userDidCompleteNUXPaywall() }
        }
        PaywallView(
            viewModel: paywallViewModel,
            onSkip: nuxSkipAction,
            onPurchaseSucceeded: onPurchaseSucceeded
        )
    }
}

#Preview("Onboarding Flow") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator(notificationCenter: MockNotificationCenter())
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    let onboardingSteps: [ConversationOnboardingState] = [
        .idle,
        .setupProfile,
        .settingUpProfile,
        .savedProfileSuccess,
        .requestNotifications,
        .notificationsEnabled
    ]

    VStack {
        Spacer()
        HStack {
            Button {
                // back
                if var currentIndex = onboardingSteps.firstIndex(of: coordinator.state) {
                    onboardingSteps.formIndex(before: &currentIndex)
                    coordinator.state = onboardingSteps[currentIndex]
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.glassProminent)

            Button {
                // next
                if var currentIndex = onboardingSteps.firstIndex(of: coordinator.state) {
                    onboardingSteps.formIndex(after: &currentIndex)
                    coordinator.state = onboardingSteps[currentIndex]
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.glassProminent)
        }

        Spacer()

        ConversationOnboardingView(
            coordinator: coordinator,
            focusCoordinator: focusCoordinator,
            scrollOverscrollAmount: 0,
            onTapSetupProfile: {},
            onUseProfile: { _, _ in },
            onPresentProfileSettings: {}
        )
        .onAppear {
            coordinator.state = .setupProfile
        }
        .padding()
    }
}

#Preview("Setup Profile - Not Dismissible") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        scrollOverscrollAmount: 0,
        onTapSetupProfile: {},
        onUseProfile: { _, _ in },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .setupProfile
    }
    .padding()
}

#Preview("Setup Profile - Auto Dismiss") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        scrollOverscrollAmount: 0,
        onTapSetupProfile: {},
        onUseProfile: { _, _ in },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .setupProfile
    }
    .padding()
}

#Preview("Request Notifications") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        scrollOverscrollAmount: 0,
        onTapSetupProfile: {},
        onUseProfile: { _, _ in },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .requestNotifications
    }
    .padding()
}

#Preview("Notifications Enabled") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        scrollOverscrollAmount: 0,
        onTapSetupProfile: {},
        onUseProfile: { _, _ in },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .notificationsEnabled
    }
    .padding()
}

#Preview("Notifications Denied") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        scrollOverscrollAmount: 0,
        onTapSetupProfile: {},
        onUseProfile: { _, _ in },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .notificationsDenied
    }
    .padding()
}

#Preview("Waiting For Invite + Request Notifications") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        scrollOverscrollAmount: 0,
        onTapSetupProfile: {},
        onUseProfile: { _, _ in },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.isWaitingForInviteAcceptance = true
        coordinator.state = .requestNotifications
    }
    .padding()
}
