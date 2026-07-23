import ConvosCore
import SwiftUI

/// Stubbed stand-in for the OAuth browser session between
/// `beginEntitlement` and `completeEntitlement`. Track A has no live
/// backend to bounce through, so the redirect URL is shown and approval
/// is a tap; the live transport replaces this presentation with the
/// `OAuthSessionProvider` machinery driving the same approve/cancel
/// callbacks, leaving the view-model flow untouched.
struct AbilityAuthorizationSheet: View {
    let context: AbilityAuthorizationContext
    let onAuthorize: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            header
            redirectPreview
            actionButtons
        }
        .padding(.vertical, DesignConstants.Spacing.step6x)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }

    private var header: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            AbilityIconView(ability: context.ability)
            Text("Connect \(context.ability.displayName.resolved())?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text("You'll sign in with \(context.ability.displayName.resolved()) to finish connecting.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var redirectPreview: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(context.redirectUrl)
                .font(.caption.monospaced())
                .foregroundStyle(.colorTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Mock authorization: no browser opens in this build.")
                .font(.caption)
                .foregroundStyle(.colorTextTertiary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var actionButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            authorizeButton
            cancelButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var authorizeButton: some View {
        let authorizeAction = onAuthorize
        return Button("Authorize", action: authorizeAction)
            .convosButtonStyle(.rounded(fullWidth: true))
            .accessibilityIdentifier("ability-authorize-button")
    }

    private var cancelButton: some View {
        let cancelAction = onCancel
        return Button(action: cancelAction) {
            Text("Cancel")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        }
    }
}

#Preview("Authorization") {
    let gcal = MockAbilitiesService.standardCatalog().first { $0.id == "googlecalendar" }
    if let gcal {
        AbilityAuthorizationSheet(
            context: AbilityAuthorizationContext(
                ability: gcal,
                redirectUrl: "https://mock.convos.org/oauth/googlecalendar"
            ),
            onAuthorize: {},
            onCancel: {}
        )
    }
}
