import ConvosCore
import SwiftUI

/// A view that displays the appropriate onboarding content based on the coordinator's state
struct ConversationOnboardingView: View {
    @Bindable var coordinator: ConversationOnboardingCoordinator
    let focusCoordinator: FocusCoordinator
    let onUseQuickname: (Profile, UIImage?) -> Void
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
            case .idle, .started, .settingUpQuickname, .quicknameLearnMore, .presentingProfileSettings:
                EmptyView()
            case .setupQuickname:
                SetupQuicknameView()
                    .transition(.blurReplace)

            case .saveAsQuickname(let profile):
                UseAsQuicknameView(
                    profile: .constant(profile),
                    onLearnMore: {
                        // keep the keyboard dismissed
                        focusCoordinator.moveFocus(to: nil)
                        coordinator.presentWhatIsQuickname()
                    }
                )
                .transition(.blurReplace)

            case .savedAsQuicknameSuccess:
                SetupQuicknameSuccessView()
                    .transition(.blurReplace)

            case let .addQuickname(settings, profileImage):
                AddQuicknameView(
                    profile: .constant(settings.profile),
                    profileImage: .constant(profileImage),
                    onUseProfile: { profile, image in
                        onUseQuickname(profile, image)
                        Task {
                            await coordinator.didSelectQuickname()
                        }
                    }
                )
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
        .selfSizingSheet(isPresented: Binding(get: {
            coordinator.state == .quicknameLearnMore
        }, set: { _ in
        })) {
            WhatIsQuicknameView {
                coordinator.onContinueFromWhatIsQuickname()
            }
            .interactiveDismissDisabled()
            .background(.colorBackgroundPrimary)
        }
    }
}

#Preview("Onboarding Flow") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator(notificationCenter: MockNotificationCenter())
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    let onboardingSteps: [ConversationOnboardingState] = [
        .idle,
        .setupQuickname,
        .settingUpQuickname,
        .saveAsQuickname(profile: .mock()),
        .savedAsQuicknameSuccess,
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
            onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
            onPresentProfileSettings: {}
        )
        .onAppear {
            coordinator.state = .setupQuickname
        }
        .padding()
    }
}

#Preview("Setup Quickname - Not Dismissible") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .setupQuickname
    }
    .padding()
}

#Preview("Setup Quickname - Auto Dismiss") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .setupQuickname
    }
    .padding()
}

#Preview("Add Quickname") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .addQuickname(
            settings: QuicknameSettings.current(),
            profileImage: nil
        )
    }
    .padding()
}

#Preview("Save As Quickname") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    let sampleProfile = Profile(inboxId: "preview-inbox", name: "Jane Doe", avatar: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.state = .saveAsQuickname(profile: sampleProfile)
    }
    .padding()
}

#Preview("Request Notifications") {
    @Previewable @State var coordinator = ConversationOnboardingCoordinator()
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    ConversationOnboardingView(
        coordinator: coordinator,
        focusCoordinator: focusCoordinator,
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
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
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
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
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
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
        onUseQuickname: { profile, _ in print("Use quickname: \(profile.displayName)") },
        onPresentProfileSettings: {}
    )
    .onAppear {
        coordinator.isWaitingForInviteAcceptance = true
        coordinator.state = .requestNotifications
    }
    .padding()
}
