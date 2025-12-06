import Foundation
import XMTPiOS

public struct ExplodeSettings: Codable {
    public let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }
}

public let ContentTypeExplodeSettings = ContentTypeID(authorityID: "convos.org", typeID: "explode_settings", versionMajor: 1, versionMinor: 0)

public enum ExplodeSettingsCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "ExplodeSettings content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for ExplodeSettings"
        }
    }
}

public struct ExplodeSettingsCodec: ContentCodec {
    public typealias T = ExplodeSettings

    public var contentType: ContentTypeID = ContentTypeExplodeSettings

    public func encode(content: ExplodeSettings) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeExplodeSettings

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encodedContent.content = try encoder.encode(content)

        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> ExplodeSettings {
        guard !content.content.isEmpty else {
            throw ExplodeSettingsCodecError.emptyContent
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(ExplodeSettings.self, from: content.content)
        } catch {
            throw ExplodeSettingsCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: ExplodeSettings) throws -> String? {
        return "Conversation expires at \(content.expiresAt)"
    }

    public func shouldPush(content: ExplodeSettings) throws -> Bool {
        // Push to ensure all devices (including offline ones) receive the message
        // But the notification will be silently dropped (not shown to user)
        true
    }
}
