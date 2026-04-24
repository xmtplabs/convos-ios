import Foundation

/// Bridges Convos' user-facing `Consent` enum (GRDB / UI model) and
/// the abstraction-layer `MessagingConsentState` enum.
///
/// Stage 2 migration (audit §5, §1.4): the prior `Consent` extension
/// returned `XMTPiOS.ConsentState` directly, making every caller of
/// `consent.consentState` XMTPiOS-aware. After this migration the
/// direction is flipped — `Consent` maps to `MessagingConsentState`
/// on this side, and the XMTPiOS boundary mapping
/// (`MessagingConsentState <-> XMTPiOS.ConsentState`) lives beside
/// the rest of the XMTPiOS adapter code in
/// `Storage/Repositories/DB XMTP Representations/Consent+ConsentState.swift`.
extension Consent {
    /// Projects Convos' `Consent` onto the messaging-layer enum.
    public var messagingConsentState: MessagingConsentState {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

extension MessagingConsentState {
    /// Projects the messaging-layer `MessagingConsentState` onto
    /// Convos' `Consent` (the GRDB / UI model).
    public var consent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}
