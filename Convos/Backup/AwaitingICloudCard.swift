import SwiftUI

/// Shown on the empty conversations list while `BackupCoordinator` is
/// holding the bootstrap gate closed waiting for iCloud Documents and
/// iCloud Keychain to settle. The wait exists to keep a fresh install
/// on Device B from minting a new identity that would propagate via
/// iCloud Keychain and overwrite Device A's identity. Visible feedback
/// is the difference between "the app is broken" and "the app is being
/// careful with your account."
struct AwaitingICloudCard: View {
    let secondsRemaining: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "icloud")
                    .foregroundStyle(.colorFillPrimary)
                    .font(.callout)
                Text("Checking iCloud for your account")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.colorTextPrimary)
            }

            Text(
                "We're waiting for iCloud Keychain to deliver your "
                + "identity before letting this device set up a new "
                + "account. This usually takes a few seconds."
            )
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)

            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProgressView()
                    .progressViewStyle(.circular)
                if secondsRemaining > 0 {
                    Text("Up to \(secondsRemaining)s remaining")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .accessibilityIdentifier("awaiting-icloud-card")
    }
}

#Preview {
    AwaitingICloudCard(secondsRemaining: 42)
        .padding()
}
