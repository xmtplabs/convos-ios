import ConvosCore
import Foundation
import Observation

/// Observes `SessionStateMachine` and exposes whether the session has
/// transitioned to the terminal `DeviceReplacedError` state — i.e. another
/// paired device has revoked this installation from its `Devices` screen.
///
/// `StaleDeviceBanner` reads `isDeviceRemoved` and offers the user a
/// single way forward: reset and re-onboard.
@MainActor
@Observable
final class StaleDeviceObserver {
    private(set) var isDeviceRemoved: Bool = false

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

    /// Optimistically clears the banner the moment the user taps Reset,
    /// without waiting for the new (post-delete) state machine to come up
    /// healthy. The host view rebinds to the freshly-built state manager
    /// after `deleteAllInboxes()` completes.
    func dismiss() {
        unbind()
        isDeviceRemoved = false
    }

    private func apply(state: SessionStateMachine.State) {
        if case let .error(error) = state, error is DeviceReplacedError {
            isDeviceRemoved = true
        } else {
            isDeviceRemoved = false
        }
    }

    deinit {
        if let observer = stateObserver, let manager = stateManager {
            manager.removeObserver(observer)
        }
    }
}
