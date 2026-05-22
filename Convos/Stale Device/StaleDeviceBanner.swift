import SwiftUI

/// Shown at the top of `ConversationsView` when `StaleDeviceObserver`
/// detects the session has landed in `.error(DeviceReplacedError)` —
/// another paired device revoked this one. The only path out is a full
/// local data reset (Convos has no read-only mode); the hold-to-confirm
/// button calls through to `SessionManager.deleteAllInboxes()` and lets
/// normal onboarding kick in afresh. We use the same hold-to-confirm
/// primitive as `DeleteAllDataView` so the action looks consistent with
/// the other destructive surface in the app.
struct StaleDeviceBanner: View {
    let onReset: () -> Void
    var isResetting: Bool = false

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.colorCaution)
                    .font(.callout)
                Text("This device has been removed")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.colorTextPrimary)
                    .multilineTextAlignment(.center)
            }
            Text("Another device removed this one from your account. Resetting will clear local data here so you can start fresh or pair again.")
                .font(.system(size: 13))
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HoldToResetButton(isResetting: isResetting, onReset: onReset)
                .padding(.top, DesignConstants.Spacing.step2x)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignConstants.Spacing.step4x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                .fill(.colorBackgroundRaisedSecondary)
        )
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This device has been removed. Hold to reset to clear local data and start fresh.")
        .accessibilityIdentifier("stale-device-banner")
    }
}

private struct HoldToResetButton: View {
    let isResetting: Bool
    let onReset: () -> Void

    private var buttonConfig: HoldToConfirmStyleConfig {
        var config = HoldToConfirmStyleConfig.default
        config.duration = 3.0
        config.backgroundColor = .colorCaution
        return config
    }

    var body: some View {
        Button {
            onReset()
        } label: {
            ZStack {
                Text("Hold to reset")
                    .opacity(isResetting ? 0 : 1)
                Text("Resetting...")
                    .opacity(isResetting ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: isResetting)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .disabled(isResetting)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: buttonConfig))
        .accessibilityLabel(isResetting ? "Resetting device" : "Hold to reset device")
        .accessibilityHint(isResetting ? "" : "Hold to confirm")
        .accessibilityIdentifier("hold-to-reset-device-button")
    }
}

#Preview {
    StaleDeviceBanner(onReset: {})
        .padding()
}
