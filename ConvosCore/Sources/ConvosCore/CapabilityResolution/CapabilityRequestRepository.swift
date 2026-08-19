import Combine
import ConvosConnections
import Foundation
import GRDB

/// Observes the message table for `capability_request` rows in one conversation and
/// publishes the latest one that the viewing member hasn't resolved with a
/// matching `capability_request_result` yet. The picker UI subscribes — when the
/// publisher emits a non-nil `CapabilityRequest`, the conversation view model
/// recomputes the `CapabilityPickerLayout` and surfaces the approval sheet.
///
/// Resolution detection joins result rows on `requestId` and applies
/// `CapabilityConnectPrompt.resolution` — the SAME validated rule the transcript
/// pill derives its display state from, so "tap path open" and "pill pending"
/// can never disagree. Resolution is per viewer: only the viewer's own
/// approve/deny/cancel rows resolve a request for them (earliest wins, in
/// message-time order); other members' rows, asker-authored rows, and
/// non-decision statuses never resolve it.
public protocol CapabilityRequestRepositoryProtocol: Sendable {
    var pendingRequestPublisher: AnyPublisher<CapabilityRequest?, Never> { get }

    /// Resolves which conversation an approval's grant writes must scope to
    /// (see `CapabilityGrantScope`). `isAgentDm` is the conversation's
    /// persisted classification; `liveMarkerOrigin` reads the DM's own XMTP
    /// appData marker and is consulted only when the local mirror row is
    /// absent.
    func resolveGrantScope(
        isAgentDm: Bool,
        askerInboxId: String,
        liveMarkerOrigin: @escaping @Sendable () async -> String?
    ) async -> CapabilityGrantScopeResolution
}

public final class CapabilityRequestRepository: CapabilityRequestRepositoryProtocol, @unchecked Sendable {
    private let dbReader: any DatabaseReader
    private let conversationId: String
    private let viewerInboxId: String

    public init(dbReader: any DatabaseReader, conversationId: String, viewerInboxId: String) {
        self.dbReader = dbReader
        self.conversationId = conversationId
        self.viewerInboxId = viewerInboxId
    }

    public func resolveGrantScope(
        isAgentDm: Bool,
        askerInboxId: String,
        liveMarkerOrigin: @escaping @Sendable () async -> String?
    ) async -> CapabilityGrantScopeResolution {
        await CapabilityGrantScopeResolution.resolve(
            conversationId: conversationId,
            isAgentDm: isAgentDm,
            askerInboxId: askerInboxId,
            viewerInboxId: viewerInboxId,
            dbReader: dbReader,
            liveMarkerOrigin: liveMarkerOrigin
        )
    }

    public lazy var pendingRequestPublisher: AnyPublisher<CapabilityRequest?, Never> = {
        let conversationId = self.conversationId
        let viewerInboxId = self.viewerInboxId
        return ValueObservation
            .tracking { db -> CapabilityRequest? in
                Self.computeLatestPendingRequest(
                    conversationId: conversationId,
                    viewerInboxId: viewerInboxId,
                    db: db
                )
            }
            .publisher(in: dbReader, scheduling: .async(onQueue: .main))
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }()

    /// Pure function over a `Database` (visible for testing). Walks every
    /// capability_request message for the conversation in descending date
    /// order and returns the first one that no validated result from the
    /// viewer resolves.
    static func computeLatestPendingRequest(conversationId: String, viewerInboxId: String, db: Database) -> CapabilityRequest? {
        do {
            let resultsByRequestId = try resultRecordsByRequestId(conversationId: conversationId, db: db)
            return try computeLatestPendingRequest(
                conversationId: conversationId,
                viewerInboxId: viewerInboxId,
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
    /// `CapabilityConnectPrompt.resolution`: the viewer's first validated
    /// decision in message-time order wins; other members' rows and
    /// asker-authored rows never count.
    static func computeLatestPendingRequest(
        conversationId: String,
        viewerInboxId: String,
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
                askerInboxId: request.askerInboxId,
                viewerInboxId: viewerInboxId
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
