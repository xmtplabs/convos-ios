import Combine
import Foundation
import GRDB

/// Read access to the locally-cached credit balance row. The actual value
/// is sourced from the backend by `CreditBalanceWriter`; this repository
/// just exposes the single row as an observable publisher + a sync read.
public protocol CreditsRepositoryProtocol: Sendable {
    var balancePublisher: AnyPublisher<CreditBalance?, Never> { get }
    func currentBalance() throws -> CreditBalance?
}

public final class CreditsRepository: CreditsRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public var balancePublisher: AnyPublisher<CreditBalance?, Never> {
        ValueObservation
            .tracking { db in
                try DBCreditBalance
                    .filter(DBCreditBalance.Columns.id == DBCreditBalance.currentRowID)
                    .fetchOne(db)?
                    .hydrate()
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    public func currentBalance() throws -> CreditBalance? {
        try databaseReader.read { db in
            try DBCreditBalance
                .filter(DBCreditBalance.Columns.id == DBCreditBalance.currentRowID)
                .fetchOne(db)?
                .hydrate()
        }
    }
}
