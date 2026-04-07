import SwiftUI

struct StaleDeviceBanner: View {
    let onDeleteData: () -> Void

    var body: some View {
        let action = onDeleteData
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.colorLava)
                    .font(.callout)
                Text("This device has been replaced")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.colorTextPrimary)
            }
            Text("Your account has been restored on another device. This one is no longer active.")
                .font(.system(size: 13))
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive, action: action) {
                Text("Delete data and start fresh")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.colorLava)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityLabel("This device has been replaced. Tap delete data and start fresh to continue.")
        .accessibilityIdentifier("stale-device-banner")
    }
}

#Preview {
    StaleDeviceBanner(onDeleteData: {})
        .padding()
}
