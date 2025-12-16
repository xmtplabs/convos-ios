import SwiftUI

// MARK: - Shattering Text Animation Config

struct ShatteringTextAnimationConfig {
    var letterHorizontalRange: ClosedRange<Double> = 25...50
    var letterVerticalRange: ClosedRange<Double> = 15...35
    var letterRotationRange: ClosedRange<Double> = 15...45
    var letterScaleRange: ClosedRange<Double> = 2.0...5.0
    var letterBlurRadius: CGFloat = 5
    var letterAnimationResponse: Double = 0.7
    var letterAnimationDamping: Double = 0.3
    var letterStaggerDelay: Double = 0.03

    static let `default`: ShatteringTextAnimationConfig = .init()
}

// MARK: - Shattering Text

struct ShatteringText: View {
    let text: String
    let isExploded: Bool
    var config: ShatteringTextAnimationConfig = .default

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
                    let delay = Double(index) * config.letterStaggerDelay
                    let springAnimation = Animation
                        .spring(response: config.letterAnimationResponse, dampingFraction: config.letterAnimationDamping)
                        .delay(delay)
                    // Use easeOut for opacity to prevent bounce-back visibility
                    let opacityAnimation = Animation
                        .easeOut(duration: config.letterAnimationResponse * 0.6)
                        .delay(delay)

                    Text(String(character))
                        .offset(isExploded && index < letterOffsets.count ? letterOffsets[index] : .zero)
                        .rotationEffect(.degrees(isExploded && index < letterRotations.count ? letterRotations[index] : 0))
                        .scaleEffect(isExploded && index < letterScales.count ? letterScales[index] : 1)
                        .blur(radius: isExploded ? config.letterBlurRadius : 0)
                        .animation(isExploded ? springAnimation : .none, value: isExploded)
                        .opacity(isExploded ? 0.0 : 1.0)
                        .animation(isExploded ? opacityAnimation : .none, value: isExploded)
                }
            }
            .opacity(isExploded ? 1.0 : 0.0)
            .animation(.none, value: isExploded)
        }
        .task(id: text) { generateRandomValues() }
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

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var isExploded: Bool = false

        var body: some View {
            VStack(spacing: DesignConstants.Spacing.step5x) {
                ShatteringText(text: "Exploding...", isExploded: isExploded)
                    .font(.headline)

                Button(isExploded ? "Reset" : "Shatter") {
                    isExploded.toggle()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(44)
        }
    }

    return PreviewWrapper()
}
