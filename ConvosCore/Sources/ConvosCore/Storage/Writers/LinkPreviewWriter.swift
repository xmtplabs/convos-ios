import Foundation
import GRDB

public final class LinkPreviewWriter: Sendable {
    private let dbWriter: any DatabaseWriter

    nonisolated(unsafe) public static var shared: LinkPreviewWriter?

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func updateLinkPreview(_ preview: LinkPreview, forMessageId messageId: String) async {
        do {
            let data = try JSONEncoder().encode(preview)
            guard let json = String(data: data, encoding: .utf8) else { return }
            try await dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE message SET linkPreview = ? WHERE id = ?",
                    arguments: [json, messageId]
                )
            }
        } catch {
            Log.error("Failed to update link preview metadata for message \(messageId)")
        }
    }
}
