import ConvosMessagingProtocols
import Foundation
import GRDB
import XMTPiOS

/// XMTPiOS → Messaging boundary mapper for delivery status. The
/// `MessageStatus` translator itself lives on the Convos-owned
/// `MessagingDeliveryStatus` (see
/// `Storage/Models/MessagingDeliveryStatus+MessageStatus.swift`); this
/// file is the only XMTPiOS-aware site, so the DTU adapter can build
/// `MessagingDeliveryStatus` directly without re-implementing `.status`.
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
