import SwiftUI

struct ExplosionCountdownBadge: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            if remaining > 0 {
                HStack(spacing: DesignConstants.Spacing.stepHalf) {
                    Image(systemName: "timer")
                        .font(.caption2)
                    Text(formatCountdown(remaining))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.colorOrange)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.vertical, DesignConstants.Spacing.stepX)
                .background(.colorOrange.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }

    private func formatCountdown(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)d \(remainingHours)h"
        } else {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(90))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(3700))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(90000))
    }
    .padding()
}
