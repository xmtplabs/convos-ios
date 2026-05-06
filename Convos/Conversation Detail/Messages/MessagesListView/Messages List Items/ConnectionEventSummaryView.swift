import ConvosCore
import SwiftUI

struct ConnectionEventSummaryView: View {
    let summary: ConnectionEventSummary
    /// Live name of the verified assistant in the current conversation. The
    /// processor leaves `.verifiedAssistant`-actor summaries unprefixed and
    /// this view prepends the name at render time so the rendered text stays
    /// in sync with the conversation's stable membership snapshot, instead of
    /// flapping with the per-emission `agentVerification` state in
    /// memberProfiles. Pass `nil` if no verified assistant is in the
    /// conversation; the view falls back to rendering `summary.text` as-is.
    var verifiedAssistantName: String?

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
        guard summary.actor == .verifiedAssistant,
              let name = verifiedAssistantName,
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
