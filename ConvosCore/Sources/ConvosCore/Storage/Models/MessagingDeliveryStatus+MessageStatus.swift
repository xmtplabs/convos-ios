import ConvosMessagingProtocols
import Foundation

/// Maps the abstraction-layer `MessagingDeliveryStatus` to the
/// GRDB-backed `DBMessage.status` value the UI binds to.
///
/// Stage 2 migration proof-of-pattern (audit §5): replaces the
/// pre-existing `extension XMTPiOS.MessageDeliveryStatus { var status }`
/// with an extension on the Convos-owned enum. The XMTPiOS-boundary
/// translation now lives in
/// `Storage/XMTP DB Representations/MessageDeliveryStatus+DBRepresentation.swift`
/// as a one-way mapper (`MessagingDeliveryStatus.from(_:)`). Everything
/// that derives a `MessageStatus` from a delivery signal now flows
/// through this abstraction-only extension, which is what the DTU
/// adapter will also use without importing XMTPiOS.
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
