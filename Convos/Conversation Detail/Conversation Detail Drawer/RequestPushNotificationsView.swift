import SwiftUI

struct RequestPushNotificationsView: View {
    let isWaitingForInviteAcceptance: Bool
    let permissionState: NotificationPermissionState
    let enableNotifications: () -> Void
    let openSettings: () -> Void

    @State private var showingButton: Bool = false

    var label: some View {
        Group {
            switch permissionState {
            case .request:
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Image(systemName: "app.badge.fill")
                        .foregroundStyle(.colorLava)
                    if isWaitingForInviteAcceptance {
                        Text("Notify me when I'm approved")
                            .foregroundStyle(.colorTextPrimaryInverted)
                    } else {
                        Text("Notify me of new messages")
                            .foregroundStyle(.colorTextPrimaryInverted)
                    }
                }
            case .enabled:
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Image(systemName: "app.badge.checkmark.fill")
                        .foregroundStyle(.colorLava)
                    Text("Notifications enabled")
                        .foregroundStyle(.colorTextPrimary)
                }
            case .denied:
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Image(systemName: "app.badge.fill")
                        .foregroundStyle(.colorOrange)
                    if isWaitingForInviteAcceptance {
                        Text("Notify me when I'm approved")
                            .foregroundStyle(.colorTextPrimaryInverted)
                    } else {
                        Text("Notify me of new messages")
                            .foregroundStyle(.colorTextPrimaryInverted)
                    }
                }
            }
        }
    }

    var buttonBackgroundColor: Color {
        switch permissionState {
        case .request:
                .colorBackgroundInverted
        case .enabled:
                .colorFillMinimal
        case .denied:
                .colorBackgroundInverted
        }
    }

    var body: some View {
        Button {
            switch permissionState {
            case .request:
                enableNotifications()
            case .enabled:
                // No action needed - coordinator will handle state transition
                break
            case .denied:
                openSettings()
            }
        } label: {
            label
        }
        .convosButtonStyle(
            .rounded(
                fullWidth: true,
                backgroundColor: buttonBackgroundColor
            )
        )
        .accessibilityIdentifier("notification-permission-button")
        .transition(.blurReplace)
    }
}

#Preview {
    VStack(spacing: 20) {
        Text("Request State")
            .font(.caption)
        RequestPushNotificationsView(
            isWaitingForInviteAcceptance: false,
            permissionState: .request,
            enableNotifications: {},
            openSettings: {}
        )

        Text("Enabled State")
            .font(.caption)
        RequestPushNotificationsView(
            isWaitingForInviteAcceptance: false,
            permissionState: .enabled,
            enableNotifications: {},
            openSettings: {}
        )

        Text("Denied State")
            .font(.caption)
        RequestPushNotificationsView(
            isWaitingForInviteAcceptance: false,
            permissionState: .denied,
            enableNotifications: {},
            openSettings: {}
        )
    }
    .padding()
}
