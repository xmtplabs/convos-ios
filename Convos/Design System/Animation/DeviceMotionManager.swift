import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class DeviceMotionManager {
    static let shared: DeviceMotionManager = .init()

    private(set) var rollAngle: Double = 0.0

    private let motionManager: CMMotionManager = .init()
    private var activeListenerCount: Int = 0
    private var idleSwayPhase: Double = 0.0
    private var idleSwayTimer: Timer?

    private var isDeviceMotionAvailable: Bool { motionManager.isDeviceMotionAvailable }

    private init() {}

    func startUpdates() {
        activeListenerCount += 1
        guard activeListenerCount == 1 else { return }

        #if targetEnvironment(simulator)
        startIdleSway()
        #else
        if isDeviceMotionAvailable {
            stopIdleSway()
            startDeviceMotion()
        } else {
            startIdleSway()
        }
        #endif
    }

    func stopUpdates() {
        activeListenerCount -= 1
        guard activeListenerCount <= 0 else { return }
        activeListenerCount = 0

        motionManager.stopDeviceMotionUpdates()
        startIdleSway()
    }

    private func startDeviceMotion() {
        motionManager.deviceMotionUpdateInterval = Constant.updateInterval
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            Task { @MainActor [weak self] in
                guard let self, let gravity = motion?.gravity else { return }
                let rawAngle: Double = asin(max(-1, min(1, gravity.x))) * (180.0 / .pi)
                let clamped: Double = max(-Constant.maxAngle, min(Constant.maxAngle, rawAngle))
                self.rollAngle = self.rollAngle * (1 - Constant.smoothingFactor) + clamped * Constant.smoothingFactor
            }
        }
    }

    private func startIdleSway() {
        guard idleSwayTimer == nil else { return }
        idleSwayTimer = Timer.scheduledTimer(withTimeInterval: Constant.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.idleSwayPhase += Constant.idleSwaySpeed
                self.rollAngle = sin(self.idleSwayPhase) * Constant.idleSwayPrimaryAmplitude
                    + sin(self.idleSwayPhase * 0.7) * Constant.idleSwaySecondaryAmplitude
            }
        }
    }

    private func stopIdleSway() {
        idleSwayTimer?.invalidate()
        idleSwayTimer = nil
    }

    private enum Constant {
        static let updateInterval: TimeInterval = 1.0 / 30.0
        static let maxAngle: Double = 30.0
        static let smoothingFactor: Double = 0.12
        static let idleSwaySpeed: Double = 0.03
        static let idleSwayPrimaryAmplitude: Double = 20.0
        static let idleSwaySecondaryAmplitude: Double = 10.0
    }
}
