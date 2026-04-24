import Foundation
import GRDB
import XMTPiOS

/// Stage 2 migration proof-of-pattern (audit §5).
///
/// Before: this file exposed
/// `extension XMTPiOS.MessageDeliveryStatus { var status: MessageStatus }`
/// — a translator attached directly to the XMTPiOS enum.
///
/// After: the translator lives on the Convos-owned
/// `MessagingDeliveryStatus` (see
/// `Storage/Models/MessagingDeliveryStatus+MessageStatus.swift`).
/// This file now only holds the XMTPiOS → Messaging boundary mapper,
/// which is what the adapter layer will use in Stage 2/3. The single
/// remaining caller in
/// `Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift`
/// flows through `MessagingDeliveryStatus(ffiStatus)` → `.status`, so
/// all `MessageStatus` derivations are now expressed against the
/// abstraction and the DTU adapter can reuse them unchanged.
extension MessagingDeliveryStatus {
    /// Build a Convos-owned delivery status from the XMTPiOS enum.
    ///
    /// Kept as the only XMTPiOS-aware surface of this mapping so the
    /// eventual DTU adapter can build `MessagingDeliveryStatus`
    /// directly without re-implementing `.status`.
    init(_ xmtpDeliveryStatus: XMTPiOS.MessageDeliveryStatus) {
        switch xmtpDeliveryStatus {
        case .failed: self = .failed
        case .unpublished: self = .unpublished
        case .published: self = .published
        case .all: self = .all
        }
    }
}
