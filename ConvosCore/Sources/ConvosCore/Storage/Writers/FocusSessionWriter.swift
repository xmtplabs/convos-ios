import Foundation
import GRDB

public protocol FocusSessionWriterProtocol: Sendable {
    func applyFocusModeControl(
        _ control: FocusModeControl,
        conversationId: String,
        receivedAt: Date
    ) async throws

    func applyStreamingText(
        _ payload: StreamingText,
        receivedAt: Date
    ) async throws

    func applyStreamingClear(
        _ payload: StreamingClear,
        receivedAt: Date
    ) async throws
}

public extension FocusSessionWriterProtocol {
    func applyFocusModeControl(_ control: FocusModeControl, conversationId: String) async throws {
        try await applyFocusModeControl(control, conversationId: conversationId, receivedAt: Date())
    }

    func applyStreamingText(_ payload: StreamingText) async throws {
        try await applyStreamingText(payload, receivedAt: Date())
    }

    func applyStreamingClear(_ payload: StreamingClear) async throws {
        try await applyStreamingClear(payload, receivedAt: Date())
    }
}

public final class FocusSessionWriter: FocusSessionWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func applyFocusModeControl(
        _ control: FocusModeControl,
        conversationId: String,
        receivedAt: Date
    ) async throws {
        try await databaseWriter.write { db in
            let existing = try DBFocusSession
                .filter(Column("sessionId") == control.sessionId)
                .fetchOne(db)

            switch control.state {
            case .start:
                let resolvedFocusedInboxId = control.focusedInboxId ?? existing?.focusedInboxId
                let session = DBFocusSession(
                    sessionId: control.sessionId,
                    conversationId: existing?.conversationId ?? conversationId,
                    focusedInboxId: resolvedFocusedInboxId,
                    state: .started,
                    startedAt: existing?.startedAt ?? receivedAt,
                    stoppedAt: nil
                )
                try session.save(db, onConflict: .replace)

            case .stop:
                guard var session = existing else {
                    let session = DBFocusSession(
                        sessionId: control.sessionId,
                        conversationId: conversationId,
                        focusedInboxId: control.focusedInboxId,
                        state: .stopped,
                        startedAt: receivedAt,
                        stoppedAt: receivedAt
                    )
                    try session.save(db, onConflict: .replace)
                    return
                }
                session.state = .stopped
                session.stoppedAt = receivedAt
                try session.save(db, onConflict: .replace)
            }
        }
    }

    public func applyStreamingText(
        _ payload: StreamingText,
        receivedAt: Date
    ) async throws {
        try await databaseWriter.write { db in
            guard try Self.sessionIsActive(payload.sessionId, db: db) else { return }
            let existing = try DBLiveBubble
                .filter(Column("sessionId") == payload.sessionId
                        && Column("senderInboxId") == payload.senderInboxId)
                .fetchOne(db)
            if let existing, existing.revision >= Int64(payload.revision) {
                return
            }
            let bubble = DBLiveBubble(
                sessionId: payload.sessionId,
                senderInboxId: payload.senderInboxId,
                text: payload.text,
                revision: Int64(payload.revision),
                updatedAt: receivedAt
            )
            try bubble.save(db, onConflict: .replace)
        }
    }

    public func applyStreamingClear(
        _ payload: StreamingClear,
        receivedAt: Date
    ) async throws {
        try await databaseWriter.write { db in
            guard try Self.sessionIsActive(payload.sessionId, db: db) else { return }
            let existing = try DBLiveBubble
                .filter(Column("sessionId") == payload.sessionId
                        && Column("senderInboxId") == payload.senderInboxId)
                .fetchOne(db)
            if let existing, existing.revision >= Int64(payload.revision) {
                return
            }
            let cleared = DBLiveBubble(
                sessionId: payload.sessionId,
                senderInboxId: payload.senderInboxId,
                text: "",
                revision: Int64(payload.revision),
                updatedAt: receivedAt
            )
            try cleared.save(db, onConflict: .replace)
        }
    }

    private static func sessionIsActive(_ sessionId: String, db: Database) throws -> Bool {
        guard let session = try DBFocusSession
            .filter(Column("sessionId") == sessionId)
            .fetchOne(db) else { return false }
        return session.state == .started
    }
}
