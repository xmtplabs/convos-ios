import ConvosCore
import SwiftUI

/// Transcript row for a capability request: centered "<Agent> wants to connect"
/// caption above a tappable service pill (Figma frame 4900). The pill persists
/// in history; its trailing accessory reflects the derived status — chevron
/// while pending (tap opens the approval sheet), checkmark once any member's
/// approval lands, nothing once dismissed.
struct CapabilityConnectPromptView: View {
    let prompt: CapabilityConnectPrompt
    let agentName: String
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Text("\(agentName) wants to connect")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)

            let action = onTap
            Button(action: action) {
                pillContent
            }
            .buttonStyle(.plain)
            .disabled(prompt.status != .pending)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agentName) wants to connect \(prompt.serviceName)")
    }

    private var pillContent: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            serviceIcon

            Text(prompt.serviceName)
                .font(.callout)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)

            statusAccessory
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .frame(height: Constant.pillHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                .fill(Color.colorFillMinimal)
        )
        .contentShape(.rect)
    }

    @ViewBuilder
    private var serviceIcon: some View {
        if let assetName = ConnectionServiceIcon.assetName(forServiceId: prompt.serviceId) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: Constant.iconSize, height: Constant.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.small)
                        .stroke(Color.colorBorderEdge, lineWidth: Constant.iconBorderWidth)
                )
        } else {
            Image(systemName: fallbackSymbolName)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.iconSize, height: Constant.iconSize)
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch prompt.status {
        case .pending:
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.colorTextTertiary)
        case .connected:
            Image(systemName: "checkmark")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
        case .dismissed:
            EmptyView()
        }
    }

    private var fallbackSymbolName: String {
        switch prompt.icon {
        case .health: return "heart.text.square"
        case .calendar: return "calendar"
        case .contacts: return "person.crop.circle"
        case .photos: return "photo"
        case .music: return "music.note"
        case .home: return "house"
        case .generic, .error: return "bolt.horizontal"
        }
    }

    private enum Constant {
        static let pillHeight: CGFloat = 44.0
        static let iconSize: CGFloat = 24.0
        static let iconBorderWidth: CGFloat = 0.4
    }
}

#if DEBUG
#Preview("Pending / Connected / Dismissed") {
    VStack(spacing: DesignConstants.Spacing.step6x) {
        CapabilityConnectPromptView(
            prompt: CapabilityConnectPrompt(
                requestId: "req-1",
                askerInboxId: "agent",
                serviceName: "Google Calendar",
                serviceId: "googlecalendar",
                icon: .calendar,
                status: .pending
            ),
            agentName: "Assistant",
            onTap: {}
        )
        CapabilityConnectPromptView(
            prompt: CapabilityConnectPrompt(
                requestId: "req-2",
                askerInboxId: "agent",
                serviceName: "Google Calendar",
                serviceId: "googlecalendar",
                icon: .calendar,
                status: .connected
            ),
            agentName: "Assistant",
            onTap: {}
        )
        CapabilityConnectPromptView(
            prompt: CapabilityConnectPrompt(
                requestId: "req-3",
                askerInboxId: "agent",
                serviceName: "Calendar",
                serviceId: nil,
                icon: .calendar,
                status: .dismissed
            ),
            agentName: "Assistant",
            onTap: {}
        )
    }
    .padding()
}
#endif
