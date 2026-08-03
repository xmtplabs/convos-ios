import ConvosCore
import SwiftUI

/// Bundle picker shown before extending a multi-bundle ability to an
/// agent: one toggle per permission bundle, seeded from the manifest's
/// default-enabled set. Mirrors the permission rows of the capability
/// approval sheet. An empty selection never turns into an extension; the
/// confirm button disables instead.
struct AbilityBundleSelectionSheet: View {
    let context: AbilityBundleSelectionContext
    let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var enabledBundleIds: Set<String> = []
    @State private var didSeedSelection: Bool = false

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            header
            bundleRows
            actionButtons
        }
        .padding(.vertical, DesignConstants.Spacing.step6x)
        .presentationDetents([.medium, .large])
        .onAppear { seedSelectionIfNeeded() }
    }

    private var header: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            AbilityIconView(ability: context.ability)
            Text("Share \(context.ability.displayName.resolved())?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text("Choose what \(context.agent.displayName) can use in this convo.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var bundleRows: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Permissions")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step4x)

            VStack(spacing: Constant.rowGap) {
                ForEach(context.ability.bundles) { bundle in
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

    private var actionButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            confirmButton
            cancelButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var confirmButton: some View {
        let confirmAction = {
            onConfirm(enabledBundleIds.sorted())
            dismiss()
        }
        return Button("Share", action: confirmAction)
            .convosButtonStyle(.rounded(fullWidth: true))
            .disabled(enabledBundleIds.isEmpty)
            .accessibilityIdentifier("ability-bundle-share-button")
    }

    private var cancelButton: some View {
        let cancelAction = { dismiss() }
        return Button(action: cancelAction) {
            Text("Cancel")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        }
    }

    private func seedSelectionIfNeeded() {
        guard !didSeedSelection else { return }
        didSeedSelection = true
        enabledBundleIds = Set(context.ability.bundles.filter(\.defaultEnabled).map(\.id))
    }

    private enum Constant {
        static let rowGap: CGFloat = 1.0
    }
}

#Preview("Bundle selection") {
    let gcal = MockAbilitiesService.standardCatalog().first { $0.id == "googlecalendar" }
    if let gcal {
        AbilityBundleSelectionSheet(
            context: AbilityBundleSelectionContext(
                ability: gcal,
                agent: ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley")
            ),
            onConfirm: { _ in }
        )
    }
}
