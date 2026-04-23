import SwiftUI

/// Shown at the top of the main UI when `StaleDeviceObserver` detects the
/// session has landed in `.error(DeviceReplacedError)`. Offers the user a
/// single path out — `SessionManager.deleteAllInboxes()` via the
/// `onReset` callback.
struct StaleDeviceBanner: View {
    let onReset: () -> Void

    var body: some View {
        let action = onReset
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.title3)
                .foregroundStyle(.colorLava)
            VStack(alignment: .leading, spacing: 4) {
                Text("This device has been replaced")
                    .font(.callout)
                    .foregroundStyle(.colorTextPrimary)
                Text("Another device took over your Convos account. Reset to start fresh on this phone.")
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextSecondary)
                Button(action: action) {
                    Text("Reset this device")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.colorLava)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stale-device-banner")
    }
}

#Preview {
    StaleDeviceBanner(onReset: {})
        .padding()
}
