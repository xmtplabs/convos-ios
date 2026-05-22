import Combine
import Foundation

/// Real `CreditsServiceProtocol` backed by the Convos backend's
/// `GET /v2/accounts/me/credits` endpoint. Used in production and in
/// non-production builds whenever the "use real backend" toggle is on.
///
/// Mirrors `MockCreditsService` in shape: a process-wide singleton publishes
/// `CreditBalance?` updates so the HOME pill, conversation low-balance banner,
/// agent contact section, and settings detail screen all stay in lockstep.
public final class BackendCreditsService: CreditsServiceProtocol, @unchecked Sendable {
    /// Process-wide singleton. Lazily constructed on first access — by then
    /// `ConfigManager.shared.currentEnvironment` is configured (it's set in
    /// `ConvosApp.init` before any UI surface is rendered).
    public static let shared: BackendCreditsService = BackendCreditsService(
        apiClient: ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
    )

    /// Refresh debounce window. View-appear + scene-becomes-active triggers
    /// fire freely; this TTL collapses bursts so we don't hammer the API
    /// when the user navigates between views in quick succession. Forced
    /// refreshes (pull-to-refresh, post-purchase) bypass it.
    private static let refreshTTL: TimeInterval = 15

    private let apiClient: any ConvosAPIClientProtocol
    private let balanceSubject: CurrentValueSubject<CreditBalance?, Never>
    private let lock: NSLock = NSLock()
    private var lastFetchedAt: Date?

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
        self.balanceSubject = CurrentValueSubject(nil)
        Task { [weak self] in
            await self?.refresh(force: true)
        }
    }

    public var balancePublisher: AnyPublisher<CreditBalance?, Never> {
        balanceSubject.eraseToAnyPublisher()
    }

    public var currentBalance: CreditBalance? {
        balanceSubject.value
    }

    public func refresh(force: Bool) async {
        if !force, let last = readLastFetchedAt(),
           Date().timeIntervalSince(last) < Self.refreshTTL {
            return
        }
        do {
            let balance = try await apiClient.getCreditBalance()
            balanceSubject.send(balance)
            writeLastFetchedAt(Date())
        } catch {
            Log.error("Failed to refresh credit balance from backend: \(error)")
        }
    }

    private func readLastFetchedAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastFetchedAt
    }

    private func writeLastFetchedAt(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        lastFetchedAt = date
    }
}
