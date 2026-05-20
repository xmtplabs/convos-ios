import Combine
import Foundation

public protocol CreditsServiceProtocol: AnyObject, Sendable {
    var balancePublisher: AnyPublisher<CreditBalance?, Never> { get }
    var currentBalance: CreditBalance? { get }

    /// Pull a fresh balance from the backend. The default `force: false` is
    /// TTL-debounced (see implementation) so views can call this on every
    /// `.task` / scene-becomes-active without storming the API.
    /// Pass `force: true` for explicit user-initiated freshness
    /// (pull-to-refresh, post-purchase).
    func refresh(force: Bool) async
}

public extension CreditsServiceProtocol {
    func refresh() async {
        await refresh(force: false)
    }
}
