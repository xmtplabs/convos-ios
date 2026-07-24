import ConvosCore
import Foundation
import Observation

/// Observes `SessionStateMachine` and exposes whether the session has
/// landed in the terminal `AccountDeletedError` state — the backend's
/// deletion barrier reported the account deleted (from this or another
/// paired device) outside any local deletion flow.
///
/// Mirrors `StaleDeviceObserver`, but the exit is different: a revoked
/// installation resets locally and re-onboards, while a deleted account
/// offers only a local wipe — nothing may auto-provision a replacement
/// account without explicit user intent.
@MainActor
@Observable
final class AccountDeletedObserver {
    private(set) var isAccountDeleted: Bool = false

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

    /// Optimistically clears the sheet the moment the user starts the
    /// local wipe. The host view rebinds to the freshly-built state
    /// manager after the wipe completes.
    func dismiss() {
        unbind()
        isAccountDeleted = false
    }

    /// Re-presents the sheet after a local wipe failed: the backend account
    /// is still deleted, so the terminal state and its retry affordance must
    /// survive the session rather than being hidden behind a gated
    /// (non-`AccountDeletedError`) service. The host view's `onChange` on
    /// this flag re-arms its local dismissal state.
    func present() {
        isAccountDeleted = true
    }

    private func apply(state: SessionStateMachine.State) {
        if case let .error(error) = state, error is AccountDeletedError {
            isAccountDeleted = true
        } else {
            isAccountDeleted = false
        }
    }

    deinit {
        if let observer = stateObserver, let manager = stateManager {
            manager.removeObserver(observer)
        }
    }
}
