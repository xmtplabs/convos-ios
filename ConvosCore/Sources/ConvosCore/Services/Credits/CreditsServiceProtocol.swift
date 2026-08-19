import Combine
import Foundation

public protocol CreditsServiceProtocol: AnyObject, Sendable {
    var balancePublisher: AnyPublisher<CreditBalance?, Never> { get }

    /// The cached balance, read synchronously.
    ///
    /// The backend implementation reads the database to answer this, so it
    /// blocks for as long as it takes to get a connection out of the reader
    /// pool - which at launch, with the list observations running, has been
    /// seconds. Never call it on the main thread, and in particular never as
    /// the default value of a SwiftUI `@State`: those are evaluated on every
    /// init of the view, so it lands inside body evaluation and takes the
    /// whole scene down with a watchdog kill. Observe `balancePublisher`
    /// instead - it schedules asynchronously for this same reason.
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
