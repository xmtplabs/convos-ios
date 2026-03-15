import SwiftUI

struct BalloonSwayModifier: ViewModifier {
    var motionManager: DeviceMotionManager = .shared

    func body(content: Content) -> some View {
        content
            .rotationEffect(
                .degrees(motionManager.rollAngle),
                anchor: Constant.circleCenter
            )
            .onAppear {
                motionManager.startUpdates()
            }
            .onDisappear {
                motionManager.stopUpdates()
            }
    }

    private enum Constant {
        static let circleCenter: UnitPoint = .init(x: 0.5, y: 0.4)
    }
}

extension View {
    func balloonSway() -> some View {
        modifier(BalloonSwayModifier())
    }
}
