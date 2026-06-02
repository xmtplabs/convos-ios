import Foundation
@preconcurrency import XMTPiOS

public let ContentTypePairingJoinRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "pairing_join_request",
    versionMajor: 1,
    versionMinor: 0
)

/// First DM from the joiner to the initiator after scanning the pairing
/// QR. Tells the initiator who's asking to pair so the initiator can
/// generate + send a PIN back over DM.
public struct PairingJoinRequestContent: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let slug: String
    public let joinerInboxId: String
    public let deviceName: String

    public init(
        schemaVersion: UInt32 = 1,
        slug: String,
        joinerInboxId: String,
        deviceName: String
    ) {
        self.schemaVersion = schemaVersion
        self.slug = slug
        self.joinerInboxId = joinerInboxId
        self.deviceName = deviceName
    }
}

public enum PairingJoinRequestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "PairingJoinRequest content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for PairingJoinRequest"
        }
    }
}

public struct PairingJoinRequestCodec: ContentCodec {
    public typealias T = PairingJoinRequestContent

    public var contentType: ContentTypeID = ContentTypePairingJoinRequest

    public init() {}

    public func encode(content: PairingJoinRequestContent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypePairingJoinRequest
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> PairingJoinRequestContent {
        guard !content.content.isEmpty else {
            throw PairingJoinRequestCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(PairingJoinRequestContent.self, from: content.content)
        } catch {
            throw PairingJoinRequestCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: PairingJoinRequestContent) throws -> String? {
        nil
    }

    public func shouldPush(content: PairingJoinRequestContent) throws -> Bool {
        false
    }
}
