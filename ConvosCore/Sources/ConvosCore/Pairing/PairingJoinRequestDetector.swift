import Foundation
@preconcurrency import XMTPiOS

/// A pairing join request that passed self-signature verification.
public struct VerifiedPairingJoinRequest: Sendable, Equatable {
    public let joinerInboxId: String
    public let deviceName: String
    public let slug: String

    public init(joinerInboxId: String, deviceName: String, slug: String) {
        self.joinerInboxId = joinerInboxId
        self.deviceName = deviceName
        self.slug = slug
    }
}

/// Shared verification for pairing join requests that arrive outside an
/// active pairing session - on the main message stream (`StreamProcessor`)
/// or in a push notification (the NSE's welcome and message paths).
///
/// Only requests whose embedded invite slug is signed by this inbox's own
/// identity key are surfaced: the iCloud-discovery joiner mints its slug
/// from the synced keychain backup and the QR flow signs its slug locally,
/// so both carry our signature, while a forged request can't - producing a
/// valid slug requires the private key. The address comparison anchors
/// that verification to our key: the slug's inboxId and address fields are
/// attacker-choosable, but the signature only ever recovers to the
/// signer's own address.
public enum PairingJoinRequestDetector {
    /// Returns the verified join request carried by `message`, or nil when
    /// the message isn't a pairing join request or fails verification.
    /// Decodes via the codec directly so it works on clients that never
    /// registered the pairing codecs (the NSE's).
    public static func verifiedJoinRequest(
        in message: DecodedMessage,
        identity: KeychainIdentity
    ) -> VerifiedPairingJoinRequest? {
        guard let typeId = try? message.encodedContent.type.typeID,
              typeId == ContentTypePairingJoinRequest.typeID,
              let content = try? PairingJoinRequestCodec().decode(content: message.encodedContent) else {
            return nil
        }
        guard verify(slug: content.slug, senderInboxId: message.senderInboxId, identity: identity) else {
            return nil
        }
        return VerifiedPairingJoinRequest(
            joinerInboxId: message.senderInboxId,
            deviceName: content.deviceName,
            slug: content.slug
        )
    }

    /// Pure verification core, separated from `DecodedMessage` extraction
    /// so it can be unit tested with minted slugs. True when `slug` is a
    /// valid, unexpired invite signed by `identity`'s own key and the
    /// sender isn't this inbox itself.
    public static func verify(
        slug: String,
        senderInboxId: String,
        identity: KeychainIdentity
    ) -> Bool {
        guard senderInboxId != identity.inboxId else { return false }
        guard let invite = try? PairingInvite.fromURLSafeSlug(slug) else { return false }
        return invite.initiatorInboxId == identity.inboxId
            && invite.initiatorAddress.lowercased() == identity.keys.privateKey.walletAddress.lowercased()
    }
}
