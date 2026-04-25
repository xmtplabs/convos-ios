import ConvosMessagingProtocols
import XMTPiOS

/// Stage 2 migration (audit §5, §1.4).
///
/// Before: this file held `extension Consent { var consentState: XMTPiOS.ConsentState }`
/// — a direct Convos -> XMTPiOS mapper that every caller had to
/// route through, making the XMTPiOS type visible to call sites
/// that had no other reason to import it.
///
/// After: this file only holds the XMTPiOS <-> `MessagingConsentState`
/// boundary. Convos' `Consent` now maps to the abstraction layer via
/// `Storage/Models/MessagingConsentState+Consent.swift`, and the one
/// remaining call site in
/// `Messaging/XMTPClientProvider.swift` threads through
/// `consent.messagingConsentState.xmtpConsentState` — same pattern
/// as the `MessagingDeliveryStatus(ffiStatus)` bridging used by the
/// delivery-status leaf. `XMTPClientProvider.swift` still imports
/// XMTPiOS (it is a Stage-3 seam rewrite), but the Consent surface
/// itself now routes through the abstraction.
extension MessagingConsentState {
    /// Build a messaging-layer consent state from the XMTPiOS enum.
    public init(_ xmtpConsentState: XMTPiOS.ConsentState) {
        switch xmtpConsentState {
        case .allowed: self = .allowed
        case .denied: self = .denied
        case .unknown: self = .unknown
        }
    }

    /// Project back to the XMTPiOS enum for adapter calls into the
    /// SDK. Only the XMTPiOS adapter should need this.
    public var xmtpConsentState: XMTPiOS.ConsentState {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}
