import ConvosCore
import SwiftUI

struct ExplosionCountdownBadge: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            let isUrgent = remaining <= 24 * 3600
            Text(ExplosionDurationFormatter.compactCountdown(interval: remaining))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isUrgent ? .colorCaution : .colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step2x)
                .padding(.vertical, DesignConstants.Spacing.stepHalf)
                .background(isUrgent ? .colorCaution.opacity(0.15) : .colorFillMinimal)
                .clipShape(Capsule())
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
