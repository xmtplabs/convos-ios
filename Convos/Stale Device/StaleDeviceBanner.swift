import SwiftUI

/// Shown at the top of the main UI when `StaleDeviceObserver` detects the
/// session has landed in `.error(DeviceReplacedError)`. In the single-inbox
/// world there is only one variant — "this device has been replaced" — so
/// the partial-stale path from the vault era is gone. Offers the user a
/// single path out: `SessionManager.deleteAllInboxes()` via `onReset`.
struct StaleDeviceBanner: View {
    let onReset: () -> Void
    var onLearnMore: (() -> Void)?

    var body: some View {
        let resetAction = onReset
        let learnMoreAction = onLearnMore
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.colorLava)
                    .font(.callout)
                Text("This device has been replaced")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.colorTextPrimary)
                    .multilineTextAlignment(.center)
            }
            Text("Your account has been restored on another device. Resetting will clear local data here and restart setup.")
                .font(.system(size: 13))
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if let learnMoreAction {
                    Button(action: learnMoreAction) {
                        Text("Learn more")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }

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
        .accessibilityLabel("This device has been replaced. Reset device to clear local data and restart setup.")
        .accessibilityIdentifier("stale-device-banner")
    }
}

#Preview {
    StaleDeviceBanner(onReset: {}, onLearnMore: {})
        .padding()
}
