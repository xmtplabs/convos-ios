import ConvosMessagingProtocols
import Foundation

/// Maps the abstraction-layer `MessagingDeliveryStatus` to the
/// GRDB-backed `DBMessage.status` value the UI binds to.
///
/// XMTPiOS-boundary translation
/// (`MessagingDeliveryStatus.from(XMTPiOS.MessageDeliveryStatus)`) lives
/// beside the rest of the adapter mappers in
/// `Storage/XMTP DB Representations/MessageDeliveryStatus+DBRepresentation.swift`.
/// Everything that derives a `MessageStatus` from a delivery signal
/// flows through this abstraction-only extension, which is also what
/// the DTU adapter uses without importing XMTPiOS.
extension MessagingDeliveryStatus {
    /// Projects the messaging-layer delivery status onto the local DB
    /// `MessageStatus` enum.
    ///
    /// `.all` is treated as `.unknown` to preserve the historical
    /// mapping from `XMTPiOS.MessageDeliveryStatus.all`, which was
    /// used as a query-filter sentinel rather than a real per-message
    /// state. If a DB row ever lands with `.all`, treating it as
    /// `.unknown` matches the prior behavior.
    public var status: MessageStatus {
        switch self {
        case .failed: return .failed
        case .unpublished: return .unpublished
        case .published: return .published
        case .all: return .unknown
        }
    }
}
