import Combine
import Foundation
import GRDB

public protocol VoiceMemoTranscriptRepositoryProtocol: Sendable {
    func transcript(for messageId: String) async throws -> VoiceMemoTranscript?
    func transcriptPublisher(for messageId: String) -> AnyPublisher<VoiceMemoTranscript?, Never>
    func transcriptsPublisher(in conversationId: String) -> AnyPublisher<[String: VoiceMemoTranscript], Never>
}

public final class VoiceMemoTranscriptRepository: VoiceMemoTranscriptRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func transcript(for messageId: String) async throws -> VoiceMemoTranscript? {
        try await databaseReader.read { db in
            try DBVoiceMemoTranscript
                .filter(DBVoiceMemoTranscript.Columns.messageId == messageId)
                .fetchOne(db)?
                .model
        }
    }

    public func transcriptPublisher(for messageId: String) -> AnyPublisher<VoiceMemoTranscript?, Never> {
        ValueObservation
            .tracking { db in
                try DBVoiceMemoTranscript
                    .filter(DBVoiceMemoTranscript.Columns.messageId == messageId)
                    .fetchOne(db)?
                    .model
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    public func transcriptsPublisher(in conversationId: String) -> AnyPublisher<[String: VoiceMemoTranscript], Never> {
        ValueObservation
            .tracking { db in
                let rows = try DBVoiceMemoTranscript
                    .filter(DBVoiceMemoTranscript.Columns.conversationId == conversationId)
                    .fetchAll(db)
                return rows.reduce(into: [String: VoiceMemoTranscript]()) { result, row in
                    result[row.messageId] = row.model
                }
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [:])
            .eraseToAnyPublisher()
    }
}
