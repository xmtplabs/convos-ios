import SwiftUI

struct ExplosionCountdownBadge: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            if remaining > 0 {
                let isUrgent = remaining <= 24 * 3600
                Text(formatCountdown(remaining))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isUrgent ? .colorCaution : .colorTextSecondary)
                    .padding(.horizontal, DesignConstants.Spacing.step2x)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .background(isUrgent ? .colorCaution.opacity(0.15) : .colorFillMinimal)
                    .clipShape(Capsule())
            }
        }
    }

    private func formatCountdown(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(ceil(interval))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours >= 24 {
            let days = hours / 24
            return "\(days)d"
        } else if hours == 0 && minutes == 0 {
            return String(format: "00:%02d", seconds)
        } else {
            return String(format: "%02d:%02d", hours, minutes)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(30))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(90))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(3700))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(50000))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(90000))
        ExplosionCountdownBadge(expiresAt: Date().addingTimeInterval(259200))
    }
    .padding()
}
