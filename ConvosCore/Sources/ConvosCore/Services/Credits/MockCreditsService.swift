import Combine
import Foundation

public final class MockCreditsService: CreditsServiceProtocol, @unchecked Sendable {
    /// Process-wide singleton used by the Debug menu's preset picker and the
    /// in-app credits surfaces (HOME pill, etc.) so they share one observable
    /// state. Replace with a real `CreditsServiceProtocol` once the backend
    /// HTTP wrappers land.
    public static let shared: MockCreditsService = MockCreditsService()

    private let balanceSubject: CurrentValueSubject<CreditBalance?, Never>
    private let queue: DispatchQueue = DispatchQueue(label: "convos.mock-credits-service")
    private var currentPreset: CreditsStatePreset

    public init(initialPreset: CreditsStatePreset = .builderAmple) {
        self.currentPreset = initialPreset
        self.balanceSubject = CurrentValueSubject(initialPreset.balance())
    }

    public var balancePublisher: AnyPublisher<CreditBalance?, Never> {
        balanceSubject.eraseToAnyPublisher()
    }

    public var currentBalance: CreditBalance? {
        balanceSubject.value
    }

    public var preset: CreditsStatePreset {
        queue.sync { currentPreset }
    }

    public func refresh(force: Bool) async {
        // Mock service has no real network roundtrip; the TTL contract is
        // moot here. Always re-publish the current preset so debug-menu
        // changes propagate immediately regardless of `force`.
        let snapshot = queue.sync { currentPreset.balance() }
        balanceSubject.send(snapshot)
    }

    public func setPreset(_ preset: CreditsStatePreset) {
        queue.sync { currentPreset = preset }
        balanceSubject.send(preset.balance())
    }
}
