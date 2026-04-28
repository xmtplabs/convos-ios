import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeCapabilityRequest = ContentTypeID(
    authorityID: "convos.org",
    typeID: "capability_request",
    versionMajor: 1,
    versionMinor: 0
)

public enum CapabilityRequestCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "CapabilityRequest content is empty"
        case .invalidJSONFormat:
            "Invalid JSON format for CapabilityRequest"
        case .unsupportedVersion(let version):
            "Unsupported CapabilityRequest version \(version)"
        }
    }
}

public struct CapabilityRequestCodec: ContentCodec {
    public typealias T = CapabilityRequest

    public var contentType: ContentTypeID = ContentTypeCapabilityRequest

    public init() {}

    public func encode(content: CapabilityRequest) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeCapabilityRequest
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> CapabilityRequest {
        guard !content.content.isEmpty else {
            throw CapabilityRequestCodecError.emptyContent
        }
        let decoded: CapabilityRequest
        do {
            decoded = try JSONDecoder().decode(CapabilityRequest.self, from: content.content)
        } catch {
            throw CapabilityRequestCodecError.invalidJSONFormat
        }
        guard decoded.version <= CapabilityRequest.supportedVersion else {
            throw CapabilityRequestCodecError.unsupportedVersion(decoded.version)
        }
        return decoded
    }

    public func fallback(content: CapabilityRequest) throws -> String? {
        "The assistant is requesting access to your \(content.subject.displayName.lowercased())"
    }

    public func shouldPush(content: CapabilityRequest) throws -> Bool {
        false
    }
}
