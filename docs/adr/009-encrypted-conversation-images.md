# ADR 009: Encrypted Conversation Images

> **Status**: Accepted
> **Author**: @lourou
> **Created**: 2026-02-23

## Context

Convos needs end-to-end confidentiality for profile pictures and group images. Profile avatars are transmitted via ProfileUpdate and ProfileSnapshot messages (see ADR 005) as `EncryptedProfileImageRef` references. Group images are stored in conversation metadata. The design must preserve backward compatibility and remain practical to ship and operate.

## Decision

Use one shared encryption key per conversation group and store encrypted image references in metadata.

1. Encrypt both profile images and group images using AES-256-GCM.
2. Store one group-level `imageEncryptionKey` in encrypted group metadata.
3. For each image, store `{ url, salt, nonce }` as `EncryptedImageRef`.
4. Derive per-image encryption keys using HKDF from the group key + salt.
5. Keep legacy image fields for backward compatibility during transition.
6. Do not rotate keys in v1 when members are removed; rely on XMTP metadata access control for future image authorization.

## Data Safety and Migration Guarantees

- Schema changes are additive (optional encrypted fields).
- Legacy image fields remain readable by old clients.
- New clients prefer encrypted fields but can fall back to legacy fields.
- Existing unencrypted images are not force-migrated; only new uploads use encrypted format.
- Decryption integrity is guaranteed by AES-GCM authentication tag.

## Consequences

### Positive

- Conversation images are confidential to members with metadata access.
- Compact metadata format with low per-image overhead.
- Minimal rollout risk due to backward-compatible reads.

### Negative

- No key rotation in v1 means removed members may still know historical group key material.
- More client complexity for encrypt/decrypt and metadata handling.
- Public invite preview images require a separate opt-in policy (ADR 010).

## Rollout and Observability

- Validate encrypt/decrypt round-trip in unit tests.
- Validate cross-member decrypt behavior in integration testing.
- Monitor image load/decrypt failures and metadata decode errors.

## Related Files

- `ConvosCore/Sources/ConvosCore/Profiles/Proto/profile_messages.proto` — `EncryptedProfileImageRef` for profile avatars
- `ConvosCore/Sources/ConvosCore/Profiles/Crypto/ImageEncryption.swift` — AES-256-GCM encrypt/decrypt
- `ConvosCore/Sources/ConvosCore/Storage/Writers/MyProfileWriter.swift` — encrypts and uploads profile avatars
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift` — group image encryption
- `ConvosCore/Sources/ConvosCore/Crypto/EncryptedImageService.swift` — encrypted image loading
- `Convos/Shared Views/AvatarView.swift`

## Related Decisions

- [ADR 008](./008-asset-lifecycle-and-renewal.md): retention and renewal behavior for stored assets
- [ADR 010](./010-public-preview-image-toggle.md): optional non-encrypted preview image for invites

## References

- [Encrypted Images Plan](../plans/encrypted-images.md)
