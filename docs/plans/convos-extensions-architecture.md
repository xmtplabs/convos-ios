# Convos Extensions Architecture Plan

> **Status**: In Progress (Invites ✅, Profiles ✅, Explode pending)  
> **Created**: 2026-02-25  
> **Updated**: 2026-02-26

## Executive Summary

Extract Convos-specific patterns (invites, profiles, explode) into reusable extensions that any XMTP integrator can adopt. This enables other apps to leverage Convos's privacy-focused patterns without replicating the implementation.

## Current State Analysis

### Convos-Specific Patterns

| Pattern | Description | XMTP Touchpoints |
|---------|-------------|------------------|
| **Invites** | Cryptographic tokens, DM-based join flow | DMs, Groups, Consent States |
| **Profiles** | Per-conversation identity storage | Group `appData` (8KB metadata) |
| **Explode** | Conversation expiration/deletion | Custom content type, Group metadata |

### Where These Live Now

**Extracted to packages (✅ complete):**

```
ConvosAppData/                          # Shared foundation (21 tests)
├── Proto/conversation_custom_metadata.pb.swift  # Protobuf types
├── AppDataSerialization.swift          # Base64URL, DEFLATE, compact encoding
└── ProfileHelpers.swift               # Profile collection helpers

ConvosInvites/                          # Invite system (120 tests)
├── ConvosInvitesCore/                  # Core crypto (no XMTP dependency)
│   ├── Core/InviteToken.swift          # ChaCha20-Poly1305 token encryption
│   ├── Core/InviteSigner.swift         # secp256k1 ECDSA signing
│   ├── Core/InviteEncoding.swift       # URL-safe Base64 + DEFLATE
│   ├── Core/Crypto.swift               # Key derivation, public key recovery
│   └── Core/Proto/invite.pb.swift      # Invite protobuf schema
└── ConvosInvites/                      # XMTP integration layer
    ├── InviteCoordinator.swift         # High-level join request processing
    ├── InviteTagStorage.swift          # Tag storage in group appData
    ├── InviteClientProvider.swift      # XMTP client protocol
    └── ContentTypes/InviteJoinErrorCodec.swift  # Join error feedback

ConvosProfiles/                         # Profile system (25 tests)
├── Crypto/ImageEncryption.swift        # AES-256-GCM image encryption
└── Crypto/EncryptedImageLoader.swift   # Encrypted image loading protocol
```

**Still in ConvosCore (not yet extracted):**

```
ConvosCore/
├── Custom Content Types/
│   └── ExplodeSettingsCodec.swift      # Explosion notifications (future: ConvosExplode package)
├── Invites & Custom Metadata/
│   ├── SignedInvite+Signing.swift      # Slug generation (uses ConvosInvitesCore)
│   └── XMTPGroup+CustomMetadata.swift  # Metadata read/write (uses ConvosAppData)
└── Syncing/
    ├── InviteJoinRequestsManager.swift # Thin bridge (~80 lines) to InviteCoordinator
    └── InviteClientProviderAdapter.swift # Adapts XMTP client to InviteClientProvider
```

### XMTP SDK Architecture (libxmtp)

```
libxmtp/
├── crates/
│   ├── xmtp_mls/           # Core MLS client (groups, messages, sync)
│   ├── xmtp_content_types/ # Content codecs (text, reactions, attachments...)
│   ├── xmtp_db/            # Storage layer
│   └── xmtp_id/            # Identity management
├── bindings/mobile/        # FFI bindings (uniffi → iOS/Android)
└── sdks/ios/               # Swift wrapper over FFI
```

**Key insight:** Content types in libxmtp are modular (`xmtp_content_types` crate). We could follow this pattern for extensions.

## Design Options

### Option A: Swift-Only Extensions (Above SDK)

