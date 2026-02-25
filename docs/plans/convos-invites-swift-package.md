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
- 65 tests covering all core functionality

### ✅ Phase 2: XMTP Integration

- Created `ConvosInvites` module with XMTP SDK integration
- Implemented:
  - `InviteCoordinator.swift` - High-level API
  - `InviteTagStorage.swift` - Tag storage in group appData
  - `Models.swift` - InviteOptions, JoinRequest, JoinResult, etc.
- 4 tests for integration layer

### ✅ Phase 3: ConvosCore Migration

- Added ConvosInvites as dependency in ConvosCore
- Removed 10 files from ConvosCore (now in package)
- Updated all imports to use ConvosInvites
- Moved 61 tests from ConvosCore to ConvosInvites
- Net reduction: ~1000 lines of code in ConvosCore

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
│   ├── ConvosInvitesCore/     # Core crypto (no XMTP)
│   │   ├── InviteToken.swift
│   │   ├── InviteSigner.swift
│   │   ├── InviteEncoding.swift
│   │   └── Proto/invite.pb.swift
│   │
│   └── ConvosInvites/         # XMTP integration
│       ├── InviteCoordinator.swift
│       ├── InviteTagStorage.swift
│       └── Models.swift
│
└── Tests/
    ├── ConvosInvitesCoreTests/  # 65 tests
    └── ConvosInvitesTests/      # 4 tests
```

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
