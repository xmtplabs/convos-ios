import Foundation
import SwiftProtobuf
// FIXME(stage4): `@preconcurrency import XMTPiOS` remains because
// ConvosProfiles is a sibling SwiftPM package (ConvosCore depends on
// it). The codec conforms to `XMTPiOS.ContentCodec` directly.
// Migration to the Convos-owned `MessagingCodec` protocol requires
// either promoting `Messaging*` out of ConvosCore into a shared
// package, or defining a package-local codec protocol and having
// callers bridge. Tracks audit §5 Stage 6 (codec migration).
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
