import Foundation

public final class MockReadReceiptWriter: ReadReceiptWriterProtocol, @unchecked Sendable {
    public var sentReadReceipts: [String] = []

    public init() {}

    public func sendReadReceipt(for conversationId: String) async throws {
        sentReadReceipts.append(conversationId)
    }

    public func fetchReadMemberInboxIds(
        for conversationId: String,
        afterNs messageDateNs: Int64,
        excludingInboxId: String
    ) async throws -> [String] {
        []
    }
}
