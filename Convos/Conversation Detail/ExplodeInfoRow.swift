import ConvosCore
import SwiftUI

struct ExplodeInfoRow: View {
    let scheduledExplosionDate: Date?
    let onTap: () -> Void
    let onExplodeNow: () -> Void

    @State private var isPressing: Bool = false
    @State private var isHolding: Bool = false
    @State private var pressStartDate: Date?
    @State private var frozenProgress: Double = 0
    @State private var didFire: Bool = false

    var body: some View {
        if let expiresAt = scheduledExplosionDate {
            scheduledContent(expiresAt: expiresAt)
                .listRowBackground(isHolding ? Color.colorCaution : nil)
        } else {
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        let action = { onTap() }
        Button(action: action) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "burst")
                    .font(.body)
                    .foregroundStyle(.colorCaution)
                    .frame(
                        width: DesignConstants.Spacing.step10x,
                        height: DesignConstants.Spacing.step10x
                    )
                    .background(
                        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                            .fill(Color.colorCaution.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text("Explode")
                        .font(.body)
                        .foregroundStyle(.colorCaution)

                    Text("Destroy all messages and members")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func scheduledContent(expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { clockContext in
            let countdownText = ExplosionDurationFormatter.countdown(
                until: expiresAt, from: clockContext.date
            )
            holdableRow(countdownText: countdownText)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: Constant.holdDuration,
            maximumDistance: Constant.maxDistance,
            perform: {
                guard !didFire else { return }
                didFire = true
                frozenProgress = 1.0
                pressStartDate = nil
                onExplodeNow()
            },
            onPressingChanged: { pressing in
                isPressing = pressing
                if pressing {
                    didFire = false
                    pressStartDate = Date()
                    frozenProgress = 0
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHolding = true
                    }
                } else if !didFire {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isHolding = false
                        frozenProgress = 0
                    }
                    pressStartDate = nil
                }
            }
        )
    }

    @ViewBuilder
    private func holdableRow(countdownText: String) -> some View {
        TimelineView(.animation(paused: !isPressing)) { context in
            let holdProgress: Double = {
                if let start = pressStartDate {
                    return min(1.0, context.date.timeIntervalSince(start) / Constant.holdDuration)
                }
                return frozenProgress
            }()

            HStack(spacing: DesignConstants.Spacing.step2x) {
                ZStack {
                    Image(systemName: "burst")
                        .font(.body)
                        .foregroundStyle(.white)
                        .opacity(isHolding ? 0 : 1)

                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1.0)
                        .overlay(
                            Circle()
                                .fill(.white)
                                .scaleEffect(holdProgress)
                        )
                        .padding(DesignConstants.Spacing.step2x)
                        .opacity(isHolding ? 1 : 0)
                }
                .frame(
                    width: DesignConstants.Spacing.step10x,
                    height: DesignConstants.Spacing.step10x
                )
                .background(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
                        .fill(Color.colorCaution)
                        .opacity(isHolding ? 0 : 1)
                )

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(isHolding ? countdownText : "Exploding in \(countdownText)")
                        .font(isHolding ? .body.monospacedDigit() : .body)
                        .foregroundStyle(isHolding ? .white : .colorCaution)

                    Text("Hold to explode now")
                        .font(.footnote)
                        .foregroundStyle(isHolding ? .white.opacity(0.7) : .colorTextSecondary)
                }

                Spacer()
            }
        }
    }

    private enum Constant {
        static let holdDuration: TimeInterval = 1.5
        static let maxDistance: CGFloat = 20.0
    }
}

#Preview("Ready") {
    List {
        Section {
            ExplodeInfoRow(
                scheduledExplosionDate: nil,
                onTap: {},
                onExplodeNow: {}
            )
        }
    }
}

#Preview("Scheduled") {
    List {
        Section {
            ExplodeInfoRow(
                scheduledExplosionDate: Date().addingTimeInterval(3600),
                onTap: {},
                onExplodeNow: {}
            )
        }
    }
}