```
┌─────────────────────────────────────────────────┐
│              App (Convos, etc.)                 │
├─────────────────────────────────────────────────┤
│  ConvosInvites │ ConvosProfiles │ ConvosExplode │  ← Swift Packages
├─────────────────────────────────────────────────┤
│                   XMTPiOS SDK                   │
├─────────────────────────────────────────────────┤
│            libxmtp (Rust via FFI)               │
└─────────────────────────────────────────────────┘
```

**Pros:**
- Fastest to implement
- No changes to libxmtp
- Pure Swift, easy for iOS developers

**Cons:**
- iOS-only (Android would need separate Kotlin implementation)
- Can't leverage Rust's cryptography crates
- Harder to keep in sync across platforms

### Option B: Rust Extensions in libxmtp

```
libxmtp/crates/
├── xmtp_content_types/     # Existing
├── xmtp_invites/           # NEW: Invite token logic
├── xmtp_profiles/          # NEW: Per-conversation profiles  
└── xmtp_explode/           # NEW: Conversation expiration

bindings/mobile/src/
└── extensions/             # FFI bindings for extensions
```

**Pros:**
- Cross-platform (iOS, Android, WASM, Node)
- Leverage Rust crypto crates (same as libxmtp)
- Single implementation, consistent behavior

**Cons:**
- Requires changes to libxmtp repo
- Longer timeline
- Need buy-in from XMTP team

### Option C: Hybrid Approach (Recommended)

**Phase 1:** Swift-only extensions (quick win, validate API design)
**Phase 2:** Port to Rust once API is stable, contribute to libxmtp

```
Phase 1:                          Phase 2:
┌───────────────────┐            ┌───────────────────┐
│  ConvosExtensions │            │  xmtp_extensions  │
│   (Swift Pkg)     │     →      │   (Rust crate)    │
└─────────┬─────────┘            └─────────┬─────────┘
          │                                │
    ┌─────▼─────┐                    ┌─────▼─────┐
    │  XMTPiOS  │                    │  libxmtp  │
    └───────────┘                    └───────────┘
```

## Proposed Extension Architecture

### 1. Invites Extension

**Purpose:** Enable apps to create shareable invite links that:
- Encrypt conversation ID (only creator can derive key)
- Sign with creator's identity (prevents forgery)
- Support optional expiration and single-use flags
- Process join requests via DMs

**API Surface (Swift):**
```swift
public protocol InviteExtension {
    // Creation
    func createInvite(
        for group: XMTPGroup,
        name: String?,
        description: String?,
        imageURL: URL?,
        expiresAt: Date?,
        singleUse: Bool
    ) async throws -> InviteURL
    
    // Redemption  
    func redeemInvite(_ url: InviteURL) async throws -> JoinRequest
    
    // Processing (creator side)
    func processJoinRequests(
        in dm: XMTPDM,
        handler: JoinRequestHandler
    ) async throws
    
    // Revocation
    func revokeAllInvites(for group: XMTPGroup) async throws
}
```

**Dependencies on XMTP SDK:**
- Create/access DMs (for join request channel)
- Create/access Groups (for adding members)
- Read/write group `appData` (for invite tag)
- Manage consent states (for spam blocking)
- Access identity for signing

### 2. Profiles Extension

**Purpose:** Store per-conversation profiles in group metadata

**API Surface:**
```swift
public protocol ProfilesExtension {
    // Set my profile in a conversation
    func setMyProfile(
        in group: XMTPGroup,
        name: String?,
        avatarURL: URL?
    ) async throws
    
    // Get profiles for all members
    func getProfiles(
        in group: XMTPGroup
    ) async throws -> [InboxID: Profile]
    
    // Observe profile changes
    func observeProfiles(
        in group: XMTPGroup
    ) -> AsyncStream<[InboxID: Profile]>
}
```

**Dependencies:**
- Read/write group `appData`
- List group members

### 3. Explode Extension

**Purpose:** Enable conversation expiration with peer notification

