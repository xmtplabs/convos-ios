import SwiftUI

struct PullToAddAssistantView: View {
    let overscrollAmount: CGFloat
    let didReleasePastThreshold: Bool
    let onTriggered: () -> Void

    @State private var hasPlayedHaptic: Bool = false
    private let hapticGenerator: UIImpactFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    private var adjustedOverscroll: CGFloat {
        max(0.0, overscrollAmount - Constant.deadZone)
    }

    private var progress: CGFloat {
        min(1.0, adjustedOverscroll / Self.activationThreshold)
    }

    private var isPastThreshold: Bool {
        adjustedOverscroll >= Self.activationThreshold
    }

    private var subtitleText: String {
        isPastThreshold ? "Let go to" : "Pull to"
    }

    private var verticalOffset: CGFloat {
        Constant.startOffset * (1.0 - progress)
    }

    private var scaleAmount: CGFloat {
        Constant.startScale + (1.0 - Constant.startScale) * progress
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "chevron.up")
                .font(.system(size: 14))
                .foregroundStyle(.colorTextTertiary)
                .opacity(isPastThreshold ? 0 : 0.4 + 0.6 * progress)
                .animation(.easeInOut(duration: 0.2), value: isPastThreshold)

            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.colorTextTertiary)

            Text("Invite an Assistant")
                .font(.caption)
                .foregroundStyle(.colorTextPrimary)

            ZStack {
                Circle()
                    .fill(isPastThreshold ? .colorCaution : .colorFillPrimary)
                    .frame(width: 32, height: 32)

                Image(systemName: isPastThreshold ? "checkmark" : "plus")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(.easeInOut(duration: 0.2), value: isPastThreshold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .opacity(progress)
        .scaleEffect(scaleAmount)
        .offset(y: verticalOffset)
        .onChange(of: progress) { _, newProgress in
            if newProgress > 0.5, !hasPlayedHaptic {
                hapticGenerator.prepare()
            }
        }
        .onChange(of: isPastThreshold) { _, pastThreshold in
            if pastThreshold, !hasPlayedHaptic {
                hapticGenerator.impactOccurred()
                hasPlayedHaptic = true
            } else if !pastThreshold {
                hasPlayedHaptic = false
            }
        }
        .onChange(of: didReleasePastThreshold) { _, released in
            if released {
                onTriggered()
            }
        }
    }

    static let activationThreshold: CGFloat = 100

    private enum Constant {
        static let deadZone: CGFloat = 75
        static let startOffset: CGFloat = 60
        static let startScale: CGFloat = 0.6
    }
}

#Preview("In Progress") {
    VStack {
        Spacer()
        PullToAddAssistantView(
            overscrollAmount: 50,
            didReleasePastThreshold: false,
            onTriggered: {}
        )
    }
}

#Preview("Threshold Reached") {
    VStack {
        Spacer()
        PullToAddAssistantView(
            overscrollAmount: 100,
            didReleasePastThreshold: false,
            onTriggered: {}
        )
    }
}
