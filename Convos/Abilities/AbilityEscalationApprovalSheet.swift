import ConvosCore
import SwiftUI

/// Approval sheet for an agent's ability-use ask: the owner narrows the
/// requested permission bundles (never widens -- bundles the agent did
/// not ask for are not offered), picks a scope, and allows or declines.
/// Layout mirrors `AbilityBundleSelectionSheet` (header / rows / actions).
///
/// A swipe-down is neither answer: the request stays pending and the
/// prompt card stays up. Deliberate -- consent must be explicit, so only
/// Allow and Don't allow resolve the ask; the sheet is closed by the view
/// model once the service call lands.
struct AbilityEscalationApprovalSheet: View {
    let context: AbilityEscalationApprovalContext
    let isResolving: Bool
    let onAllow: ([String], AbilityDelegationScope) -> Void
    let onDecline: () -> Void

    @State private var enabledBundleIds: Set<String> = []
    @State private var didSeedSelection: Bool = false
    @State private var scopeChoice: ScopeChoice = .once

    /// Owner-facing scope choices; maps onto `AbilityDelegationScope` at
    /// grant. Defaults to `.once` (least privilege).
    private enum ScopeChoice: String, CaseIterable, Identifiable {
        case once = "Just once"
        case day = "1 day"
        case week = "1 week"

        var id: String { rawValue }
    }

    /// Scrollable so the header is never clipped at the medium detent and
    /// large Dynamic Type sizes scroll instead of overflowing.
    var body: some View {
        ScrollView {
            VStack(spacing: DesignConstants.Spacing.step4x) {
                header
                permissionRows
                scopePicker
                actionButtons
            }
            .padding(.vertical, DesignConstants.Spacing.step6x)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .onAppear { seedSelectionIfNeeded() }
    }

    private var header: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            AbilityIconView(ability: context.ability)
            Text("Let \(context.request.agentDisplayName) use \(context.ability.displayName.resolved())?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text(context.request.reason)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
            Text("Asked by \(context.request.agentDisplayName) in this convo")
                .font(.caption)
                .foregroundStyle(.colorTextTertiary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    /// One toggle per requested bundle, seeded on. Row layout copies
    /// `AbilityBundleSelectionSheet.bundleRow`'s pattern (not extracted:
    /// the two sheets may diverge).
    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Permissions")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)

            VStack(spacing: Constant.rowGap) {
                ForEach(requestedBundles) { bundle in
                    bundleRow(bundle)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge))
            .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }

    private func bundleRow(_ bundle: AbilitiesAPI.AbilityBundle) -> some View {
        let binding: Binding<Bool> = bundleBinding(bundleId: bundle.id)
        let description: String = bundle.description.resolved()
        return HStack(spacing: DesignConstants.Spacing.step2x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(bundle.title.resolved())
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
            }
            Spacer(minLength: 0)
            Toggle(bundle.title.resolved(), isOn: binding)
                .labelsHidden()
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorBackgroundSurfaceless)
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("How long")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)

            Picker("How long", selection: $scopeChoice) {
                ForEach(ScopeChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .accessibilityIdentifier("escalation-scope-picker")
        }
    }

    private var actionButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            allowButton
            declineButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var allowButton: some View {
        let allowAction = {
            onAllow(enabledBundleIds.sorted(), delegationScope())
        }
        return Button("Allow", action: allowAction)
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(enabledBundleIds.isEmpty || isResolving)
            .accessibilityIdentifier("escalation-allow-button")
    }

    /// An explicit negative resolution, not a dismissal: styled like the
    /// sheets' cancel buttons but it resolves the request.
    private var declineButton: some View {
        let declineAction = onDecline
        return Button(action: declineAction) {
            Text("Don't allow")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        }
        .disabled(isResolving)
        .accessibilityIdentifier("escalation-decline-button")
    }

    /// The requested bundles resolved against the catalog ability's
    /// metadata; the owner can narrow this set, not widen it.
    private var requestedBundles: [AbilitiesAPI.AbilityBundle] {
        let requested = Set(context.request.requestedBundleIds)
        return context.ability.bundles.filter { (bundle: AbilitiesAPI.AbilityBundle) -> Bool in
            requested.contains(bundle.id)
        }
    }

    private func delegationScope(now: Date = Date()) -> AbilityDelegationScope {
        switch scopeChoice {
        case .once: .oneShot
        case .day: .expiring(now.addingTimeInterval(Constant.dayInterval))
        case .week: .expiring(now.addingTimeInterval(Constant.weekInterval))
        }
    }

    private func bundleBinding(bundleId: String) -> Binding<Bool> {
        Binding(
            get: { enabledBundleIds.contains(bundleId) },
            set: { isOn in
                if isOn {
                    enabledBundleIds.insert(bundleId)
                } else {
                    enabledBundleIds.remove(bundleId)
                }
            }
        )
    }

    private func seedSelectionIfNeeded() {
        guard !didSeedSelection else { return }
        didSeedSelection = true
        enabledBundleIds = Set(context.request.requestedBundleIds)
    }

    private enum Constant {
        static let rowGap: CGFloat = 1.0
        static let dayInterval: TimeInterval = 86_400
        static let weekInterval: TimeInterval = 604_800
    }
}

#Preview("Approval sheet") {
    let gcal = MockAbilitiesService.standardCatalog().first { $0.id == "googlecalendar" }
    if let gcal {
        AbilityEscalationApprovalSheet(
            context: AbilityEscalationApprovalContext(
                request: MockAbilityEscalationService.scriptedRequest(conversationId: "mock-conversation-1"),
                ability: gcal
            ),
            isResolving: false,
            onAllow: { _, _ in },
            onDecline: {}
        )
    }
}
