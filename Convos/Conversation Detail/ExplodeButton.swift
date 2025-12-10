import SwiftUI
import UIKit

// MARK: - Hold To Confirm Button Style

struct HoldToConfirmStyleConfig {
    // Timing
    var duration: TimeInterval = 2.0
    var maxDistance: CGFloat = 20.0

    // Colors
    var backgroundColor: Color = .colorOrange
    var pressedOverlayColor: Color = .black
    var pressedOverlayOpacity: Double = 0.15
    var progressIndicatorColor: Color = .white
    var progressIndicatorStrokeColor: Color = .white.opacity(0.3)

    // Layout
    var verticalPadding: CGFloat = DesignConstants.Spacing.step4x
    var horizontalPadding: CGFloat = DesignConstants.Spacing.step3x
    var progressIndicatorPadding: CGFloat = DesignConstants.Spacing.step3x
    var progressIndicatorStrokeWidth: CGFloat = 1.0

    // Progress indicator
    var showProgressIndicator: Bool = true

    static let `default`: HoldToConfirmStyleConfig = .init()
}

struct HoldToConfirmPrimitiveStyle: PrimitiveButtonStyle {
    var config: HoldToConfirmStyleConfig = .default

    // Convenience initializer for just duration
    init(duration: TimeInterval) {
        self.config = HoldToConfirmStyleConfig(duration: duration)
    }

    init(config: HoldToConfirmStyleConfig = .default) {
        self.config = config
    }

    @Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoldToConfirmBody(
            config: config,
            isEnabled: isEnabled,
            trigger: configuration.trigger,
            label: { configuration.label }
        )
    }

    private struct HoldToConfirmBody<Label: View>: View {
        let config: HoldToConfirmStyleConfig
        let isEnabled: Bool
        let trigger: () -> Void
        @ViewBuilder var label: () -> Label

        @State private var isPressing: Bool = false
        @State private var pressStartDate: Date?
        @State private var didFire: Bool = false
        @State private var frozenProgress: Double = 0

        var body: some View {
            TimelineView(.animation(paused: !isPressing)) { context in
                let currentProgress: Double = {
                    if let start = pressStartDate {
                        return min(1.0, context.date.timeIntervalSince(start) / config.duration)
                    }
                    return frozenProgress
                }()

                label()
                    .padding(.vertical, config.verticalPadding)
                    .background(
                        Capsule()
                            .fill(config.backgroundColor)
                            .overlay(
                                config.pressedOverlayColor
                                    .opacity(currentProgress > 0.0 ? config.pressedOverlayOpacity : 0.0),
                                in: Capsule()
                            )
                    )
                    .overlay(alignment: .leading) {
                        if config.showProgressIndicator {
                            HStack {
                                Circle()
                                    .stroke(config.progressIndicatorStrokeColor, lineWidth: config.progressIndicatorStrokeWidth)
                                    .overlay(
                                        Circle()
                                            .fill(config.progressIndicatorColor)
                                            .scaleEffect(currentProgress)
                                    )
                                Spacer()
                            }
                            .padding(config.progressIndicatorPadding)
                            .opacity(isEnabled && currentProgress > 0.0 ? 1.0 : 0.0)
                        }
                    }
            }
            .onLongPressGesture(
                minimumDuration: config.duration,
                maximumDistance: config.maxDistance,
                perform: {
                    guard !didFire else { return }
                    didFire = true
                    frozenProgress = 1.0
                    pressStartDate = nil
                    trigger()
                },
                onPressingChanged: { pressing in
                    isPressing = pressing
                    if pressing {
                        didFire = false
                        pressStartDate = Date()
                        frozenProgress = 0
                    } else if !didFire {
                        // Released early - animate back to zero
                        withAnimation(.easeOut(duration: 0.18)) {
                            frozenProgress = 0
                        }
                        pressStartDate = nil
                    }
                }
            )
        }
    }
}

// MARK: - Explode State

enum ExplodeState: Equatable {
    case ready
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

    static var explodedAnimationDelay: CGFloat = 0.7
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

