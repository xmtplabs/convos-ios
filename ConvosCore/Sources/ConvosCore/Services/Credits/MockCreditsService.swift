import Combine
import Foundation

public final class MockCreditsService: CreditsServiceProtocol, @unchecked Sendable {
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

    public func refresh() async {
        let snapshot = queue.sync { currentPreset.balance() }
        balanceSubject.send(snapshot)
    }

    public func setPreset(_ preset: CreditsStatePreset) {
        queue.sync { currentPreset = preset }
        balanceSubject.send(preset.balance())
    }
}
