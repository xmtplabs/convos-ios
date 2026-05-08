import ConvosCore
import SwiftUI

struct ConnectionEventSummaryView: View {
    let summary: ConnectionEventSummary

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)

            Text(summary.text)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.text)
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
