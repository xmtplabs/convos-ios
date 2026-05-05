import ConvosCore
import Foundation
import Observation

/// Observes `SessionStateMachine` and exposes whether the current session
/// has transitioned to the terminal `DeviceReplacedError` state. The
/// `StaleDeviceBanner` reads this and offers the user a reset action.
///
/// The plan collapses the prior vault-era `StaleDeviceState` + per-inbox
/// `isStale` scaffolding into a single terminal session error; this
/// observer is the only surface the UI needs to watch.
@MainActor
@Observable
final class StaleDeviceObserver {
    private(set) var isDeviceReplaced: Bool = false

    @ObservationIgnored private var stateObserver: (any SessionStateObserver)?
    @ObservationIgnored private weak var stateManager: (any SessionStateManagerProtocol)?

    /// Binds the observer to a session's `SessionStateManager`. Safe to
    /// call multiple times — rebinding replaces the prior observation.
    func bind(to stateManager: any SessionStateManagerProtocol) {
        unbind()
        self.stateManager = stateManager
        apply(state: stateManager.currentState)
        let closure = ClosureStateObserver { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.apply(state: state)
            }
        }
        stateManager.addObserver(closure)
        self.stateObserver = closure
    }

    func unbind() {
        if let observer = stateObserver, let manager = stateManager {
            manager.removeObserver(observer)
        }
        stateObserver = nil
        stateManager = nil
    }

    private func apply(state: SessionStateMachine.State) {
        if case let .error(error) = state, error is DeviceReplacedError {
            isDeviceReplaced = true
        } else {
            isDeviceReplaced = false
        }
    }

    deinit {
        if let observer = stateObserver, let manager = stateManager {
            manager.removeObserver(observer)
        }
    }
}
