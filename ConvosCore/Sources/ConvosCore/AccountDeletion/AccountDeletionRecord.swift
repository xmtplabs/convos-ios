import Foundation

/// Phase of an in-flight account deletion. The durable record carrying this
/// phase is written before the first backend request, so every crash window
/// has a defined recovery (see `AccountDeletionStateStore`).
///
/// `completed` is not a phase: completion clears the record as the final act
/// of the local wipe, so "no record" means "no deletion in flight".
public enum AccountDeletionPhase: String, Codable, Sendable, CaseIterable {
    /// Written before the deletion request is sent. Keys are intact; the
    /// backend outcome is unknown until a response (or a terminal
    /// identity-deleted signal during recovery) arrives.
    case requested
    /// The backend confirmed the deletion (endpoint success, or the terminal
    /// identity-deleted response during recovery). Local identity keys still
    /// exist so best-effort protocol teardown can run.
    case backendConfirmed = "backend_confirmed"
    /// The manifest-driven local wipe is in progress. No backend auth is
    /// needed or possible past this point.
    case localWipePending = "local_wipe_pending"

    /// Legal forward transitions. Re-writing the same phase is allowed by the
    /// store (idempotent updates); going backwards is not.
    public func canTransition(to next: AccountDeletionPhase) -> Bool {
        switch (self, next) {
        case (.requested, .backendConfirmed),
             (.backendConfirmed, .localWipePending):
            return true
        case (.requested, .requested),
             (.backendConfirmed, .backendConfirmed),
             (.localWipePending, .localWipePending):
            return true
        default:
            return false
        }
    }
}

/// Durable record of an in-flight account deletion, persisted as JSON in the
/// app-group container before the first backend request.
///
/// Carries only the non-secret identifiers recovery needs to finish the job:
/// the operation id the backend can resolve an ambiguous outcome against, the
/// wipe-manifest version to resume from, and the identifiers of the keychain
/// slots to clear (the SIWE JWT and account-id slots are scoped by device id
/// and Ethereum address, which can no longer be derived once the identity key
/// is gone).
public struct AccountDeletionRecord: Codable, Equatable, Sendable {
    /// Schema version of this record itself.
    public static let currentVersion: Int = 1

    public let version: Int
    public private(set) var phase: AccountDeletionPhase
    /// Client-generated id sent with the deletion request, so an ambiguous
    /// outcome can be resolved against the backend's deletion record instead
    /// of guessed.
    public let operationId: UUID
    /// Version of the wipe manifest to execute; pinned at request time so a
    /// resume after an app update still runs the manifest the deletion
    /// started with (newer entries are additive and idempotent, so resuming
    /// on a newer version is also safe).
    public let wipeManifestVersion: Int
    public let inboxId: String
    public let clientId: String
    /// Lowercased Ethereum address of the identity; needed to reconstruct the
    /// address-scoped keychain slot names during the wipe.
    public let ethAddress: String
    public let deviceId: String
    public let requestedAt: Date
    public private(set) var backendConfirmedAt: Date?
    public private(set) var wipeStartedAt: Date?

    public init(
        operationId: UUID,
        wipeManifestVersion: Int = WipeManifest.currentVersion,
        inboxId: String,
        clientId: String,
        ethAddress: String,
        deviceId: String,
        requestedAt: Date = Date(),
        phase: AccountDeletionPhase = .requested
    ) {
        self.version = Self.currentVersion
        self.phase = phase
        self.operationId = operationId
        self.wipeManifestVersion = wipeManifestVersion
        self.inboxId = inboxId
        self.clientId = clientId
        self.ethAddress = ethAddress.lowercased()
        self.deviceId = deviceId
        self.requestedAt = requestedAt
        self.backendConfirmedAt = nil
        self.wipeStartedAt = nil
    }

    /// Returns a copy advanced to `next`, stamping the phase timestamp.
    /// Throws when the transition is illegal.
    public func advanced(to next: AccountDeletionPhase, at date: Date = Date()) throws -> AccountDeletionRecord {
        guard phase.canTransition(to: next) else {
            throw AccountDeletionStateStoreError.invalidTransition(from: phase, to: next)
        }
        var copy = self
        copy.phase = next
        switch next {
        case .requested:
            break
        case .backendConfirmed:
            if copy.backendConfirmedAt == nil {
                copy.backendConfirmedAt = date
            }
        case .localWipePending:
            if copy.wipeStartedAt == nil {
                copy.wipeStartedAt = date
            }
        }
        return copy
    }
}
