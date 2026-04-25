import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingConsent`.
///
/// Wraps `XMTPiOS.PrivatePreferences`. Convos' existing consent flow
/// in `XMTPClientProvider.swift:243-256` uses
/// `conversation.updateConsentState(state:)`; this API is the second
/// path — setting consent in bulk, querying state directly, and
/// kicking off preference-replication sync.
public final class XMTPiOSMessagingConsent: MessagingConsent, @unchecked Sendable {
    let xmtpPreferences: XMTPiOS.PrivatePreferences

    public init(xmtpPreferences: XMTPiOS.PrivatePreferences) {
        self.xmtpPreferences = xmtpPreferences
    }

    public func set(records: [MessagingConsentRecord]) async throws {
        let xmtpRecords = records.map { record -> XMTPiOS.ConsentRecord in
            switch record.entity {
            case .conversationId(let conversationId):
                return XMTPiOS.ConsentRecord(
                    value: conversationId,
                    entryType: .conversation_id,
                    consentType: record.state.xmtpConsentState
                )
            case .inboxId(let inboxId):
                return XMTPiOS.ConsentRecord(
                    value: inboxId,
                    entryType: .inbox_id,
                    consentType: record.state.xmtpConsentState
                )
            }
        }
        try await xmtpPreferences.setConsentState(entries: xmtpRecords)
    }

    public func conversationState(id: String) async throws -> MessagingConsentState {
        let xmtpState = try await xmtpPreferences.conversationState(conversationId: id)
        return MessagingConsentState(xmtpState)
    }

    public func inboxIdState(_ inboxId: MessagingInboxID) async throws -> MessagingConsentState {
        let xmtpState = try await xmtpPreferences.inboxIdState(inboxId: inboxId)
        return MessagingConsentState(xmtpState)
    }

    public func syncPreferences() async throws {
        try await xmtpPreferences.sync()
    }
}