**API Surface:**
```swift
public protocol ExplodeExtension {
    // Set expiration (notifies all members)
    func setExpiration(
        for group: XMTPGroup,
        expiresAt: Date
    ) async throws
    
    // Check if expired
    func isExpired(_ group: XMTPGroup) -> Bool
    
    // Observe expiration events
    func observeExpirations() -> AsyncStream<ExpirationEvent>
}
```

**Dependencies:**
- Custom content type (ExplodeSettings)
- Read/write group `appData`
- Send messages

## Required XMTP SDK Capabilities

For extensions to work, the SDK must expose:

| Capability | Current Status | Notes |
|------------|----------------|-------|
| Group `appData` read/write | ✅ Available | `group.updateAppData()` |
| DM creation by inbox ID | ✅ Available | `conversations.findOrCreateDm()` |
| Custom content types | ✅ Available | Register codecs |
| Consent state management | ✅ Available | `preferences.setConsentState()` |
| Member listing | ✅ Available | `group.members()` |
| Identity signing | ⚠️ Partial | Need key access for invite signing |
| Push notification options | ✅ Available | `shouldPush` in send options |

**Key insight:** Convos manages its own secp256k1 private keys in the iOS Keychain (separate from XMTP's identity). The XMTP SDK does expose `signWithInstallationKey()` but Convos uses raw key access for invite signing. Extensions would need to either:
- Use the SDK's signing capabilities (may require API additions)
- Manage their own keys (current approach, more complex)

## Migration Strategy

### Phase 1: Extract to Swift Packages ✅ Complete

1. ✅ Created `ConvosAppData` package (shared protobuf types, serialization)
2. ✅ Created `ConvosInvites` package (invite system, 120 tests)
3. ✅ Created `ConvosProfiles` package (image encryption, 25 tests)
4. ✅ Migrated ConvosCore to import from packages
5. ✅ Removed ~1,388 lines of duplicated code from ConvosCore
6. ✅ `InviteJoinRequestsManager` rewritten as thin bridge (~80 lines) to `InviteCoordinator`

**Not yet extracted:**
- ExplodeSettingsCodec (future ConvosExplode package)

### Phase 2: Stabilize & Document (in progress)

1. ✅ ConvosInvites README with full API reference
2. ✅ ADR 001 updated with package file references
3. ✅ ADR 005 updated with package file references
4. [ ] Gather feedback from potential adopters
5. [ ] Refine API based on feedback

### Phase 3: Rust Port (future, optional)

1. Propose architecture to XMTP team
2. Port cryptographic operations to Rust
3. Add FFI bindings
4. Create Swift/Kotlin wrappers
5. Deprecate Swift-only package

## Open Questions

1. **Invite Tag Storage:** Should tags be stored in group metadata (current) or a separate namespace?

2. **Profile Conflicts:** How to handle concurrent profile updates from multiple members?

3. **Explode Trust Model:** Should we add cryptographic enforcement (time-locks) or keep it trust-based?

4. **Extension Composition:** Can extensions be combined? (e.g., invite with profile preset)

5. **Versioning:** How to handle breaking changes to extension wire formats?

6. **Namespace:** Should extensions use `convos.org` authority or a neutral one like `xmtp.org/extensions`?

## Next Steps

1. [ ] Review this plan with stakeholders
2. [ ] Validate SDK capabilities (especially identity signing)
3. [ ] Create `ConvosExtensions` Swift package skeleton
4. [ ] Extract invite system first (most complex)
5. [ ] Write integration tests

## References

- [ADR 001: Invite System Architecture](../adr/001-invite-system-architecture.md)
- [ADR 002: Per-Conversation Identity Model](../adr/002-per-conversation-identity-model.md)
- [ADR 004: Explode Feature](../adr/004-explode-feature.md)
- [ADR 005: Profile Storage](../adr/005-profile-storage-in-conversation-metadata.md)
- [libxmtp README](https://github.com/xmtp/libxmtp)
