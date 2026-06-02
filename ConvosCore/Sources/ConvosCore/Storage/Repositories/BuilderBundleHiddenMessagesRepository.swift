import Combine
import Foundation
import GRDB

/// Reads the set of message ids a `BuilderBundleManifest` flagged as
/// agent-builder bundle messages for a conversation (see
/// `DBBuilderBundleHiddenMessage`). The messages list filters these out on
/// every client so the agent brief never appears in the chat.
public protocol BuilderBundleHiddenMessagesRepositoryProtocol: Sendable {
    /// Synchronous fetch for view-construction paths that can't await -- seeds
    /// `MessagesListRepository.hiddenBundleMessageIds` before `fetchInitial()`
    /// so the first list emission already hides the bundle.
    func hiddenMessageIdsSync(in conversationId: String) -> Set<String>
    /// Reactive observation -- emits the current set plus any rows written as
    /// later manifests or their bundle messages arrive.
    func hiddenMessageIdsPublisher(in conversationId: String) -> AnyPublisher<Set<String>, Never>
}

public final class BuilderBundleHiddenMessagesRepository: BuilderBundleHiddenMessagesRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func hiddenMessageIdsSync(in conversationId: String) -> Set<String> {
        do {
            return try databaseReader.read { db in
                try Self.fetch(db, conversationId: conversationId)
            }
        } catch {
            Log.error("BuilderBundleHiddenMessagesRepository: hiddenMessageIdsSync failed for \(conversationId): \(error.localizedDescription)")
            return []
        }
    }

    public func hiddenMessageIdsPublisher(in conversationId: String) -> AnyPublisher<Set<String>, Never> {
        ValueObservation
            .tracking { db in
                try Self.fetch(db, conversationId: conversationId)
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    private static func fetch(_ db: Database, conversationId: String) throws -> Set<String> {
        let rows = try DBBuilderBundleHiddenMessage
            .filter(DBBuilderBundleHiddenMessage.Columns.conversationId == conversationId)
            .fetchAll(db)
        return Set(rows.map(\.messageId))
    }
}
