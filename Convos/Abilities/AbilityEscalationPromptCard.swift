import ConvosCore
import SwiftUI

/// Consent prompt for an agent's ability-use ask: centered caption above
/// a tappable ability pill, one reason line underneath. Borrows
/// `CapabilityConnectPromptView`'s layout language (caption + pill), but
/// lives on an app surface, not in the transcript.
///
/// Entry points: exactly one today -- the conversation bottom bar's
/// status slot, via `AbilityEscalationPromptSurface`. The approval sheet
/// is reachable from nowhere else. Behavior is single-entry, so no mode
/// enum is warranted (the `ContactDetailMode` convention kicks in only
/// once a second entry point branches behavior).
struct AbilityEscalationPromptCard: View {
    let request: AbilityDelegationRequest
    /// Display name resolved from the catalog; falls back to the raw
    /// ability id only if the fixture and catalog ever diverge.
    let abilityDisplayName: String
    /// The catalog entry backing this ask, when it has resolved. Nil in
    /// the brief window between the card appearing and the async catalog
    /// lookup completing, and whenever the catalog carries no `icon` for
    /// this ability -- either way, `pillContent` falls back to the local
    /// symbol.
    let ability: AbilitiesAPI.Ability?
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Text("\(request.agentDisplayName) asked to use")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)

            let action = onTap
            Button(action: action) {
                pillContent
            }
            .buttonStyle(.plain)

            Text(request.reason)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(request.agentDisplayName) asked to use \(abilityDisplayName). \(request.reason)")
        .accessibilityIdentifier("escalation-prompt-card")
    }

    private var pillContent: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            pillIcon

            Text(abilityDisplayName)
                .font(.callout)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.colorTextTertiary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .frame(height: Constant.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(Color.colorFillMinimal)
        )
        .contentShape(.rect)
    }

    /// The catalog icon once resolved, matching `AbilityEscalationApprovalSheet`'s
    /// header; falls back to today's local SF Symbol otherwise -- including
    /// while the backend has not yet populated `icon.iosUrl` for any ability.
    @ViewBuilder
    private var pillIcon: some View {
        if let ability {
            AbilityIconView(ability: ability, iconSize: Constant.iconSize, showsBackground: false)
        } else {
            Image(systemName: AbilityIconView.symbolName(for: request.abilityId))
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.iconSize, height: Constant.iconSize)
        }
    }

    private enum Constant {
        static let pillHeight: CGFloat = 44.0
        static let iconSize: CGFloat = 24.0
    }
}

/// Thin wrapper the conversation bottom bar embeds: renders the card for
/// the view model's pending ask and owns the approval sheet presentation,
/// so `ConversationView` adds exactly one view expression and zero new
/// modifiers to its already-heavy body.
struct AbilityEscalationPromptSurface: View {
    @Bindable var viewModel: ConversationEscalationViewModel

    var body: some View {
        Group {
            if let request = viewModel.pendingRequest {
                AbilityEscalationPromptCard(
                    request: request,
                    abilityDisplayName: abilityDisplayName(for: request),
                    ability: matchedAbility(for: request),
                    onTap: handleCardTap
                )
            }
        }
        .sheet(item: $viewModel.approvalContext) { context in
            approvalSheet(context)
        }
    }

    private func abilityDisplayName(for request: AbilityDelegationRequest) -> String {
        guard let ability = matchedAbility(for: request) else {
            return request.abilityId
        }
        return ability.displayName.resolved()
    }

    /// The resolved catalog entry for `request`, or nil if the async
    /// catalog lookup hasn't landed yet (or resolved a different ask).
    private func matchedAbility(for request: AbilityDelegationRequest) -> AbilitiesAPI.Ability? {
        guard let ability = viewModel.pendingAbility, ability.id == request.abilityId else {
            return nil
        }
        return ability
    }

    private func handleCardTap() {
        viewModel.presentApproval()
    }

    private func approvalSheet(_ context: AbilityEscalationApprovalContext) -> some View {
        AbilityEscalationApprovalSheet(
            context: context,
            isResolving: viewModel.isResolving,
            onAllow: handleAllow,
            onDecline: handleDecline
        )
    }

    private func handleAllow(bundleIds: [String], scope: AbilityDelegationScope) {
        viewModel.grant(bundleIds: bundleIds, scope: scope)
    }

    private func handleDecline() {
        viewModel.decline()
    }
}

#Preview("Prompt card - symbol fallback") {
    AbilityEscalationPromptCard(
        request: MockAbilityEscalationService.scriptedRequest(conversationId: "mock-conversation-1"),
        abilityDisplayName: "Google Calendar",
        ability: nil,
        onTap: {}
    )
    .padding(DesignConstants.Spacing.step4x)
}

#Preview("Prompt card - catalog icon") {
    // Constructed inline with a self-contained data: URI rather than a
    // shared fixture: the backend does not populate `icon.iosUrl` yet (see
    // MockAbilitiesService's googlecalendar entry), so this is preview-only
    // stand-in data for the day it does, kept off the shared catalog to
    // avoid changing every other mock-mode surface's rendering.
    let previewIcon: AbilitiesAPI.AbilityIcon? = try? AbilitiesAPI.AbilityIcon(
        iosUrl: PreviewData.calendarIconDataUrl,
        androidUrl: PreviewData.calendarIconDataUrl
    )
    let ability: AbilitiesAPI.Ability? = try? AbilitiesAPI.Ability(
        id: "googlecalendar",
        version: 1,
        displayName: AbilitiesAPI.LocalizedText(en: "Google Calendar"),
        subtitle: AbilitiesAPI.LocalizedText(en: "View and edit events"),
        icon: previewIcon,
        auth: AbilitiesAPI.AbilityAuth(type: .oauth),
        bundles: []
    )
    if let ability {
        AbilityEscalationPromptCard(
            request: MockAbilityEscalationService.scriptedRequest(conversationId: "mock-conversation-1"),
            abilityDisplayName: ability.displayName.resolved(),
            ability: ability,
            onTap: {}
        )
        .padding(DesignConstants.Spacing.step4x)
    }
}

/// Self-contained preview fixtures: a data: URI so `AsyncImage` has a real
/// image to decode without any network dependency.
private enum PreviewData {
    static let calendarIconDataUrl: String = """
    data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR42mOQKn5BU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULACYM1EwIDQXQAAAAAElFTkSuQmCC
    """
}
