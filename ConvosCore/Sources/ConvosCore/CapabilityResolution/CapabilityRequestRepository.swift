import Combine
import ConvosConnections
import Foundation
import GRDB

/// Observes the message table for `capability_request` rows in one conversation and
/// publishes the latest one that hasn't been resolved by a matching
/// `capability_request_result` yet. The picker UI subscribes — when the publisher
/// emits a non-nil `CapabilityRequest`, the conversation view model recomputes the
/// `CapabilityPickerLayout` and surfaces the card.
///
/// Resolution detection is by `requestId`: a `capability_request_result` with the same
/// `requestId` (regardless of status) marks the request as resolved.
public protocol CapabilityRequestRepositoryProtocol: Sendable {
    var pendingRequestPublisher: AnyPublisher<CapabilityRequest?, Never> { get }
}

public final class CapabilityRequestRepository: CapabilityRequestRepositoryProtocol, @unchecked Sendable {
    private let dbReader: any DatabaseReader
    private let conversationId: String

    public init(dbReader: any DatabaseReader, conversationId: String) {
        self.dbReader = dbReader
        self.conversationId = conversationId
    }

    public lazy var pendingRequestPublisher: AnyPublisher<CapabilityRequest?, Never> = {
        let conversationId = self.conversationId
        return ValueObservation
            .tracking { db -> CapabilityRequest? in
                Self.computeLatestPendingRequest(conversationId: conversationId, db: db)
            }
            .publisher(in: dbReader, scheduling: .async(onQueue: .main))
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }()

    /// Visible for testing — pure function over a `Database`. Walks every
    /// capability_request message for the conversation in descending date order, and
    /// returns the first one whose `requestId` doesn't appear in any
    /// capability_request_result row.
    static func computeLatestPendingRequest(conversationId: String, db: Database) -> CapabilityRequest? {
        do {
            let resolvedIds = try resolvedRequestIds(conversationId: conversationId, db: db)
            let requests = try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .filter(DBMessage.Columns.contentType == MessageContentType.capabilityRequest.rawValue)
                .order(DBMessage.Columns.dateNs.desc)
                .fetchAll(db)
            for row in requests {
                guard let text = row.text,
                      let data = text.data(using: .utf8),
                      let request = try? JSONDecoder().decode(CapabilityRequest.self, from: data) else {
                    continue
                }
                if !resolvedIds.contains(request.requestId) {
                    return request
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func resolvedRequestIds(conversationId: String, db: Database) throws -> Set<String> {
        let results = try DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .filter(DBMessage.Columns.contentType == MessageContentType.capabilityRequestResult.rawValue)
            .fetchAll(db)
        var ids: Set<String> = []
        for row in results {
            guard let text = row.text,
                  let data = text.data(using: .utf8),
                  let result = try? JSONDecoder().decode(CapabilityRequestResult.self, from: data) else {
                continue
            }
            ids.insert(result.requestId)
        }
        return ids
    }
}
