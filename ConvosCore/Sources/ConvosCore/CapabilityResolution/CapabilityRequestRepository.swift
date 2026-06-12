import Combine
import ConvosConnections
import Foundation
import GRDB

/// Observes the message table for `capability_request` rows in one conversation and
/// publishes the latest one that hasn't been resolved by a matching
/// `capability_request_result` yet. The picker UI subscribes — when the publisher
/// emits a non-nil `CapabilityRequest`, the conversation view model recomputes the
/// `CapabilityPickerLayout` and surfaces the approval sheet.
///
/// Resolution detection joins result rows on `requestId` and applies
/// `CapabilityConnectPrompt.resolution` — the SAME validated rule the transcript
/// pill derives its display state from, so "tap path open" and "pill pending"
/// can never disagree. First decision wins, in message-time order: the earliest
/// validated approve/deny/cancel resolves the request for the whole
/// conversation; asker-authored rows and non-decision statuses never resolve it.
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

    /// Pure function over a `Database` (visible for testing). Walks every
    /// capability_request message for the conversation in descending date
    /// order and returns the first one that no validated result resolves.
    static func computeLatestPendingRequest(conversationId: String, db: Database) -> CapabilityRequest? {
        do {
            let resultsByRequestId = try resultRecordsByRequestId(conversationId: conversationId, db: db)
            return try computeLatestPendingRequest(
                conversationId: conversationId,
                db: db,
                resultsByRequestId: resultsByRequestId
            )
        } catch {
            Log.error("CapabilityRequestRepository: computeLatestPendingRequest failed for \(conversationId): \(error)")
            return nil
        }
    }

    /// Shared with `MessagesRepository`'s compose-time join, which uses the
    /// returned request to decide which unresolved pill renders `.pending`
    /// (actionable) versus `.superseded` — keeping the transcript and the tap
    /// path on one verdict. Resolution per request is
    /// `CapabilityConnectPrompt.resolution`: the first validated decision in
    /// message-time order wins, asker-authored rows never count.
    static func computeLatestPendingRequest(
        conversationId: String,
        db: Database,
        resultsByRequestId: [String: [CapabilityConnectPrompt.ResultRecord]]
    ) throws -> CapabilityRequest? {
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
            let resolution = CapabilityConnectPrompt.resolution(
                results: resultsByRequestId[request.requestId] ?? [],
                askerInboxId: request.askerInboxId
            )
            if resolution == nil {
                return request
            }
        }
        return nil
    }

    /// Every capability_request_result row in the conversation, decoded and
    /// keyed by `requestId`, each carrying the row's XMTP-attested `senderId`
    /// plus its message-time position (`dateNs` + message id) — the inputs
    /// `CapabilityConnectPrompt.resolution` validates and orders against.
    /// The query orders by sent timestamp with the message id as a stable
    /// tiebreaker so each bucket is already in message-time order, and
    /// `resolution` re-sorts on the same key anyway, so first-decision-wins
    /// cannot be bypassed by an unordered caller.
    static func resultRecordsByRequestId(
        conversationId: String,
        db: Database
    ) throws -> [String: [CapabilityConnectPrompt.ResultRecord]] {
        let results = try DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .filter(DBMessage.Columns.contentType == MessageContentType.capabilityRequestResult.rawValue)
            .order(DBMessage.Columns.dateNs.asc, DBMessage.Columns.id.asc)
            .fetchAll(db)
        var recordsByRequestId: [String: [CapabilityConnectPrompt.ResultRecord]] = [:]
        for row in results {
            guard let text = row.text,
                  let data = text.data(using: .utf8),
                  let result = try? JSONDecoder().decode(CapabilityRequestResult.self, from: data) else {
                continue
            }
            recordsByRequestId[result.requestId, default: []].append(
                .init(senderId: row.senderId, status: result.status, sentAtNs: row.dateNs, messageId: row.id)
            )
        }
        return recordsByRequestId
    }
}
