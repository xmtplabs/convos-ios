import SwiftUI

/// Presented from `ConversationsView` when `AccountDeletedObserver`
/// detects the session has landed in `.error(AccountDeletedError)` — the
/// account was deleted (typically from another paired device). The only
/// forward action is wiping this device's local data; the account itself
/// is already gone and nothing re-creates one without explicit intent.
struct AccountDeletedSheet: View {
    let onWipe: () -> Void
    let onContinue: () -> Void
    var isWiping: Bool = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Heads up")
                    .textCase(.uppercase)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)

                Text("This account was deleted")
                    .font(.system(.largeTitle))
                    .fontWeight(.bold)
                    .padding(.bottom, DesignConstants.Spacing.step4x)

                Text("This account was deleted, so this device can no longer use it.")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)

                Text("Delete the data on this device to start fresh.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: DesignConstants.Spacing.step2x) {
                HoldToWipeButton(isWiping: isWiping, onWipe: onWipe)

                let continueAction = { onContinue() }
                Button(action: continueAction) {
                    Text("Not now")
                }
                .convosButtonStyle(.text)
                .frame(maxWidth: .infinity)
                .disabled(isWiping)
            }
            .padding(.top, DesignConstants.Spacing.step4x)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step10x : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deleted-sheet")
    }
}

private struct HoldToWipeButton: View {
    let isWiping: Bool
    let onWipe: () -> Void

    private var buttonConfig: HoldToConfirmStyleConfig {
        var config = HoldToConfirmStyleConfig.default
        config.duration = 3.0
        config.backgroundColor = .colorCaution
        return config
    }

    var body: some View {
        let action = { onWipe() }
        let label: String = isWiping ? "Deleting data" : "Hold to delete data on this device"
        let hint: String = isWiping ? "" : "Hold to confirm"
        Button(action: action) {
            textView
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .disabled(isWiping)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: buttonConfig))
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier("hold-to-wipe-deleted-account-button")
    }

    private var textView: some View {
        let idleOpacity: Double = isWiping ? 0 : 1
        let busyOpacity: Double = isWiping ? 1 : 0
        return ZStack {
            Text("Hold to delete")
                .opacity(idleOpacity)
            Text("Deleting...")
                .opacity(busyOpacity)
        }
        .animation(.easeInOut(duration: 0.2), value: isWiping)
    }
}

#Preview {
    AccountDeletedSheet(onWipe: {}, onContinue: {})
}
