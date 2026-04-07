import SwiftUI

struct StaleDeviceBanner: View {
    let onDeleteData: () -> Void
    let onLearnMore: () -> Void

    var body: some View {
        let deleteAction = onDeleteData
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
            }
            Text("Your account has been restored on another device. This one can no longer access your conversations.")
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

                Button(role: .destructive, action: deleteAction) {
                    Text("Delete data and start fresh")
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
        .accessibilityLabel("This device has been replaced. This device can no longer access your conversations. Learn more or delete data and start fresh.")
        .accessibilityIdentifier("stale-device-banner")
    }
}

struct StaleDeviceInfoView: View {
    let onDeleteData: () -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        let action = {
            dismiss()
            onDeleteData()
        }
        FeatureInfoSheet(
            title: "This device no longer has access",
            paragraphs: [
                .init("Your account was restored on another device, which revoked this installation."),
                .init("To continue using Convos on this device, delete local data and start fresh.")
            ],
            primaryButtonTitle: "Delete data and start fresh",
            primaryButtonAction: action,
            showDragIndicator: true
        )
    }
}

#Preview {
    VStack(spacing: 16) {
        StaleDeviceBanner(onDeleteData: {}, onLearnMore: {})
        StaleDeviceInfoView(onDeleteData: {})
    }
    .padding()
}
