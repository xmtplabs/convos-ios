# ADR 010: Public Preview Image Toggle for Invite Links

> **Status**: Accepted
> **Author**: @lourou
> **Created**: 2026-02-23

## Context

With encrypted group images, invite previews should not expose private media by default. At the same time, some communities want richer invite cards with a visible group photo.

We need a policy that is privacy-first by default while allowing explicit opt-in for public image previews.

## Decision

Add a user-controlled toggle to include a public invite preview image.

1. Default is `off` (private): only encrypted group image is uploaded/used.
2. When `on`, upload both:
   - encrypted image for members, and
   - unencrypted public image URL for invite preview payload.
3. Invite payload uses `publicImageURLString` only; encrypted image metadata remains member-only.
4. Turning toggle off clears public preview URL for future invites.

## Data Safety and Migration Guarantees

- Database migration is additive:
  - `publicImageURLString` (nullable)
  - `includeInfoInPublicPreview` (bool, default `false`)
- No destructive migration of existing image data.
- If toggle state changes, encrypted member path remains intact.
- Invite generation remains valid when public URL is absent.

## Consequences

### Positive

- Privacy-preserving default behavior.
- Explicit user control for preview visibility.
- Clean separation between member media and public invite media.

### Negative

- Additional upload/storage when toggle is on.
- More state transitions to test (on/off, image update while on/off).
- Potential user confusion if they expect private image to appear in public preview automatically.

## Rollout and Observability

- Add analytics/logging for toggle changes and dual-upload outcomes.
- Verify invite payload contains image only when toggle is enabled and URL exists.
- Monitor upload failures for encrypted and public paths separately.

## Related Files

- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift`
- `ConvosCore/Sources/ConvosCore/Storage/Migrations/*`
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift`
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift`
- `Convos/Conversation Detail/Settings/GroupSettingsView.swift`

## Related Decisions

- [ADR 009](./009-encrypted-conversation-images.md): encrypted image architecture
- [ADR 008](./008-asset-lifecycle-and-renewal.md): lifecycle and renewal of S3 assets

## References

- [Public Preview Image Toggle Plan](../plans/public-preview-image-toggle.md)
