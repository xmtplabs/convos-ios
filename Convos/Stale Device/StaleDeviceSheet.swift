import SwiftUI

/// Presented from `ConversationsView` as a self-sizing sheet when
/// `StaleDeviceObserver` detects the session has landed in
/// `.error(DeviceReplacedError)` — another paired device revoked this one.
/// Visual design mirrors `ConversationForkedInfoView`. "Hold to delete"
/// runs the destructive reset (same path as Settings -> Delete all data);
/// "Continue" dismisses the sheet for this session.
struct StaleDeviceSheet: View {
    let onDelete: () -> Void
    let onContinue: () -> Void
    var isDeleting: Bool = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Heads up")
                    .textCase(.uppercase)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)

                Text("This device has been removed")
                    .font(.system(.largeTitle))
                    .fontWeight(.bold)
                    .padding(.bottom, DesignConstants.Spacing.step4x)

                Text("Another device removed this one from your account.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("Delete all data to start fresh or pair again.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                HoldToDeleteButton(isDeleting: isDeleting, onDelete: onDelete)

                let continueAction = { onContinue() }
                Button(action: continueAction) {
                    Text("Continue")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
                .disabled(isDeleting)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stale-device-sheet")
    }
}

private struct HoldToDeleteButton: View {
    let isDeleting: Bool
    let onDelete: () -> Void

    private var buttonConfig: HoldToConfirmStyleConfig {
        var config = HoldToConfirmStyleConfig.default
        config.duration = 3.0
        config.backgroundColor = .colorCaution
        return config
    }

    var body: some View {
        let action = { onDelete() }
        Button(action: action) {
            ZStack {
                Text("Hold to delete")
                    .opacity(isDeleting ? 0 : 1)
                Text("Deleting...")
                    .opacity(isDeleting ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: isDeleting)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .disabled(isDeleting)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: buttonConfig))
        .accessibilityLabel(isDeleting ? "Deleting device data" : "Hold to delete device data")
        .accessibilityHint(isDeleting ? "" : "Hold to confirm")
        .accessibilityIdentifier("hold-to-delete-device-button")
    }
}

#Preview {
    @Previewable @State var presenting: Bool = false
    let toggle = { presenting.toggle() }
    VStack {
        Button(action: toggle) {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presenting) {
        StaleDeviceSheet(onDelete: {}, onContinue: { presenting = false })
    }
}
