import Foundation

/// A no-op `ConnectionDelivering` that logs every attempt. Useful for the debug view
/// and for local testing before the XMTP-backed delivery adapter exists.
public actor ConsoleDelivering: ConnectionDelivering {
    public private(set) var log: [LogEntry] = []
    private let printToStdout: Bool

    public init(printToStdout: Bool = true) {
        self.printToStdout = printToStdout
    }

    public func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {
        let entry = LogEntry(conversationId: conversationId, payload: payload, deliveredAt: Date())
        log.append(entry)
        if printToStdout {
            print("[ConvosConnections] -> \(conversationId): \(payload.summary)")
        }
    }

    public func snapshot() -> [LogEntry] {
        log
    }

    public func clear() {
        log.removeAll()
    }

    public struct LogEntry: Sendable, Identifiable, Equatable {
        public let conversationId: String
        public let payload: ConnectionPayload
        public let deliveredAt: Date

        public var id: UUID { payload.id }
    }
}
