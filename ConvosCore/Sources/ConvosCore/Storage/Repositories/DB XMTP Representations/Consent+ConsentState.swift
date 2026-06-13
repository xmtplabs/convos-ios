import XMTPiOS

extension Consent {
    var consentState: XMTPiOS.ConsentState {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

extension XMTPiOS.ConsentState {
    /// Inverse of `Consent.consentState`. Used by inbound-conversation gates
    /// (`StreamProcessor`, `InboundConversationFilter`) that read XMTP's
    /// consent type and need to operate on our internal `Consent` enum.
    var asConsent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}
