import ConvosCore
import SwiftUI

struct ConnectionEventSummaryView: View {
    let summary: ConnectionEventSummary
    /// Live agent display names keyed by inbox id, sourced from the
    /// conversation's current members. The renderer prepends the resolved
    /// name for `.grantedAgent`-actor summaries so ProfileUpdate-driven
    /// renames propagate without reprocessing the message list. Pass an
    /// empty dictionary if no agents are in the conversation; the view
    /// falls back to rendering `summary.text` as-is.
    var agentNamesByInboxId: [String: String]

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)

            Text(renderedText)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(renderedText)
    }

    private var renderedText: String {
        guard summary.actor == .grantedAgent,
              let inboxId = summary.grantedToInboxId,
              let name = agentNamesByInboxId[inboxId],
              !name.isEmpty else {
            return summary.text
        }
        return "\(name) \(summary.text)"
    }

    private var iconName: String {
        switch summary.icon {
        case .health:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "heart.text.square"
        case .calendar:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "calendar"
        case .contacts:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "person.crop.circle"
        case .photos:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "photo"
        case .music:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "music.note"
        case .home:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "house"
        case .generic:
            return summary.outcome == .failure ? "exclamationmark.triangle.fill" : "bolt.horizontal"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch summary.outcome {
        case .failure:
            return .red.opacity(0.8)
        case .pending, .success:
            return .secondary
        }
    }
}
