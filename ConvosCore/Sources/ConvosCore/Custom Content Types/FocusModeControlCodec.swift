import Foundation
@preconcurrency import XMTPiOS

public struct FocusModeControl: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case start, stop
    }

    public let state: State
    public let focusedInboxId: String?
    public let sessionId: String

    public init(state: State, focusedInboxId: String?, sessionId: String) {
        self.state = state
        self.focusedInboxId = focusedInboxId
        self.sessionId = sessionId
    }
}

public let ContentTypeFocusModeControl = ContentTypeID(
    authorityID: "convos.org",
    typeID: "focus_mode_control",
    versionMajor: 1,
    versionMinor: 0
)

public enum FocusModeControlCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "FocusModeControl content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for FocusModeControl"
        }
    }
}

public struct FocusModeControlCodec: ContentCodec {
    public typealias T = FocusModeControl

    public var contentType: ContentTypeID = ContentTypeFocusModeControl

    public init() {}

    public func encode(content: FocusModeControl) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeFocusModeControl
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> FocusModeControl {
        guard !content.content.isEmpty else {
            throw FocusModeControlCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(FocusModeControl.self, from: content.content)
        } catch {
            throw FocusModeControlCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: FocusModeControl) throws -> String? {
        nil
    }

    public func shouldPush(content: FocusModeControl) throws -> Bool {
        false
    }
}
