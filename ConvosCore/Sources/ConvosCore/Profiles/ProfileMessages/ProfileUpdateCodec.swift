import Foundation
import SwiftProtobuf
@preconcurrency import XMTPiOS

public let ContentTypeProfileUpdate = ContentTypeID(
    authorityID: "convos.org",
    typeID: "profile_update",
    versionMajor: 1,
    versionMinor: 0
)

public enum ProfileUpdateCodecError: Error, LocalizedError {
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .decodingFailed:
            return "Failed to decode ProfileUpdate protobuf"
        }
    }
}

public struct ProfileUpdateCodec: ContentCodec {
    public typealias T = ProfileUpdate

    public var contentType: ContentTypeID = ContentTypeProfileUpdate

    public init() {}

    public func encode(content: ProfileUpdate) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeProfileUpdate
        encodedContent.content = try content.serializedData()
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ProfileUpdate {
        do {
            return try ProfileUpdate(serializedData: content.content)
        } catch {
            throw ProfileUpdateCodecError.decodingFailed
        }
    }

    public func fallback(content: ProfileUpdate) throws -> String? {
        nil
    }

    public func shouldPush(content: ProfileUpdate) throws -> Bool {
        false
    }
}
