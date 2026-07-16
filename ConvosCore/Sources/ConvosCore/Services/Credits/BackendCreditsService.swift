import Combine
import Foundation
import GRDB

/// Real `CreditsServiceProtocol` backed by the Convos backend's
/// `GET /v2/accounts/me/credits` endpoint. The HTTP refresh is delegated to
/// `CreditBalanceWriter`, which upserts the result into the local
/// `credit_balance` table. Reads (`balancePublisher`, `currentBalance`) are
/// delegated to `CreditsRepository`, which observes the same table via GRDB.
///
/// View sites consume the protocol surface; the writer/repository split is
/// internal. The repo-based observation lets the HOME pill, conversation
/// banner, settings detail, and paywall stay in lockstep through the same
/// GRDB observation channel the rest of the app uses.
public final class BackendCreditsService: CreditsServiceProtocol {
    private let writer: CreditBalanceWriter
    private let repository: CreditsRepository

    public init(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        apiClient: any ConvosAPIClientProtocol
    ) {
        self.writer = CreditBalanceWriter(databaseWriter: databaseWriter, apiClient: apiClient)
        self.repository = CreditsRepository(databaseReader: databaseReader)
    }

    public var balancePublisher: AnyPublisher<CreditBalance?, Never> {
        repository.balancePublisher
    }

    public var currentBalance: CreditBalance? {
        do {
            return try repository.currentBalance()
        } catch {
            Log.error("Failed reading cached credit balance: \(error)")
            return nil
        }
    }

    public func refresh(force: Bool) async {
        await writer.refresh(force: force)
    }

    /// Account-deletion fence; see `CreditBalanceWriter.beginAccountWipe()`.
    public func beginAccountWipe() async {
        await writer.beginAccountWipe()
    }

    /// Reopens the writer after the wipe; see
    /// `CreditBalanceWriter.endAccountWipe()`. Synchronous for `defer`.
    public func endAccountWipe() {
        writer.endAccountWipe()
    }
}
