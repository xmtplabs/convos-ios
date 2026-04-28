import Combine
import ConvosConnections
import Foundation
import GRDB

/// Observes the `capabilityResolution` table for one conversation and publishes the full
/// set of resolutions (every `(subject, capability)` row that has been approved for it).
/// Conversation Info subscribes to drive the "Connections" section.
public protocol CapabilityResolutionsRepositoryProtocol: Sendable {
    var resolutionsPublisher: AnyPublisher<[CapabilityResolution], Never> { get }
}

public final class CapabilityResolutionsRepository: CapabilityResolutionsRepositoryProtocol, @unchecked Sendable {
    private let dbReader: any DatabaseReader
    private let conversationId: String

    public init(dbReader: any DatabaseReader, conversationId: String) {
        self.dbReader = dbReader
        self.conversationId = conversationId
    }

    public lazy var resolutionsPublisher: AnyPublisher<[CapabilityResolution], Never> = {
        let conversationId = self.conversationId
        return ValueObservation
            .tracking { db -> [CapabilityResolution] in
                try DBCapabilityResolution
                    .filter(DBCapabilityResolution.Columns.conversationId == conversationId)
                    .order(DBCapabilityResolution.Columns.subject.asc, DBCapabilityResolution.Columns.capability.asc)
                    .fetchAll(db)
                    .compactMap { $0.toResolution() }
            }
            .publisher(in: dbReader, scheduling: .async(onQueue: .main))
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }()
}
