import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeCapabilityRequestResult = ContentTypeID(
    authorityID: "convos.org",
    typeID: "capability_request_result",
    versionMajor: 1,
    versionMinor: 0
)

public enum CapabilityRequestResultCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            "CapabilityRequestResult content is empty"
        case .invalidJSONFormat:
            "Invalid JSON format for CapabilityRequestResult"
        case .unsupportedVersion(let version):
            "Unsupported CapabilityRequestResult version \(version)"
        }
    }
}

public struct CapabilityRequestResultCodec: ContentCodec {
    public typealias T = CapabilityRequestResult

    public var contentType: ContentTypeID = ContentTypeCapabilityRequestResult

    public init() {}

    public func encode(content: CapabilityRequestResult) throws -> EncodedContent {
        var encodedContent = EncodedContent()
        encodedContent.type = ContentTypeCapabilityRequestResult
        encodedContent.content = try JSONEncoder().encode(content)
        return encodedContent
    }

    public func decode(content: EncodedContent) throws -> CapabilityRequestResult {
        guard !content.content.isEmpty else {
            throw CapabilityRequestResultCodecError.emptyContent
        }
        let decoded: CapabilityRequestResult
        do {
            decoded = try JSONDecoder().decode(CapabilityRequestResult.self, from: content.content)
        } catch {
            throw CapabilityRequestResultCodecError.invalidJSONFormat
        }
        guard decoded.version <= CapabilityRequestResult.supportedVersion else {
            throw CapabilityRequestResultCodecError.unsupportedVersion(decoded.version)
        }
        return decoded
    }

    public func fallback(content: CapabilityRequestResult) throws -> String? {
        switch content.status {
        case .approved:
            "Approved \(content.subject.displayName.lowercased()) access"
        case .denied:
            "Declined \(content.subject.displayName.lowercased()) access"
        case .cancelled:
            "Cancelled \(content.subject.displayName.lowercased()) access request"
        }
    }

    public func shouldPush(content: CapabilityRequestResult) throws -> Bool {
        false
    }
}
