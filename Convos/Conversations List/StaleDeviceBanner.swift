import ConvosCore
import SwiftUI

/// Top-of-list banner shown when `SessionStateMachine` surfaces a
/// `DeviceReplacedError` — i.e., the sole XMTP installation for
/// this inbox has been revoked, almost always because the user
/// restored on another device.
///
/// Single variant: Rev 4 collapsed the old `partialStale` /
/// `fullStale` distinction into a binary. "Reset device" is the
/// only path out; `Learn more` links to the convos learn site.
struct StaleDeviceBanner: View {
    let onResetDevice: () -> Void
    let onLearnMore: () -> Void

    var body: some View {
        let resetAction = onResetDevice
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
            Text("Your account has been restored on another device. Resetting will clear local data on this device and restart setup.")
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
        .accessibilityLabel(
            "This device has been replaced. Your account has been restored on another device. Resetting will clear local data on this device and restart setup. Learn more or reset device."
        )
        .accessibilityIdentifier("stale-device-banner")
    }
}

#Preview {
    StaleDeviceBanner(
        onResetDevice: {},
        onLearnMore: {}
    )
    .padding()
}
