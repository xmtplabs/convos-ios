import ConvosCore
import SwiftUI

struct AgentLostPowerStatus: View {
    let agentName: String
    let isCreator: Bool
    var onUpgrade: (() -> Void)?
    var onLearnMore: (() -> Void)?

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "bolt.fill")
                    .font(.footnote)
                    .foregroundStyle(.colorLava)
                Text("\(agentName) lost power")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }

            if isCreator {
                upgradeButton
            } else {
                learnMoreButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var upgradeButton: some View {
        let action = { onUpgrade?() }
        Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text("Upgrade")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .background(Capsule().fill(.colorLava))
        }
    }

    @ViewBuilder
    private var learnMoreButton: some View {
        let action = { onLearnMore?() }
        Button(action: action) {
            Text("Learn more")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .background(
                    Capsule()
                        .stroke(.colorBorderSubtle, lineWidth: 1)
                )
        }
    }
}

#Preview("Creator") {
    AgentLostPowerStatus(
        agentName: "Hoodrat",
        isCreator: true,
        onUpgrade: {}
    )
}

#Preview("Non-creator") {
    AgentLostPowerStatus(
        agentName: "Hoodrat",
        isCreator: false,
        onLearnMore: {}
    )
}
