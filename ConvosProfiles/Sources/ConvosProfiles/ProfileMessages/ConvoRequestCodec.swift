import Foundation
import SwiftProtobuf
@preconcurrency import XMTPiOS

public let ContentTypeConvoRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "convo_request",
    versionMajor: 1,
    versionMinor: 0
)

public enum ConvoRequestCodecError: Error, LocalizedError {
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .decodingFailed:
            return "Failed to decode ConvoRequest protobuf"
        }
    }
}

public struct ConvoRequestCodec: ContentCodec {
    public typealias T = ConvoRequest

    public var contentType: ContentTypeID = ContentTypeConvoRequest

    public init() {}

    public func encode(content: ConvoRequest) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeConvoRequest
        encodedContent.content = try content.serializedData()
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ConvoRequest {
        do {
            return try ConvoRequest(serializedBytes: content.content)
        } catch {
            throw ConvoRequestCodecError.decodingFailed
        }
    }

    public func fallback(content: ConvoRequest) throws -> String? {
        nil
    }

    public func shouldPush(content: ConvoRequest) throws -> Bool {
        false
    }
}
