import Foundation
@preconcurrency import XMTPiOS

public let ContentTypeDeviceRemoved = ContentTypeID(
    authorityID: "convos.org",
    typeID: "device_removed",
    versionMajor: 1,
    versionMinor: 0
)

/// Sent by the initiator of a `revokeInstallation(installationId:)` call
/// just before the libxmtp revoke API call lands. Both installations share
/// the same inbox so every conversation the inbox is in is observable by
/// the target installation; we send into one of those conversations. The
/// target installation's `StreamProcessor` recognizes the codec, checks
/// `revokedInstallationId` against its own `client.installationId`, and
/// if it matches transitions the session to `.error(DeviceReplacedError)`
/// — surfacing the `StaleDeviceBanner` without any periodic polling.
public struct DeviceRemovedContent: Codable, Sendable, Equatable {
    public let schemaVersion: UInt32
    public let revokedInstallationId: String
    public let removedAt: Int64

    public init(
        schemaVersion: UInt32 = 1,
        revokedInstallationId: String,
        removedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.schemaVersion = schemaVersion
        self.revokedInstallationId = revokedInstallationId
        self.removedAt = removedAt
    }
}

public enum DeviceRemovedCodecError: Error, LocalizedError {
    case emptyContent
    case invalidJSONFormat

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "DeviceRemoved content is empty"
        case .invalidJSONFormat:
            return "Invalid JSON format for DeviceRemoved"
        }
    }
}

public struct DeviceRemovedCodec: ContentCodec {
    public typealias T = DeviceRemovedContent

    public var contentType: ContentTypeID = ContentTypeDeviceRemoved

    public init() {}

    public func encode(content: DeviceRemovedContent) throws -> EncodedContent {
        var encoded = EncodedContent()
        encoded.type = ContentTypeDeviceRemoved
        encoded.content = try JSONEncoder().encode(content)
        return encoded
    }

    public func decode(content: EncodedContent) throws -> DeviceRemovedContent {
        guard !content.content.isEmpty else {
            throw DeviceRemovedCodecError.emptyContent
        }
        do {
            return try JSONDecoder().decode(DeviceRemovedContent.self, from: content.content)
        } catch {
            throw DeviceRemovedCodecError.invalidJSONFormat
        }
    }

    public func fallback(content: DeviceRemovedContent) throws -> String? {
        nil
    }

    public func shouldPush(content: DeviceRemovedContent) throws -> Bool {
        false
    }
}

public extension Notification.Name {
    /// Posted by `StreamProcessor` when a `DeviceRemovedContent` message
    /// arrives whose `revokedInstallationId` matches the receiving
    /// installation. `SessionStateMachine` observes this and transitions
    /// to `.error(DeviceReplacedError)` so the `StaleDeviceBanner`
    /// surfaces immediately — no polling required.
    static let installationWasRevokedByPeer = Notification.Name("convos.session.installationWasRevokedByPeer")
}
