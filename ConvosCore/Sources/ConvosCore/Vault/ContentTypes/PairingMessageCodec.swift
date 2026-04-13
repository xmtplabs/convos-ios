import Foundation
@preconcurrency import XMTPiOS

public let ContentTypePairingMessage = ContentTypeID(
    authorityID: "convos.org",
    typeID: "pairing_message",
    versionMajor: 1,
    versionMinor: 0
)

public struct PairingMessageContent: Codable, Sendable, Equatable {
    public enum MessageType: String, Codable, Sendable {
        case pin
        case pinEcho = "pin_echo"
        case error
    }

    public let type: MessageType
    public let payload: String

    public init(type: MessageType, payload: String) {
        self.type = type
        self.payload = payload
    }

    public static func pin(_ pin: String) -> PairingMessageContent {
        PairingMessageContent(type: .pin, payload: pin)
    }

    public static func pinEcho(_ pin: String) -> PairingMessageContent {
        PairingMessageContent(type: .pinEcho, payload: pin)
    }

    public static func error(_ message: String) -> PairingMessageContent {
        PairingMessageContent(type: .error, payload: message)
    }
}

public enum PairingMessageCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "PairingMessage content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for PairingMessage"
        }
    }
}

public struct PairingMessageCodec: ContentCodec {
    public typealias T = PairingMessageContent

    public var contentType: ContentTypeID = ContentTypePairingMessage

    public init() {}

    public func encode(content: PairingMessageContent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypePairingMessage
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> PairingMessageContent {
        guard !content.content.isEmpty else {
            throw PairingMessageCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(PairingMessageContent.self, from: content.content)
        } catch {
            throw PairingMessageCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: PairingMessageContent) throws -> String? {
        nil
    }

    public func shouldPush(content: PairingMessageContent) throws -> Bool {
        false
    }
}