    // Text shatter
    var letterHorizontalRange: ClosedRange<Double> = 25...50
    var letterVerticalRange: ClosedRange<Double> = 15...35
    var letterRotationRange: ClosedRange<Double> = 15...45
    var letterScaleRange: ClosedRange<Double> = 2.0...5.0
    var letterBlurRadius: CGFloat = 5
    var letterAnimationResponse: Double = 0.7
    var letterAnimationDamping: Double = 0.3
    var letterStaggerDelay: Double = 0.03

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

// MARK: - Shattering Text

struct ShatteringText: View {
    let text: String
    let isExploded: Bool
    var config: ExplodeButtonAnimationConfig = .default

    @State private var letterOffsets: [CGSize] = []
    @State private var letterRotations: [Double] = []
    @State private var letterScales: [Double] = []

    var body: some View {
        ZStack {
            // Regular text when not exploded
            Text(text)
                .opacity(isExploded ? 0 : 1)
                .animation(.easeOut(duration: 0.1), value: isExploded)

            // Shattered letters
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                    Text(String(character))
                        .offset(isExploded && index < letterOffsets.count ? letterOffsets[index] : .zero)
                        .rotationEffect(.degrees(isExploded && index < letterRotations.count ? letterRotations[index] : 0))
                        .scaleEffect(isExploded && index < letterScales.count ? letterScales[index] : 1)
                        .blur(radius: isExploded ? config.letterBlurRadius : 0)
                        .opacity(isExploded ? 0.0 : 1.0)
                        .animation(
                            isExploded
                            ? .spring(response: config.letterAnimationResponse, dampingFraction: config.letterAnimationDamping)
                                .delay(Double(index) * config.letterStaggerDelay)
                            : .none,
                            value: isExploded
                        )
                }
            }
            .opacity(isExploded ? 1.0 : 0.0)
            .animation(.none, value: isExploded)
        }
        .onAppear { generateRandomValues() }
    }

    private func generateRandomValues() {
        let letterCount = text.count
        let centerIndex = Double(letterCount - 1) / 2.0

        // swiftlint:disable:next unused_enumerated
        letterOffsets = text.enumerated().map { i, _ in
            // Calculate position relative to center: -1 (leftmost) to +1 (rightmost)
            let normalizedPosition = centerIndex > 0
            ? (Double(i) - centerIndex) / centerIndex
            : 0

            // Horizontal: letters fly outward from center
            let horizontalDistance = normalizedPosition * Double.random(in: config.letterHorizontalRange)

            // Vertical: alternate up/down based on odd/even index
            let verticalDirection = i.isMultiple(of: 2) ? -1.0 : 1.0
            let verticalDistance = verticalDirection * Double.random(in: config.letterVerticalRange)

            return CGSize(width: horizontalDistance, height: verticalDistance)
        }

        // swiftlint:disable:next unused_enumerated
        letterRotations = text.enumerated().map { i, _ in
            let centerIndex = Double(text.count - 1) / 2.0
            let direction = Double(i) < centerIndex ? -1.0 : 1.0
            return direction * Double.random(in: config.letterRotationRange)
        }

        letterScales = text.map { _ in
            Double.random(in: config.letterScaleRange)
        }
    }
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

    @State private var iconRotation: Double = 0
    @State private var buttonScale: CGFloat = 1.0

    // MARK: - Computed Properties

    private var displayText: String {
        switch state {
        case .ready:
            return readyText
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

    // MARK: - Body

    var body: some View {
        Button {
            onExplode()
        } label: {
            buttonContent
        }
        .disabled(!state.isReady)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: config.buttonStyle))
        .scaleEffect(buttonScale)
        .onChange(of: state) { _, newValue in
            handleStateChange(newValue)
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
        // Main icon
        Image("explodeIcon")
            .rotationEffect(.degrees(iconRotation))
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
            case .exploding, .exploded:
                ShatteringText(
                    text: explodingText,
                    isExploded: shouldShatter,
                    config: config
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
        case .error:
            handleErrorState()
        }
    }

    private func handleExplodingState() {
        UIImpactFeedbackGenerator(style: config.explodingHapticStyle).impactOccurred()
        // Sync icon spin with hold duration
        let spinDuration = config.iconSpinDuration > 0 ? config.iconSpinDuration : config.buttonStyle.duration
        withAnimation(.linear(duration: spinDuration)) {
            iconRotation = 360
        }
    }

    private func handleExplodedState() {
        UIImpactFeedbackGenerator(style: config.explodedHapticStyle).impactOccurred()
        iconRotation = 0

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
        withAnimation(.easeOut(duration: 0.3)) {
            iconRotation = 0
        }
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
