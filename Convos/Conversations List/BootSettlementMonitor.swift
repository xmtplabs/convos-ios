import ConvosCore
import Foundation
import Observation

/// Tracks whether the initial boot catch-up has settled so the
/// conversations list can switch from cheap full reloads to diffed,
/// animated snapshot applies.
///
/// The session state machine emits `.ready` only after the batch
/// catch-up completes, so reaching `.ready` means the burst of catch-up
/// writes has landed. A fallback timeout guarantees the list never
/// stays in reload-mode when the session errors or never reaches
/// `.ready` (fresh installs, previews, mock sessions).
///
/// `isSettled` latches true for the remainder of the launch; foreground
/// re-catch-ups stay on the diffed path because the user may be
/// mid-scroll, where a full reload would jump the list.
@MainActor
@Observable
final class BootSettlementMonitor {
    private(set) var isSettled: Bool = false

    @ObservationIgnored private var stateObserver: (any SessionStateObserver)?
    @ObservationIgnored private weak var stateManager: (any SessionStateManagerProtocol)?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?

    /// Binds the monitor to a session's state manager. Safe to call
    /// multiple times before settling — rebinding replaces the prior
    /// observation. A no-op once settled.
    func bind(
        to stateManager: any SessionStateManagerProtocol,
        fallbackTimeout: TimeInterval = 10
    ) {
        guard !isSettled else { return }
        unbind()
        self.stateManager = stateManager

        if case .ready = stateManager.currentState {
            settle(reason: "ready at bind")
            return
        }

        let closure = ClosureStateObserver { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor [weak self] in
                self?.settle(reason: "ready")
            }
        }
        stateManager.addObserver(closure)
        stateObserver = closure

        fallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fallbackTimeout))
            guard !Task.isCancelled else { return }
            self?.settle(reason: "timeout")
        }
    }

    private func settle(reason: String) {
        guard !isSettled else { return }
        isSettled = true
        Log.info("[PERF] conversations list settled (\(reason))")
        fallbackTask?.cancel()
        fallbackTask = nil
        unbind()
    }

    private func unbind() {
        if let observer = stateObserver, let manager = stateManager {
            manager.removeObserver(observer)
        }
        stateObserver = nil
        stateManager = nil
    }

    deinit {
        fallbackTask?.cancel()
        if let observer = stateObserver, let manager = stateManager {
            manager.removeObserver(observer)
        }
    }
}
