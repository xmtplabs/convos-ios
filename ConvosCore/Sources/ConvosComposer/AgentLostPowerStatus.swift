#if canImport(UIKit)
import ConvosCore
import SwiftUI

public struct AgentLostPowerStatus: View {
    public let agentName: String
    public let isCreator: Bool
    public var onUpgrade: (() -> Void)?

    public init(agentName: String, isCreator: Bool, onUpgrade: (() -> Void)? = nil) {
        self.agentName = agentName
        self.isCreator = isCreator
        self.onUpgrade = onUpgrade
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                Image(systemName: "bolt.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.colorLava)
                Text("\(agentName) lost power")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }

            if isCreator {
                upgradeButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var upgradeButton: some View {
        let action = { if let onUpgrade { onUpgrade() } }
        Button(action: action) {
            Text("Upgrade")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step3HalfX)
                .background(Capsule().fill(.colorLava))
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
        isCreator: false
    )
}
#endif
