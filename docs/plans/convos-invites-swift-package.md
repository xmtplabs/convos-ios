# ConvosInvites Swift Package Design

> **Status**: ✅ Complete  
> **Created**: 2025-02-25  
> **Completed**: 2025-02-25

## Summary

Extracted the Convos invite system into a reusable Swift package (`ConvosInvites`) that any XMTP iOS app can adopt.

## Package Location

`/Users/jarod/Code/convos-ios/ConvosInvites/`

See [ConvosInvites/README.md](../../ConvosInvites/README.md) for full documentation.

## Completed Phases

### ✅ Phase 1: Core Crypto Extraction

- Created `ConvosInvitesCore` module with no XMTP dependency
- Implemented:
  - `InviteToken.swift` - ChaCha20-Poly1305 token encryption
  - `InviteSigner.swift` - secp256k1 ECDSA signing
  - `InviteEncoding.swift` - URL-safe Base64 + DEFLATE
  - `InviteError.swift` - Error types
  - `InvitePayloadExtensions.swift` - Protobuf accessors
  - `Proto/invite.pb.swift` - Protobuf definitions
- Tests covering all core functionality

### ✅ Phase 2: XMTP Integration

- Created `ConvosInvites` module with XMTP SDK integration
- Implemented:
  - `InviteCoordinator.swift` - High-level join request processing (client per call, `@unchecked Sendable`)
  - `InviteTagStorage.swift` - Tag storage in group appData (uses `SecRandomCopyBytes`)
  - `InviteClientProvider.swift` - Protocol for XMTP client abstraction
  - `ContentTypes/InviteJoinErrorCodec.swift` - Join error feedback content type
  - `Models.swift` - InviteOptions, JoinRequest, JoinResult, JoinRequestError, etc.

### ✅ Phase 3: ConvosCore Migration

- Added ConvosInvites as dependency in ConvosCore
- Removed duplicated files from ConvosCore (now in package)
- `InviteJoinRequestsManager` rewritten as thin bridge (~80 lines) to `InviteCoordinator`
- `InviteClientProviderAdapter` bridges XMTP client to `InviteClientProvider` protocol
- Net reduction: ~1,388 lines of code removed from ConvosCore

### ✅ Phase 4: Documentation

- Created comprehensive README.md with:
  - Installation instructions
  - Quick start examples
  - Architecture diagram
  - Complete API reference
  - Security considerations
  - Testing instructions

## Architecture

```
ConvosInvites/
├── Sources/
│   ├── ConvosInvitesCore/           # Core crypto (no XMTP dependency)
│   │   ├── Core/
│   │   │   ├── InviteToken.swift         # ChaCha20-Poly1305 token encryption
│   │   │   ├── InviteSigner.swift        # secp256k1 ECDSA signing
│   │   │   ├── InviteEncoding.swift      # URL-safe Base64 + DEFLATE
│   │   │   ├── Crypto.swift              # Key derivation, public key recovery
│   │   │   ├── InviteError.swift         # Error types
│   │   │   ├── InvitePayloadExtensions.swift  # Protobuf accessors
│   │   │   └── Proto/invite.pb.swift     # Protobuf definitions
│   │   └── ConvosInvitesCore.swift       # Module exports
│   │
│   └── ConvosInvites/               # XMTP integration layer
│       ├── InviteCoordinator.swift        # High-level join request processing
│       ├── InviteClientProvider.swift      # XMTP client protocol
│       ├── InviteTagStorage.swift         # Tag storage in group appData
│       ├── Models.swift                   # Options, results, errors
│       ├── ContentTypes/
│       │   └── InviteJoinErrorCodec.swift # Join error content type
│       └── ConvosInvites.swift            # Module exports
│
└── Tests/
    ├── ConvosInvitesCoreTests/      # 91 tests
    └── ConvosInvitesTests/          # 29 tests
```

**Total: 120 tests**

## Key Design Decisions

1. **Two products**: `ConvosInvitesCore` (no XMTP) and `ConvosInvites` (full integration)
2. **Private key management**: Package accepts keys as parameters, apps manage storage
3. **Package visibility**: Used Swift 6 `package` access for internal helpers
4. **URL formats**: Supports all Convos URL schemes (legacy and current)
5. **Backward compatibility**: Added `description_p` alias for protobuf naming

## Future Work

- Split to separate repository when ready to share externally
- Consider Rust port for cross-platform compatibility
- Apply same pattern to Profiles and Explode features

## References

- [ADR 001: Invite System Architecture](../adr/001-invite-system-architecture.md)
- [ConvosInvites README](../../ConvosInvites/README.md)
- [Convos Extensions Architecture](./convos-extensions-architecture.md)
