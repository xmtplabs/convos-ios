import ConvosCore
import SwiftUI

/// Top-of-list banner shown when at least one inbox is stale (revoked).
///
/// Two variants:
/// - **Partial stale**: some inboxes still work. Banner says "Some conversations
///   moved to another device." Action: "Reset device" (destructive verb makes the
///   intent explicit so users don't tap "Continue" expecting to keep their data).
/// - **Full stale**: every inbox revoked. Banner says "This device has been replaced."
///   Action is the same reset, but the auto-reset countdown will fire shortly.
struct StaleDeviceBanner: View {
    let state: StaleDeviceState
    let onResetDevice: () -> Void
    let onLearnMore: () -> Void

    private var title: String {
        switch state {
        case .partialStale: "Some conversations moved to another device"
        case .fullStale: "This device has been replaced"
        case .healthy: ""
        }
    }

    private var body_: String {
        switch state {
        case .partialStale: "Some inboxes have been restored on another device. Resetting will clear local data on this device and restart setup."
        case .fullStale: "Your account has been restored on another device. Resetting will clear local data on this device and restart setup."
        case .healthy: ""
        }
    }

    var body: some View {
        let resetAction = onResetDevice
        let learnMoreAction = onLearnMore
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.colorLava)
                    .font(.callout)
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.colorTextPrimary)
                    .multilineTextAlignment(.center)
            }
            Text(body_)
                .font(.system(size: 13))
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: learnMoreAction) {
                    Text("Learn more")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: resetAction) {
                    Text("Reset device")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.colorLava)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(body_). Learn more or reset device.")
        .accessibilityIdentifier("stale-device-banner")
    }
}

struct StaleDeviceInfoView: View {
    let state: StaleDeviceState
    let onResetDevice: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    private var title: String {
        switch state {
        case .partialStale: "Some conversations moved away"
        case .fullStale: "This device no longer has access"
        case .healthy: ""
        }
    }

    private var paragraphs: [FeatureInfoParagraph] {
        switch state {
        case .partialStale:
            return [
                .init("Some of your inboxes were restored on another device. That device revoked this installation, so those conversations are no longer accessible here."),
                .init("You can keep using the inboxes that are still active, or reset this device to start fresh.")
            ]
        case .fullStale:
            return [
                .init("Your account was restored on another device, which revoked this installation. You can no longer send or receive messages on this device."),
                .init("Reset to clear local data and start setup again.")
            ]
        case .healthy:
            return []
        }
    }

    var body: some View {
        let action = {
            dismiss()
            onResetDevice()
        }
        FeatureInfoSheet(
            title: title,
            paragraphs: paragraphs,
            primaryButtonTitle: "Reset device",
            primaryButtonAction: action,
            showDragIndicator: true
        )
    }
}

/// Modal countdown shown when entering full-stale state.
///
/// Auto-fires the reset after `countdownSeconds`. The user can cancel with the
/// secondary action — useful if detection is wrong (e.g. the user knows they
/// just restored on the same device and the check is racing) or if they want
/// to take a screenshot / preserve diagnostics first.
struct FullStaleAutoResetCountdown: View {
    let onReset: () -> Void
    let onCancel: () -> Void
    var countdownSeconds: Int = 5

    @State private var remaining: Int = 5

    var body: some View {
        let resetAction = onReset
        let cancelAction = onCancel
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.colorLava)
                .font(.largeTitle)

            Text("Resetting this device")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)

            Text("Your account was restored on another device. This one can no longer access your conversations.\n\nResetting in \(remaining) second\(remaining == 1 ? "" : "s")…")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: cancelAction) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: resetAction) {
                    Text("Reset now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.colorLava)
            }
        }
        .padding(24)
        .background(Color.colorBackgroundSurfaceless, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 24)
        .task {
            remaining = countdownSeconds
            for _ in 0..<countdownSeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                if remaining <= 0 {
                    onReset()
                    return
                }
            }
        }
        .accessibilityIdentifier("full-stale-countdown")
    }
}

#Preview {
    VStack(spacing: 24) {
        StaleDeviceBanner(state: .partialStale, onResetDevice: {}, onLearnMore: {})
        StaleDeviceBanner(state: .fullStale, onResetDevice: {}, onLearnMore: {})
        FullStaleAutoResetCountdown(onReset: {}, onCancel: {}, countdownSeconds: 5)
    }
    .padding()
}
