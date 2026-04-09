import Foundation

public struct ConversationCustomMetadataDebugSnapshot: Sendable {
    public let rawAppData: String?
    public let rawAppDataByteCount: Int
    public let parsedMetadata: ConversationCustomMetadata
    public let roundTripEncodedMetadata: String?
    public let parseLooksLossless: Bool

    public init(rawAppData: String?) {
        self.rawAppData = rawAppData
        rawAppDataByteCount = rawAppData?.utf8.count ?? 0
        parsedMetadata = ConversationCustomMetadata.parseAppData(rawAppData)
        roundTripEncodedMetadata = try? parsedMetadata.toCompactString()
        parseLooksLossless = rawAppData == roundTripEncodedMetadata
    }

    public var debugText: String {
        [
            "rawAppDataByteCount: \(rawAppDataByteCount)",
            "rawAppData:",
            rawAppData ?? "<nil>",
            "",
            "parsedMetadata:",
            String(describing: parsedMetadata),
            "",
            "roundTripEncodedMetadata:",
            roundTripEncodedMetadata ?? "<encoding failed>",
            "",
            "parseLooksLossless: \(parseLooksLossless)"
        ].joined(separator: "\n")
    }
}
