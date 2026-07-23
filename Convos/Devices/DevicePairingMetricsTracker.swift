import ConvosMetrics
import Foundation

/// Funnels one device-pairing attempt into the device-pairing metrics
/// events: at most one `devicePairingStarted` plus exactly one terminal
/// `devicePairingCompleted` / `devicePairingFailed`, no matter how many
/// code paths can reach each flow state (stream redelivery, resend loops,
/// cancel-after-terminal dismissals).
///
/// Both pairing view models drive it from their `flowState` `didSet`, so
/// step bookkeeping stays correct even for transitions added later; the
/// explicit calls are only `started()` (flow kickoff) and `cancelled()`
/// (user dismissal, which no-ops once a terminal event has fired).
@MainActor
final class DevicePairingMetricsTracker {
    private let role: DevicePairingRole
    private let coreActions: any CoreActions
    private var startedAt: Date?
    private var lastStep: DevicePairingStep
    private var didFinish: Bool = false

    init(role: DevicePairingRole, coreActions: any CoreActions) {
        self.role = role
        self.coreActions = coreActions
        // The step a flow is in before its first tracked transition; only
        // reported if the attempt dies that early.
        self.lastStep = role == .initiator ? .qrDisplayed : .joinRequested
    }

    func started() {
        guard startedAt == nil else { return }
        startedAt = Date()
        let actions = coreActions
        let role = role
        Task { await actions.devicePairingStarted(role: role) }
    }

    func reached(_ step: DevicePairingStep) {
        guard !didFinish else { return }
        lastStep = step
    }

    func completed() {
        guard finishOnce() else { return }
        let actions = coreActions
        let role = role
        let duration = durationSecs
        Task { await actions.devicePairingCompleted(role: role, durationSecs: duration) }
    }

    func failed(_ reason: DevicePairingFailureReason) {
        guard finishOnce() else { return }
        let actions = coreActions
        let role = role
        let step = lastStep
        let duration = durationSecs
        Task { await actions.devicePairingFailed(role: role, reason: reason, step: step, durationSecs: duration) }
    }

    /// User dismissal. Safe to call unconditionally on teardown: it only
    /// emits when the attempt started and hasn't already ended.
    func cancelled() {
        failed(.cancelled)
    }

    /// False when the attempt never started or already emitted its
    /// terminal event.
    private func finishOnce() -> Bool {
        guard !didFinish, startedAt != nil else { return false }
        didFinish = true
        return true
    }

    private var durationSecs: Float {
        guard let startedAt else { return 0 }
        return Float(Date().timeIntervalSince(startedAt))
    }
}
