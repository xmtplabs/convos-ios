import ConvosMessagingProtocols
import Foundation

/// Projects a `MessagingReaction` onto the user-visible emoji glyph
/// Convos stores in `DBMessage.emoji`.
///
/// Stage 2 migration (audit §5): this replaces the pre-existing
/// `extension XMTPiOS.Reaction { var emoji }` so the rendering rule
/// (U+XXXX hex-code -> UnicodeScalar for `.unicode`-schema reactions,
/// raw content otherwise) lives on the Convos-owned struct. The
/// XMTPiOS boundary now only carries the shape conversion — see
/// `Storage/XMTP DB Representations/Reaction+DBRepresentation.swift`.
extension MessagingReaction {
    /// Returns the glyph Convos wants to display for this reaction.
    ///
    /// For `.unicode`-schema reactions the `content` is the U+XXXX
    /// hex-code form; the caller expects the decoded UnicodeScalar.
    /// For every other schema (including `.shortcode`, `.custom`,
    /// `.unknown`) the raw `content` string is used verbatim, which
    /// matches the prior XMTPiOS extension behavior.
    public var emoji: String {
        switch schema {
        case .unicode:
            if let scalarValue = UInt32(content.replacingOccurrences(of: "U+", with: ""), radix: 16),
               let scalar = UnicodeScalar(scalarValue) {
                return String(scalar)
            }
        default:
            break
        }
        return content
    }
}
