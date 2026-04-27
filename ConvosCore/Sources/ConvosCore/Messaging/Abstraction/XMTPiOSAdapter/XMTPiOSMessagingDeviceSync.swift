import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingDeviceSync`.
///
/// Wraps the device-sync surface on `XMTPiOS.Client`. The abstraction
/// exposes it from day one so future multi-installation work does not
/// need to introduce a new API. Today `deviceSyncEnabled: false` on the
/// config (`InboxStateMachine.swift:1119`) means these methods are not
/// exercised in production; they are here for structural parity.
public final class XMTPiOSMessagingDeviceSync: MessagingDeviceSync, @unchecked Sendable {
    let xmtpClient: XMTPiOS.Client

    public init(xmtpClient: XMTPiOS.Client) {
        self.xmtpClient = xmtpClient
    }

    public func sendSyncRequest(
        options _: MessagingArchiveOptions,
        serverUrl _: String?
    ) async throws {
        // The pinned libxmtp SDK (ios-4.9.0-dev.88ddfad) exposes a
        // parameterless `sendSyncRequest()`; the options/serverUrl
        // arguments are no-ops at the current version.
        // FIXME(upstream): forward options and serverUrl once the
        // SDK catches up with the audit reference surface.
        try await xmtpClient.sendSyncRequest()
    }

    public func sendSyncArchive(
        options _: MessagingArchiveOptions,
        serverUrl _: String?,
        pin _: String
    ) async throws {
        // FIXME(upstream): `XMTPiOS.Client.sendSyncArchive` is not
        // available at the pinned SDK SHA. When the SDK is bumped to
        // match the audit reference, wire this through to the native
        // call. Today `deviceSyncEnabled: false` keeps this path out
        // of production anyway (InboxStateMachine.swift:1119).
        throw XMTPiOSDeviceSyncUnsupported.sendSyncArchive
    }

    public func processSyncArchive(pin _: String?) async throws {
        // FIXME(upstream): `XMTPiOS.Client.processSyncArchive` is not
        // available at the pinned SDK SHA.
        throw XMTPiOSDeviceSyncUnsupported.processSyncArchive
    }

    public func syncAllDeviceSyncGroups() async throws -> MessagingSyncSummary {
        // FIXME(upstream): `XMTPiOS.Client.syncAllDeviceSyncGroups` is
        // not available at the pinned SDK SHA. Return a no-op summary
        // that matches the shape the abstraction expects.
        return MessagingSyncSummary(numEligible: 0, numSynced: 0)
    }

    public func createArchive(
        path: String,
        encryptionKey: Data,
        options: MessagingArchiveOptions
    ) async throws {
        try await xmtpClient.createArchive(
            path: path,
            encryptionKey: encryptionKey,
            opts: options.xmtpArchiveOptions
        )
    }

    public func importArchive(
        path: String,
        encryptionKey: Data
    ) async throws {
        try await xmtpClient.importArchive(path: path, encryptionKey: encryptionKey)
    }
}

// MARK: - Unsupported operations

/// Thrown by device-sync methods that exist in the abstraction but not
/// in the pinned XMTPiOS SDK. Callers today should not invoke them
/// (`deviceSyncEnabled: false`); this makes the mismatch explicit.
enum XMTPiOSDeviceSyncUnsupported: Error, LocalizedError {
    case sendSyncArchive
    case processSyncArchive
    case syncAllDeviceSyncGroups

    var errorDescription: String? {
        switch self {
        case .sendSyncArchive:
            return "sendSyncArchive is not available in the pinned XMTPiOS SDK"
        case .processSyncArchive:
            return "processSyncArchive is not available in the pinned XMTPiOS SDK"
        case .syncAllDeviceSyncGroups:
            return "syncAllDeviceSyncGroups is not available in the pinned XMTPiOS SDK"
        }
    }
}

// MARK: - Archive options mapping

private extension MessagingArchiveOptions {
    /// Translation to the XMTPiOS native `ArchiveOptions`.
    ///
    /// The abstraction's includeConsent/includeMessages/includeHmacKeys
    /// flags map onto `ArchiveElement`; XMTPiOS currently supports
    /// `.messages` and `.consent` (no first-class hmac element — the
    /// hmac keys travel as part of the sync-groups flow). If both
    /// flags are false the archive is empty which the XMTPiOS SDK
    /// does not support; emit `[.messages, .consent]` as a safe
    /// default mirroring `ArchiveOptions.init(archiveElements:)`.
    var xmtpArchiveOptions: XMTPiOS.ArchiveOptions {
        var elements: [XMTPiOS.ArchiveElement] = []
        if includeMessages { elements.append(.messages) }
        if includeConsent { elements.append(.consent) }
        if elements.isEmpty { elements = [.messages, .consent] }
        return XMTPiOS.ArchiveOptions(
            startNs: startNs,
            endNs: endNs,
            archiveElements: elements
        )
    }
}
