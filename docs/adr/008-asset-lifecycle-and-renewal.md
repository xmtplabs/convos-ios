# ADR 008: Asset Lifecycle and Renewal Strategy

> **Status**: Accepted
> **Author**: @lourou
> **Created**: 2026-02-23

## Context

Convos stores chat images, profile images, and group images in S3. We needed a retention model that:

- reduces storage for inactive users,
- avoids leaking asset type through bucket structure,
- stays simple to operate,
- and keeps active users' important images available.

S3 lifecycle expiration is based on object age (`LastModified`). Updating tags or metadata does not reset lifecycle age.

## Decision

Adopt a single-bucket, single-rule lifecycle model:

1. All asset objects in S3 expire after 30 days.
2. No prefixes, tags, or metadata are used to classify asset type.
3. Profile and group images are renewed by the client every ~15 days via backend copy-to-self.
4. Chat images are never renewed and naturally expire.
5. Renewal is best-effort and non-blocking on app startup.
6. Renewal API accepts S3 keys (`POST /v2/assets/renew-batch`) and returns per-key outcomes, including `not_found` for expired objects.

## Data Safety and Migration Guarantees

- No data migration is required for existing assets.
- Lifecycle behavior is additive at infrastructure level (rule applies to all objects uniformly).
- Renewal failures do not block app launch.
- Expired asset handling is explicit: on confirmed `not_found`, local references are cleared so UI falls back to placeholder.
- If local cache exists for an expired asset, recovery may re-upload and restore a fresh URL.

## Consequences

### Positive

- Very simple infrastructure model.
- No asset-type leakage in URL structure.
- Active users keep profile/group images alive automatically.
- Inactive data is cleaned up without manual work.

### Negative

- Inactive users can lose remote profile/group images after 30+ days.
- If cache is unavailable at recovery time, user must re-upload.
- Additional periodic API/S3 renewal traffic.

## Rollout and Observability

- Validate behavior in staging with short lifecycle.
- Monitor renewal endpoint success/failure/`not_found` rates.
- Monitor object count trend and lifecycle deletions in S3.

## Related Files

- `ConvosCore/Sources/ConvosCore/Assets/AssetRenewalManager.swift`
- `ConvosCore/Sources/ConvosCore/Assets/AssetRenewalURLCollector.swift`
- `ConvosCore/Sources/ConvosCore/Assets/ExpiredAssetRecoveryHandler.swift`
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`

## Related Decisions

- [ADR 009](./009-encrypted-conversation-images.md): encrypted image model built on this storage lifecycle
- [ADR 010](./010-public-preview-image-toggle.md): optional public preview URL policy

## References

- [Asset Uploads Plan](../plans/asset-uploads.md)
- [Asset Renewal Plan](../plans/asset-renewal.md)
