import ConvosMessagingProtocols
import XMTPiOS

/// XMTPiOS <-> `MessagingConsentState` boundary. Convos' `Consent`
/// maps to the abstraction layer via
/// `Storage/Models/MessagingConsentState+Consent.swift`; adapter calls
/// into the SDK go through `xmtpConsentState`.
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
