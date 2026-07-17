#if canImport(UIKit)
import SwiftUI

/// A reusable pulsing circle animation component that can be configured for various use cases
public struct PulsingCircleView: View {
    /// Configuration for the pulsing circles
    public struct Configuration {
        /// Number of circles to display
        public let count: Int
        /// Size of each circle
        public let size: CGFloat
        /// Color of the circles
        public let color: Color
        /// Spacing between circles (ignored if count is 1)
        public let spacing: CGFloat
        /// Duration of one complete animation cycle
        public let animationDuration: Double
        /// Layout axis for multiple circles
        public let axis: Axis
        /// Scale range for the animation
        public let scaleRange: ClosedRange<CGFloat>
        /// Opacity range for the animation
        public let opacityRange: ClosedRange<Double>

        public init(
            count: Int = 1,
            size: CGFloat = 10,
            color: Color = .gray,
            spacing: CGFloat = 6,
            animationDuration: Double = 0.6,
            axis: Axis = .horizontal,
            scaleRange: ClosedRange<CGFloat> = 0.5...1.0,
            opacityRange: ClosedRange<Double> = 0.3...1.0
        ) {
            self.count = count
            self.size = size
            self.color = color
            self.spacing = spacing
            self.animationDuration = animationDuration
            self.axis = axis
            self.scaleRange = scaleRange
            self.opacityRange = opacityRange
        }

        /// Default configuration for a typing indicator
        public static var typingIndicator: Configuration {
            Configuration(
                count: 3,
                size: 10,
                color: .gray,
                spacing: 6,
                animationDuration: 0.6
            )
        }

        /// Default configuration for the thinking indicator's single steady
        /// pulsing dot. Slower and more opacity-driven than the typing
        /// indicator's three-dot dance — the goal is "agent is working on
        /// this" rather than "imminent reply".
        public static var thinkingIndicator: Configuration {
            Configuration(
                count: 1,
                size: 10,
                color: .gray,
                animationDuration: 1.2,
                scaleRange: 0.9...1.0,
                opacityRange: 0.4...1.0
            )
        }

        /// Default configuration for a single loading indicator
        public static var loadingIndicator: Configuration {
            Configuration(
                count: 1,
                size: 20,
                color: .colorFillTertiary,
                animationDuration: 1.0,
                scaleRange: 0.8...1.2,
                opacityRange: 0.5...1.0
            )
        }

        /// Default configuration for a progress indicator
        public static var progressIndicator: Configuration {
            Configuration(
                count: 5,
                size: 8,
                color: .colorFillTertiary,
                spacing: 4,
                animationDuration: 0.8,
                axis: .horizontal
            )
        }
    }

    public let configuration: Configuration
    @State private var animate: Bool = false

    /// Initialize with a custom configuration
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Initialize with preset configurations
    public init(_ preset: Configuration = .typingIndicator) {
        self.configuration = preset
    }

    public var body: some View {
        Group {
            if configuration.count == 1 {
                // Single circle
                Circle()
                    .fill(configuration.color)
                    .frame(width: configuration.size, height: configuration.size)
                    .scaleEffect(
                        animate
                            ? configuration.scaleRange.upperBound
                            : configuration.scaleRange.lowerBound
                    )
                    .opacity(
                        animate
                            ? configuration.opacityRange.upperBound
                            : configuration.opacityRange.lowerBound
                    )
                    .animation(
                        Animation
                            .easeInOut(duration: configuration.animationDuration)
                            .repeatForever(autoreverses: true),
                        value: animate
                    )
            } else {
                // Multiple circles
                if configuration.axis == .horizontal {
                    HStack(spacing: configuration.spacing) {
                        circlesContent
                    }
                } else {
                    VStack(spacing: configuration.spacing) {
                        circlesContent
                    }
                }
            }
        }
        .onAppear {
            animate = true
        }
        .onDisappear {
            animate = false
        }
    }

    @ViewBuilder
    private var circlesContent: some View {
        ForEach(0..<configuration.count, id: \.self) { index in
            Circle()
                .fill(configuration.color)
                .frame(width: configuration.size, height: configuration.size)
                .scaleEffect(
                    animate
                        ? configuration.scaleRange.upperBound
                        : configuration.scaleRange.lowerBound
                )
                .opacity(
                    animate
                        ? configuration.opacityRange.upperBound
                        : configuration.opacityRange.lowerBound
                )
                .animation(
                    Animation
                        .easeInOut(duration: configuration.animationDuration)
                        .repeatForever()
                        .delay(Double(index) * configuration.animationDuration / Double(configuration.count)),
                    value: animate
                )
        }
    }
}

// MARK: - Convenience Initializers

public extension PulsingCircleView {
    /// Create a typing indicator with default settings
    public static var typingIndicator: PulsingCircleView {
        PulsingCircleView(.typingIndicator)
    }

    /// Create a thinking indicator (single steady pulsing dot) with default settings
    public static var thinkingIndicator: PulsingCircleView {
        PulsingCircleView(.thinkingIndicator)
    }

    /// Create a loading indicator with default settings
    public static var loadingIndicator: PulsingCircleView {
        PulsingCircleView(.loadingIndicator)
    }

    /// Create a progress indicator with default settings
    public static var progressIndicator: PulsingCircleView {
        PulsingCircleView(.progressIndicator)
    }
}

// MARK: - Preview

#Preview("Typing Indicator") {
    PulsingCircleView.typingIndicator
        .padding()
}

#Preview("Loading Indicator") {
    PulsingCircleView.loadingIndicator
        .padding()
}

#Preview("Progress Indicator") {
    PulsingCircleView.progressIndicator
        .padding()
}

#Preview("Custom Vertical") {
    PulsingCircleView(
        configuration: .init(
            count: 4,
            size: 12,
            color: .purple,
            spacing: 8,
            animationDuration: 1.2,
            axis: .vertical,
            scaleRange: 0.3...1.5,
            opacityRange: 0.2...1.0
        )
    )
    .padding()
}

#Preview("All Presets") {
    VStack(spacing: 40) {
        VStack {
            Text("Typing Indicator")
                .font(.caption)
            PulsingCircleView.typingIndicator
        }

        VStack {
            Text("Loading Indicator")
                .font(.caption)
            PulsingCircleView.loadingIndicator
        }

        VStack {
            Text("Progress Indicator")
                .font(.caption)
            PulsingCircleView.progressIndicator
        }
    }
    .padding()
}
#endif
