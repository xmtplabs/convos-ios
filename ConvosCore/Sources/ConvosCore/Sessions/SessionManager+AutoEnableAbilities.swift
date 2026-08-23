import Foundation

extension SessionManager {
    /// Stores the gate the auto-enable service consults on every run. The
    /// host app wires this to the same feature-flag check that decides
    /// whether the v1 connections toggle renders; until it is configured the
    /// service treats itself as disabled.
    public func configureAutoEnableAbilities(isEnabled: @escaping @Sendable () async -> Bool) {
        autoEnableAbilitiesEligibilityLock.withLock { provider in
            provider = isEnabled
        }
    }

    /// Returns the session-wide auto-enable service, instantiating it on
    /// first access. The eligibility gate is read through the lock at call
    /// time, so configuring after first access still takes effect.
    func autoEnableAbilitiesService() -> AutoEnableAbilitiesService {
        autoEnableAbilitiesServiceLock.withLock { service in
            if let service { return service }
            let eligibilityLock = autoEnableAbilitiesEligibilityLock
            let new = AutoEnableAbilitiesService(
                cloudConnectionRepository: cloudConnectionRepository(),
                grantWriter: messagingService().connectionGrantWriter(),
                connectionEventWriter: messagingService().connectionEventWriter(),
                isEnabled: {
                    guard let provider = eligibilityLock.withLock({ $0 }) else {
                        return false
                    }
                    return await provider()
                }
            )
            service = new
            return new
        }
    }
}
