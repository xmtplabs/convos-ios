import Foundation
import SwiftProtobuf
@preconcurrency import XMTPiOS

/// v2 carries a plain avatar URL and the backend's version. Sent by this
/// client; an older build does not recognise the type and ignores the message,
/// which leaves it showing the last profile it saw rather than blanking the
/// avatar - what would happen if v2's shape arrived under the v1 type.
public let ContentTypeProfileUpdate = ContentTypeID(
    authorityID: "convos.org",
    typeID: "profile_update",
    versionMajor: 2,
    versionMinor: 0
)

/// The shape still on the wire from builds that predate the backend profile.
/// Decoded, never sent. Retired with the rest of the v1 read path.
public let ContentTypeProfileUpdateV1 = ContentTypeID(
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

/// Decodes the v1 messages already on the wire. Registered alongside the v2
/// codec so a member on an older build still resolves; both decode into the
/// same type, since the proto kept field 2 declared for exactly this.
public struct ProfileUpdateV1Codec: ContentCodec {
    public typealias T = ProfileUpdate

    public var contentType: ContentTypeID = ContentTypeProfileUpdateV1

    public init() {}

    public func encode(content: ProfileUpdate) throws -> EncodedContent {
        // v1 is read-only: everything this client sends is v2.
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeProfileUpdateV1
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
