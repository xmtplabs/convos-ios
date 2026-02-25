import ConvosCore
import SwiftUI
import UIKit

// MARK: - Explode State

enum ExplodeState: Equatable {
    case ready
    case scheduled(Date)
    case exploding
    case exploded
    case error(String)

    var explodingOrExploded: Bool {
        switch self {
        case .exploded, .exploding:
            return true
        default:
            return false
        }
    }

    var isExploded: Bool { self == .exploded }
    var isReady: Bool { self == .ready }
    var isExploding: Bool { self == .exploding }
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
    var isScheduled: Bool {
        if case .scheduled = self { return true }
        return false
    }

    var scheduledDate: Date? {
        if case .scheduled(let date) = self { return date }
        return nil
    }

    static let explodedAnimationDelay: CGFloat = 0.7
}

// MARK: - Animation Configuration

struct ExplodeButtonAnimationConfig {
    // Button style
    var buttonStyle: HoldToConfirmStyleConfig = .default

    // Icon animation
    var iconSpinDuration: TimeInterval = 1.5
    var iconExplodeScale: CGFloat = 2.5
    var iconExplodeBlur: CGFloat = 12
    var iconPulseScale: CGFloat = 1.1

    // Button ripple
    var rippleScale: CGFloat = 1.12
    var rippleResponse: Double = 0.15
    var rippleDamping: Double = 0.3
    var rippleSettleResponse: Double = 0.4
    var rippleSettleDamping: Double = 0.4

    // Text shatter config
    var shatteringTextConfig: ShatteringTextAnimationConfig = .default

    // Haptics
    var explodingHapticStyle: UIImpactFeedbackGenerator.FeedbackStyle = .light
    var explodedHapticStyle: UIImpactFeedbackGenerator.FeedbackStyle = .heavy

    static let `default`: ExplodeButtonAnimationConfig = {
        var config = ExplodeButtonAnimationConfig()
        config.buttonStyle.duration = 1.5
        config.buttonStyle.backgroundColor = .colorOrange
        return config
    }()
}

// MARK: - Explode Button

struct ExplodeButton: View {
    // MARK: - Properties

    let state: ExplodeState
    var config: ExplodeButtonAnimationConfig = .default
    var readyText: String = "Hold to Explode"
    var explodingText: String = "Exploding..."
    var onExplode: () -> Void

    // MARK: - Private State

    @State private var isBouncing: Bool = false
    @State private var buttonScale: CGFloat = 1.0

    // MARK: - Computed Properties

    private var displayText: String {
        switch state {
        case .ready:
            return readyText
        case .scheduled:
            return "Scheduled"
        case .exploding, .exploded:
            return explodingText
        case .error(let message):
            return message
        }
    }

    private var shouldShatter: Bool {
        state.isExploded
    }

    private var showIconView: Bool {
        switch state {
        case .error:
            return false
        default:
            return true
        }
    }

    private var explodeAccessibilityLabel: String {
        switch state {
        case .ready:
            return readyText
        case .scheduled:
            return "Scheduled to explode"
        case .exploding:
            return explodingText
        case .exploded:
            return "Conversation exploded"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if case .scheduled(let date) = state {
                scheduledContent(expiresAt: date)
            } else {
                Button {
                    onExplode()
                } label: {
                    buttonContent
                }
                .disabled(!state.isReady)
                .buttonStyle(HoldToConfirmPrimitiveStyle(config: config.buttonStyle))
            }
        }
        .scaleEffect(buttonScale)
        .onChange(of: state) { _, newValue in
            handleStateChange(newValue)
        }
        .accessibilityLabel(explodeAccessibilityLabel)
        .accessibilityHint(state.isReady ? "Hold to confirm" : "")
        .accessibilityIdentifier("explode-button")
    }

    @ViewBuilder
    private func scheduledContent(expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let isExpired = context.date >= expiresAt
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "burst")
                Text(isExpired ? "Exploding..." : "Explodes in \(ExplosionDurationFormatter.countdown(until: expiresAt, from: context.date))")
            }
            .foregroundStyle(.colorOrange)
            .font(.subheadline.weight(.medium))
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .frame(maxWidth: .infinity)
            .background(Color.colorOrange.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    // MARK: - Subviews

    private var buttonContent: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if showIconView {
                iconView
            }
            textView
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private var iconView: some View {
        Image(systemName: "burst")
            .symbolEffect(.bounce.up.byLayer, options: .repeat(.periodic(delay: 0.0)), value: isBouncing)
            .scaleEffect(iconScale)
            .blur(radius: state.isExploded ? config.iconExplodeBlur : 0)
            .opacity(state.isExploded ? 0 : 1)
            .animation(
                state.isExploded
                ? .easeOut(duration: 0.6)
                : .spring(response: 0.3, dampingFraction: 0.5),
                value: state
            )
    }

    private var textView: some View {
        ZStack {
            switch state {
            case .ready:
                Text(readyText)
                    .transition(.scale.combined(with: .opacity))
            case .scheduled:
                EmptyView()
            case .exploding, .exploded:
                ShatteringText(
                    text: explodingText,
                    isExploded: shouldShatter,
                    config: config.shatteringTextConfig
                )
                .transition(.scale.combined(with: .opacity))
            case .error(let message):
                Text(message)
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    // MARK: - Computed Animation Values

    private var iconScale: CGFloat {
        switch state {
        case .exploding: return config.iconPulseScale
        case .exploded: return config.iconExplodeScale
        default: return 1.0
        }
    }

    // MARK: - State Handling

    private func handleStateChange(_ newState: ExplodeState) {
        switch newState {
        case .exploding:
            handleExplodingState()
        case .exploded:
            handleExplodedState()
        case .ready:
            handleReadyState()
        case .scheduled:
            handleReadyState()
        case .error:
            handleErrorState()
        }
    }

    private func handleExplodingState() {
        UIImpactFeedbackGenerator(style: config.explodingHapticStyle).impactOccurred()
        isBouncing = true
    }

    private func handleExplodedState() {
        UIImpactFeedbackGenerator(style: config.explodedHapticStyle).impactOccurred()
        isBouncing = false

        // Ripple effect
        withAnimation(.spring(response: config.rippleResponse, dampingFraction: config.rippleDamping)) {
            buttonScale = config.rippleScale
        }

        withAnimation(
            .spring(response: config.rippleSettleResponse, dampingFraction: config.rippleSettleDamping)
            .delay(config.rippleResponse)
        ) {
            buttonScale = 1.0
        }
    }

    private func handleReadyState() {
        isBouncing = false
        buttonScale = 1.0
    }

    private func handleErrorState() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)

        // Shake animation
        withAnimation(.spring(response: 0.1, dampingFraction: 0.3)) {
            buttonScale = 0.95
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.1)) {
            buttonScale = 1.0
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var explodeState: ExplodeState = .ready

        var body: some View {
            VStack(spacing: DesignConstants.Spacing.step5x) {
                ExplodeButton(state: explodeState) {
                    explode()
                }

                // Debug buttons
                HStack {
                    Button("Ready") { explodeState = .ready }
                    Button("Error") { explodeState = .error("Something went wrong") }
                }
                .font(.caption)
            }
            .padding(44)
        }

        func explode() {
            explodeState = .exploding

            Task {
                try? await Task.sleep(for: .seconds(0.5))
                explodeState = .exploded
                try? await Task.sleep(for: .seconds(2.0))
                explodeState = .ready
            }
        }
    }

    return PreviewWrapper()
}
