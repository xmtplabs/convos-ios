#if canImport(UIKit)
import ConvosCore
import SwiftUI

public struct ExplosionCountdownBadge: View {
    let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    public var body: some View {
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
#endif
