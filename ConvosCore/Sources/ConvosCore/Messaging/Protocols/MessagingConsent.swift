import Foundation

// MARK: - Consent state

/// Convos-owned mirror of `XMTPiOS.ConsentState`.
///
/// Note: Convos already defines a user-facing `Consent` enum in
/// `Storage/Models/Consent.swift` with identical cases. The abstraction
/// introduces a separate type on the messaging-protocol boundary so
/// that the direction of mapping can flip: Convos' `Consent` stays as
/// the GRDB / UI model, and the XMTPiOS adapter becomes responsible
/// for bridging to/from `MessagingConsentState`.
public enum MessagingConsentState: String, Hashable, Sendable, Codable {
    case allowed
    case denied
    case unknown
}

// MARK: - Consent record

/// The entity a consent entry is keyed on.
public enum MessagingConsentEntity: Hashable, Sendable {
    case conversationId(String)
    case inboxId(MessagingInboxID)
}

/// A single consent record, used by `MessagingConsent.set(records:)`
/// and by device-sync replication.
public struct MessagingConsentRecord: Hashable, Sendable {
    public let entity: MessagingConsentEntity
    public let state: MessagingConsentState

    public init(entity: MessagingConsentEntity, state: MessagingConsentState) {
        self.entity = entity
        self.state = state
    }
}

// MARK: - Consent API

/// Read / write consent and kick off preference replication.
///
/// Surfaced on `MessagingClient.consent`. Stage 1 only declares the
/// protocol; Stage 2 provides the XMTPiOS-backed conformer.
public protocol MessagingConsent: Sendable {
    func set(records: [MessagingConsentRecord]) async throws
    func conversationState(id: String) async throws -> MessagingConsentState
    func inboxIdState(_ inboxId: MessagingInboxID) async throws -> MessagingConsentState
    func syncPreferences() async throws
}
