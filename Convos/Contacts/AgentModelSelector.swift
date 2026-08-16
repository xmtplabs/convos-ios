import Foundation
import SwiftUI

/// Prototype catalog for per-agent model choice. These labels and credit
/// multipliers came from the UX brief; the production catalog should arrive
/// from the agent runtime with stable ids, plan requirements, and live cost.
enum AgentModelOption: String, CaseIterable, Identifiable, Sendable {
    case gpt56Sol = "gpt-5.6-sol"
    case claudeOpus = "claude-opus"
    case claudeFable = "claude-fable"
    case droc46 = "droc-4.6"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt56Sol: return "GPT-5.6 Sol"
        case .claudeOpus: return "Claude Opus"
        case .claudeFable: return "Claude Fable"
        case .droc46: return "DROC 4.6"
        }
    }

    var providerName: String {
        switch self {
        case .gpt56Sol: return "OpenAI"
        case .claudeOpus, .claudeFable: return "Anthropic"
        case .droc46: return "DROC"
        }
    }

    var systemImage: String {
        switch self {
        case .gpt56Sol: return "sparkles"
        case .claudeOpus: return "brain.head.profile"
        case .claudeFable: return "book.closed.fill"
        case .droc46: return "bolt.fill"
        }
    }

    var creditMultiplier: Int {
        switch self {
        case .gpt56Sol: return 1
        case .claudeOpus: return 2
        case .claudeFable: return 4
        case .droc46: return 3
        }
    }

    var requiresPlus: Bool { self != .gpt56Sol }

    var capabilitySummary: String {
        switch self {
        case .gpt56Sol: return "Fast, capable, and included"
        case .claudeOpus: return "Deep reasoning for complex work"
        case .claudeFable: return "Highest-power creative reasoning"
        case .droc46: return "Fast research and live synthesis"
        }
    }

    var usageLabel: String {
        creditMultiplier == 1
            ? "Standard credit use"
            : "\(creditMultiplier)× standard credit use"
    }
}

/// A deliberately narrow on-device seam for the clickable prototype. Keeping
/// it behind one type makes the future replacement with a runtime repository
/// explicit rather than scattering UserDefaults through the profile view.
/// UserDefaults provides its own synchronization; this wrapper is immutable.
struct AgentModelPreferenceStore: @unchecked Sendable {
    static let live: AgentModelPreferenceStore = AgentModelPreferenceStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func selection(for agentId: String) -> AgentModelOption {
        guard let rawValue = defaults.string(forKey: key(for: agentId)),
              let model = AgentModelOption(rawValue: rawValue) else {
            return .gpt56Sol
        }
        return model
    }

    func save(_ model: AgentModelOption, for agentId: String) {
        defaults.set(model.rawValue, forKey: key(for: agentId))
    }

    private func key(for agentId: String) -> String {
        "prototype.agent-model.\(agentId)"
    }
}

/// The profile's first action: one large selector surface with any required
/// upgrade explanation revealed in place. It inherits the contact card's
/// rounded surfaces and semantic colors instead of introducing a settings UI.
struct AgentModelSelectorSection: View {
    let model: AgentModelOption
    let needsUpgrade: Bool
    let onChooseModel: () -> Void
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text("Model")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .padding(.leading, DesignConstants.Spacing.step2x)

