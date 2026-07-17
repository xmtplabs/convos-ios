import Foundation
import SwiftProtobuf
@preconcurrency import XMTPiOS

public let ContentTypeProfileSnapshot = ContentTypeID(
    authorityID: "convos.org",
    typeID: "profile_snapshot",
    versionMajor: 1,
    versionMinor: 0
)

public enum ProfileSnapshotCodecError: Error, LocalizedError {
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .decodingFailed:
            return "Failed to decode ProfileSnapshot protobuf"
        }
    }
}

public struct ProfileSnapshotCodec: ContentCodec {
    public typealias T = ProfileSnapshot

    public var contentType: ContentTypeID = ContentTypeProfileSnapshot

    public init() {}

    public func encode(content: ProfileSnapshot) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeProfileSnapshot
        encodedContent.content = try content.serializedData()
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ProfileSnapshot {
        do {
            return try ProfileSnapshot(serializedData: content.content)
        } catch {
            throw ProfileSnapshotCodecError.decodingFailed
        }
    }

    public func fallback(content: ProfileSnapshot) throws -> String? {
        nil
    }

    public func shouldPush(content: ProfileSnapshot) throws -> Bool {
        false
    }
}
