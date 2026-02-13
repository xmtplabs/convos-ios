import SwiftUI

// MARK: - Hold To Confirm Style Config

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

    // Shape
    var cornerRadius: CGFloat?

    // Progress indicator
    var showProgressIndicator: Bool = true

    static let `default`: HoldToConfirmStyleConfig = .init()
}

// MARK: - Hold To Confirm Primitive Style

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

                let shape = RoundedRectangle(cornerRadius: config.cornerRadius ?? 999)
                label()
                    .padding(.vertical, config.verticalPadding)
                    .background(
                        shape
                            .fill(config.backgroundColor)
                            .overlay(
                                config.pressedOverlayColor
                                    .opacity(currentProgress > 0.0 ? config.pressedOverlayOpacity : 0.0),
                                in: shape
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
            .sensoryFeedback(.impact(weight: .light), trigger: isPressing) { _, newValue in
                newValue
            }
            .sensoryFeedback(.success, trigger: didFire) { _, newValue in
                newValue
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
