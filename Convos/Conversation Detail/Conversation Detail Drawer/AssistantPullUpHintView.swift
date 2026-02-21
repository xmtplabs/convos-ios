import SwiftUI

struct AssistantPullUpHintView: View {
    let scrollOverscrollAmount: CGFloat
    let onRequestAssistant: () -> Void
    let onDismiss: () -> Void

    private var pullUp: CGFloat {
        max(0.0, scrollOverscrollAmount)
    }

    private var isAtThreshold: Bool {
        pullUp >= Constant.triggerThreshold
    }

    @State private var wasAtThreshold: Bool = false

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "chevron.up")
                .foregroundStyle(.colorTextTertiary)
                .opacity(isAtThreshold ? 0.0 : 1.0)
                .scaleEffect(isAtThreshold ? 0.5 : 1.0)

            Text(isAtThreshold ? "Release to add Assistant" : "Pull up to add an Assistant")
                .foregroundStyle(.colorTextSecondary)
                .contentTransition(.interpolate)
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .offset(y: -pullUp * Constant.liftMultiplier)
        .contentShape(.rect)
        .onTapGesture {
            onDismiss()
        }
        .onChange(of: isAtThreshold) { _, atThreshold in
            if atThreshold {
                wasAtThreshold = true
            }
        }
        .onChange(of: scrollOverscrollAmount) { _, newValue in
            if newValue <= 0, wasAtThreshold {
                wasAtThreshold = false
                onRequestAssistant()
            } else if newValue > 0, !isAtThreshold {
                wasAtThreshold = false
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: pullUp)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: isAtThreshold)
    }

    private enum Constant {
        static let triggerThreshold: CGFloat = 150.0
        static let liftMultiplier: CGFloat = 0.3
    }
}

struct AssistantRequestedView: View {
    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "checkmark")
                .foregroundStyle(.colorTextTertiary)

            Text("Assistant requested")
                .foregroundStyle(.colorTextSecondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Pull Up Hint") {
    @Previewable @State var overscroll: CGFloat = 0.0

    VStack {
        Spacer()
        Slider(value: $overscroll, in: 0...200.0)
            .padding()
        AssistantPullUpHintView(
            scrollOverscrollAmount: overscroll,
            onRequestAssistant: {},
            onDismiss: {}
        )
        .padding()
    }
}

#Preview("Assistant Requested") {
    AssistantRequestedView()
        .padding()
}
