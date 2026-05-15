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

    private let apiClient: any ConvosAPIClientProtocol
    private let balanceSubject: CurrentValueSubject<CreditBalance?, Never>

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
        self.balanceSubject = CurrentValueSubject(nil)
        Task { [weak self] in
            await self?.refresh()
        }
    }

    public var balancePublisher: AnyPublisher<CreditBalance?, Never> {
        balanceSubject.eraseToAnyPublisher()
    }

    public var currentBalance: CreditBalance? {
        balanceSubject.value
    }

    public func refresh() async {
        do {
            let balance = try await apiClient.getCreditBalance()
            balanceSubject.send(balance)
        } catch {
            Log.error("Failed to refresh credit balance from backend: \(error)")
        }
    }
}
