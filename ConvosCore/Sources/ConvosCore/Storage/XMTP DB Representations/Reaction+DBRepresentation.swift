import Foundation
import XMTPiOS

/// Stage 2 migration (audit §5).
///
/// Before: this file hosted
/// `extension XMTPiOS.Reaction { var emoji: String }` — a translator
/// attached directly to the XMTPiOS struct.
///
/// After: the emoji-projection logic lives on the Convos-owned
/// `MessagingReaction` (see
/// `Storage/Models/MessagingReaction+Emoji.swift`). This file now
/// only holds the XMTPiOS -> Messaging boundary initializer. The
/// single caller in
/// `Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift`
/// threads through `MessagingReaction(xmtpReaction).emoji`, matching
/// the `MessagingDeliveryStatus(ffiStatus).status` pattern already in
/// place for the delivery-status leaf.
extension MessagingReaction {
    /// Build a Convos-owned reaction value from the XMTPiOS struct.
    ///
    /// Kept as the only XMTPiOS-aware surface for this type so the
    /// eventual DTU adapter can populate `MessagingReaction` directly
    /// without re-implementing `emoji` or any other rendering rule.
    init(_ xmtpReaction: XMTPiOS.Reaction) {
        self.init(
            reference: xmtpReaction.reference,
            referenceInboxId: xmtpReaction.referenceInboxId,
            action: MessagingReaction.Action(xmtpReaction.action),
            content: xmtpReaction.content,
            schema: MessagingReaction.Schema(xmtpReaction.schema)
        )
    }
}

private extension MessagingReaction.Action {
    init(_ xmtpAction: XMTPiOS.ReactionAction) {
        switch xmtpAction {
        case .added: self = .added
        case .removed: self = .removed
        case .unknown: self = .unknown
        }
    }
}

private extension MessagingReaction.Schema {
    init(_ xmtpSchema: XMTPiOS.ReactionSchema) {
        switch xmtpSchema {
        case .unicode: self = .unicode
        case .shortcode: self = .shortcode
        case .custom: self = .custom
        case .unknown: self = .unknown
        }
    }
}
