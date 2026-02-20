import ConvosCore
import SwiftUI
import UIKit

struct ExplodeInfoRow: View {
    let scheduledExplosionDate: Date?
    let onTap: () -> Void
    let onExplodeNow: () -> Void

    @State private var isPressing: Bool = false
    @State private var isHolding: Bool = false
    @State private var pressStartDate: Date?
    @State private var frozenProgress: Double = 0
    @State private var didFire: Bool = false
    @State private var pressScale: CGFloat = 1.0
    @State private var explosionTrigger: Int = 0
    @State private var hasExploded: Bool = false
    @State private var frozenCountdown: String = ""

    var body: some View {
        if let expiresAt = scheduledExplosionDate {
            scheduledContent(expiresAt: expiresAt)
                .listRowBackground(
                    ZStack {
                        Color(.secondarySystemGroupedBackground)
                        Color.colorCaution
                            .scaleEffect(
                                x: isHolding || didFire ? 1.0 : 0.0,
                                anchor: .leading
                            )
                    }
                    .animation(.easeInOut(duration: 0.25), value: isHolding)
                )
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
        .scaleEffect(pressScale)
        .contentShape(Rectangle())
        .keyframeAnimator(
            initialValue: ExplosionKeyframes(),
            trigger: explosionTrigger
        ) { content, value in
            content
                .scaleEffect(value.scale)
                .offset(x: value.xOffset)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.12, duration: 0.1, spring: .bouncy(duration: 0.1))
                SpringKeyframe(0.96, duration: 0.08)
                SpringKeyframe(1.05, duration: 0.08)
                SpringKeyframe(0.98, duration: 0.06)
                SpringKeyframe(1.0, duration: 0.12)
            }
            KeyframeTrack(\.xOffset) {
                LinearKeyframe(0, duration: 0.06)
                LinearKeyframe(8, duration: 0.035)
                LinearKeyframe(-8, duration: 0.035)
                LinearKeyframe(6, duration: 0.035)
                LinearKeyframe(-6, duration: 0.035)
                LinearKeyframe(4, duration: 0.035)
                LinearKeyframe(-4, duration: 0.035)
                LinearKeyframe(2, duration: 0.025)
                LinearKeyframe(-2, duration: 0.025)
                LinearKeyframe(0, duration: 0.02)
            }
        }
        .onLongPressGesture(
            minimumDuration: Constant.holdDuration,
            maximumDistance: Constant.maxDistance,
            perform: {
                guard !didFire else { return }
                didFire = true
                frozenProgress = 1.0
                pressStartDate = nil
                frozenCountdown = ExplosionDurationFormatter.countdown(
                    until: expiresAt, from: Date()
                )
                triggerExplosion()
            },
            onPressingChanged: { pressing in
                isPressing = pressing
                if pressing {
                    didFire = false
                    hasExploded = false
                    pressStartDate = Date()
                    frozenProgress = 0
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHolding = true
                    }
                    withAnimation(.spring(response: 0.08, dampingFraction: 0.5)) {
                        pressScale = 0.97
                    }
                    withAnimation(.spring(response: 0.15, dampingFraction: 0.7).delay(0.08)) {
                        pressScale = 1.0
                    }
                } else if !didFire {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isHolding = false
                        frozenProgress = 0
                    }
                    pressStartDate = nil
                    withAnimation(.spring(response: 0.12, dampingFraction: 0.6)) {
                        pressScale = 1.0
                    }
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

            let displayCountdown = hasExploded ? frozenCountdown : countdownText

            HStack(spacing: DesignConstants.Spacing.step2x) {
                iconArea(holdProgress: holdProgress)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text("Exploding in \(displayCountdown)")
                        .font(.body)
                        .foregroundStyle(isHolding || hasExploded ? .white : .colorCaution)
                        .opacity(hasExploded ? 0 : 1)
                        .overlay(alignment: .leading) {
                            if didFire {
                                ShatteringText(
                                    text: "Exploding in \(frozenCountdown)",
                                    isExploded: hasExploded,
                                    config: Constant.shatterConfig
                                )
                                .font(.body)
                                .foregroundStyle(.white)
                            }
                        }

                    Text("Hold to explode now")
                        .font(.footnote)
                        .foregroundStyle(isHolding ? .white.opacity(0.7) : .colorTextSecondary)
                        .opacity(hasExploded ? 0 : 1)
                        .animation(.easeOut(duration: 0.2), value: hasExploded)
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func iconArea(holdProgress: Double) -> some View {
        ZStack {
            Image(systemName: "burst")
                .font(.body)
                .foregroundStyle(.white)
                .scaleEffect(isHolding ? 0.4 : 1.0)
                .opacity(isHolding ? 0 : 1)

            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 1.0)
                .overlay(
                    Circle()
                        .fill(.white)
                        .scaleEffect(holdProgress)
                )
                .padding(DesignConstants.Spacing.step2x)
                .opacity(isHolding && !hasExploded ? 1 : 0)

            Circle()
                .fill(.white.opacity(0.8))
                .padding(DesignConstants.Spacing.step2x)
                .scaleEffect(hasExploded ? 5.0 : 1.0)
                .opacity(hasExploded ? 0 : (didFire ? 0.8 : 0))
                .animation(.easeOut(duration: 0.4), value: hasExploded)

            Circle()
                .stroke(.white, lineWidth: 2)
                .padding(DesignConstants.Spacing.step2x)
                .scaleEffect(hasExploded ? 6.0 : 1.0)
                .opacity(hasExploded ? 0 : (didFire ? 0.6 : 0))
                .animation(.easeOut(duration: 0.5), value: hasExploded)
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
    }

    private func triggerExplosion() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        explosionTrigger += 1
        onExplodeNow()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.easeOut(duration: 0.4)) {
                hasExploded = true
            }
        }
    }

    private struct ExplosionKeyframes {
        var scale: CGFloat = 1.0
        var xOffset: CGFloat = 0
    }

    private enum Constant {
        static let holdDuration: TimeInterval = 1.5
        static let maxDistance: CGFloat = 20.0

        static let shatterConfig: ShatteringTextAnimationConfig = .init(
            letterHorizontalRange: 30...60,
            letterVerticalRange: 20...45,
            letterRotationRange: 25...70,
            letterScaleRange: 1.2...2.5,
            letterBlurRadius: 1.5,
            letterAnimationResponse: 0.45,
            letterAnimationDamping: 0.5,
            letterStaggerDelay: 0.015
        )
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