            VStack(spacing: 0.0) {
                modelButton
                if needsUpgrade {
                    Divider()
                        .padding(.leading, 68.0)
                    upgradePrompt
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                    .fill(.colorFillMinimal)
            )
        }
    }

    private var modelButton: some View {
        Button(action: onChooseModel) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: model.systemImage)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(width: 44.0, height: 44.0)
                    .background(Circle().fill(.colorFillPrimary))

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(model.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.colorTextPrimary)
                    Text(modelStatus)
                        .font(.footnote)
                        .foregroundStyle(needsUpgrade ? .colorTextPrimary : .colorTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 44.0, height: 44.0)
            }
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model, \(model.displayName), \(modelStatus)")
        .accessibilityHint("Shows all available models")
        .accessibilityIdentifier("contact-detail-agent-model")
    }

    private var modelStatus: String {
        needsUpgrade
            ? "Upgrade required · \(model.usageLabel)"
            : "\(model.providerName) · \(model.usageLabel)"
    }

    private var upgradePrompt: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("More power, when you need it")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text("\(model.displayName) uses more credits than the standard model. Upgrade your plan to make it active for this agent.")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onUpgrade) {
                Text("Upgrade to use \(model.displayName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44.0)
                    .background(Capsule().fill(.colorFillPrimary))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("contact-detail-agent-model-upgrade")
        }
        .padding(.top, DesignConstants.Spacing.step3x)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.step4x)
    }
}

/// Native selection sheet. Grouping communicates plan access before the tap;
/// the active model remains distinct from a locked model the user is previewing.
struct AgentModelPickerSheet: View {
    let activeModel: AgentModelOption
    let highlightedModel: AgentModelOption
    let hasPlusSubscription: Bool
    let onSelect: (AgentModelOption) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            List {
                modelSection(
                    title: "Included",
                    models: AgentModelOption.allCases.filter { !$0.requiresPlus }
                )
                modelSection(
                    title: "More power",
                    models: AgentModelOption.allCases.filter(\.requiresPlus)
                )
            }
            .navigationTitle("Choose a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func modelSection(title: String, models: [AgentModelOption]) -> some View {
        Section {
            ForEach(models) { model in
                modelRow(model)
            }
        } header: {
            Text(title)
        } footer: {
            if title == "More power" {
                Text("Higher-power models require Plus and use more credits. Your choice applies only to this agent.")
            }
        }
    }

    private func modelRow(_ model: AgentModelOption) -> some View {
        Button {
            onSelect(model)
            dismiss()
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Image(systemName: model.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 32.0, height: 32.0)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        Text(model.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.colorTextPrimary)
                        if model == activeModel {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.colorTextSecondary)
                        } else if model == highlightedModel,
                                  model.requiresPlus,
                                  !hasPlusSubscription {
                            Text("Pending upgrade")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                    Text(rowSubtitle(for: model))
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingIcon(for: model)
            }
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: model))
        .accessibilityAddTraits(model == activeModel ? .isSelected : [])
        .accessibilityIdentifier("agent-model-option-\(model.rawValue)")
    }

    private func rowSubtitle(for model: AgentModelOption) -> String {
        var parts: [String] = [model.capabilitySummary, model.usageLabel]
        if model.requiresPlus, !hasPlusSubscription {
            parts.append("Requires Plus")
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(for model: AgentModelOption) -> String {
        var parts: [String] = [
            model.displayName,
            model.capabilitySummary,
            model.usageLabel,
        ]
        if model == activeModel {
            parts.append("Current model")
        } else if model.requiresPlus, !hasPlusSubscription {
            parts.append(
                model == highlightedModel
                    ? "Selected for upgrade. Requires Plus"
                    : "Requires Plus"
            )
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func trailingIcon(for model: AgentModelOption) -> some View {
        if model == activeModel {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.colorTextPrimary)
                .accessibilityHidden(true)
        } else if model.requiresPlus, !hasPlusSubscription {
            Image(systemName: "lock.fill")
                .foregroundStyle(.colorTextSecondary)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Model selector — active") {
    AgentModelSelectorSection(
        model: .gpt56Sol,
        needsUpgrade: false,
        onChooseModel: {},
        onUpgrade: {}
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}

#Preview("Model selector — upgrade") {
    AgentModelSelectorSection(
        model: .claudeFable,
        needsUpgrade: true,
        onChooseModel: {},
        onUpgrade: {}
    )
    .padding()
    .background(.colorBackgroundRaisedSecondary)
}
