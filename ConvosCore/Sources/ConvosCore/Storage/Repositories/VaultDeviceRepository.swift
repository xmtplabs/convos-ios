import Combine
import Foundation
import GRDB

public final class VaultDeviceRepository: @unchecked Sendable {
    public let devicesPublisher: AnyPublisher<[DBVaultDevice], Never>

    private let dbReader: any DatabaseReader

    public init(dbReader: any DatabaseReader) {
        self.dbReader = dbReader
        self.devicesPublisher = ValueObservation
            .tracking { db in
                try DBVaultDevice
                    .order(DBVaultDevice.Columns.isCurrentDevice.desc, DBVaultDevice.Columns.addedAt.asc)
                    .fetchAll(db)
            }
            .publisher(in: dbReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    public func fetchAll() throws -> [DBVaultDevice] {
        try dbReader.read { db in
            try DBVaultDevice
                .order(DBVaultDevice.Columns.isCurrentDevice.desc, DBVaultDevice.Columns.addedAt.asc)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbReader.read { db in
            try DBVaultDevice.fetchCount(db)
        }
    }
}
