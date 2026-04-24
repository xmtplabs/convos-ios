import ConvosCore
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingDeviceSync`.
///
/// DTU's engine does not model device-sync archives, sync-group
/// replication, or pin-based archive transfer — every method here
/// throws `DTUMessagingNotSupportedError` with a descriptive reason.
///
/// Convos today sets `deviceSyncEnabled: false` in
/// `InboxStateMachine.swift:1119`, so these methods are not called on
/// the production path. They're in the abstraction from day one per
/// audit §1.6 so the Stage 5+ multi-installation work doesn't need a
/// new protocol; the DTU adapter stays correct for that Stage 5+
/// scenario as long as Convos keeps device-sync off.
public final class DTUMessagingDeviceSync: MessagingDeviceSync, @unchecked Sendable {
    let context: DTUMessagingClientContext

    public init(context: DTUMessagingClientContext) {
        self.context = context
    }

    public func sendSyncRequest(
        options: MessagingArchiveOptions,
        serverUrl: String?
    ) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingDeviceSync.sendSyncRequest",
            reason: "DTU engine does not model device-sync requests"
        )
    }

    public func sendSyncArchive(
        options: MessagingArchiveOptions,
        serverUrl: String?,
        pin: String
    ) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingDeviceSync.sendSyncArchive",
            reason: "DTU engine does not model pinned sync archives"
        )
    }

    public func processSyncArchive(pin: String?) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingDeviceSync.processSyncArchive",
            reason: "DTU engine does not model pinned sync archives"
        )
    }

    public func syncAllDeviceSyncGroups() async throws -> MessagingSyncSummary {
        throw DTUMessagingNotSupportedError(
            method: "MessagingDeviceSync.syncAllDeviceSyncGroups",
            reason: "DTU engine does not model device-sync groups"
        )
    }

    public func createArchive(
        path: String,
        encryptionKey: Data,
        options: MessagingArchiveOptions
    ) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingDeviceSync.createArchive",
            reason: "DTU engine does not model archive export"
        )
    }

    public func importArchive(
        path: String,
        encryptionKey: Data
    ) async throws {
        throw DTUMessagingNotSupportedError(
            method: "MessagingDeviceSync.importArchive",
            reason: "DTU engine does not model archive import"
        )
    }
}
