# XMTP Invites Swift Package Design

> **Status**: Planning  
> **Created**: 2026-02-25

## Overview

Extract the Convos invite system into a reusable Swift package (`ConvosInvites`) that any XMTP iOS app can adopt.

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                        App Layer                                │
│  (Convos: UI, DB models, repositories, state machines)          │
├─────────────────────────────────────────────────────────────────┤
│                    ConvosInvites Package                          │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │ Invite Tokens   │  │ Join Coordinator │  │ Custom Codecs  │  │
│  │ (crypto only)   │  │ (XMTP integration)│  │ (error types)  │  │
│  └─────────────────┘  └──────────────────┘  └────────────────┘  │
├─────────────────────────────────────────────────────────────────┤
│                       XMTPiOS SDK                               │
└─────────────────────────────────────────────────────────────────┘
```

## Package Structure

```
ConvosInvites/
├── Package.swift
├── Sources/
│   └── ConvosInvites/
│       ├── Core/                           # Pure crypto, no XMTP dependency
│       │   ├── InviteToken.swift           # Token encryption/decryption
│       │   ├── InviteSigner.swift          # Signing & verification
│       │   ├── InvitePayload.swift         # Payload structure
│       │   ├── InviteEncoding.swift        # URL-safe encoding
│       │   └── Proto/
│       │       └── invite.pb.swift         # Protobuf definitions
│       │
│       ├── XMTP/                           # XMTP SDK integration
│       │   ├── InviteCoordinator.swift     # High-level API
│       │   ├── JoinRequestProcessor.swift  # Process incoming join requests
│       │   ├── InviteTagStorage.swift      # Read/write invite tags in appData
│       │   └── InviteJoinErrorCodec.swift  # Custom content type
│       │
│       └── Models/                         # Public types
│           ├── Invite.swift                # Invite model
│           ├── JoinRequest.swift           # Join request model
│           └── InviteError.swift           # Error types
│
└── Tests/
    └── ConvosInvitesTests/
        ├── InviteTokenTests.swift
        ├── InviteSignerTests.swift
        └── InviteCoordinatorTests.swift
```

## API Design

### 1. Core Layer (No XMTP Dependency)

These are pure functions that handle cryptography. Apps could use these directly if they want custom integration.

```swift
// MARK: - Token Creation & Decryption

public enum InviteToken {
    /// Create an encrypted conversation token
    public static func encrypt(
        conversationId: String,
        creatorInboxId: String,
        privateKey: Data
    ) throws -> Data
    
    /// Decrypt a conversation token
    public static func decrypt(
        tokenBytes: Data,
        creatorInboxId: String,
        privateKey: Data
    ) throws -> String
}

// MARK: - Signing & Verification

public struct InviteSigner {
    /// Sign an invite payload
    public static func sign(
        payload: InvitePayload,
        privateKey: Data
    ) throws -> Data
    
    /// Verify signature and recover public key
    public static func verify(
        signature: Data,
        payload: InvitePayload
    ) throws -> Data  // Returns recovered public key
}

// MARK: - URL-Safe Encoding

public struct InviteEncoder {
    /// Encode a signed invite to URL-safe string
    public static func encode(_ signedInvite: SignedInvite) throws -> String
    
    /// Decode from URL-safe string
    public static func decode(_ slug: String) throws -> SignedInvite
}
```

### 2. XMTP Integration Layer

High-level API for apps using XMTPiOS.

```swift
/// Coordinates invite creation and join request processing
public actor InviteCoordinator {
    
    // MARK: - Initialization
    
    public init(
        client: XMTPiOS.Client,
        privateKey: Data,
        delegate: InviteCoordinatorDelegate?
    )
    
    // MARK: - Invite Creation
    
    /// Create a shareable invite URL for a group
    public func createInvite(
        for group: XMTPiOS.Group,
        options: InviteOptions
    ) async throws -> InviteURL
    
    /// Revoke all invites for a group (generates new invite tag)
    public func revokeInvites(
        for group: XMTPiOS.Group
    ) async throws
    
    // MARK: - Join Request Sending (Joiner Side)
    
    /// Send a join request to the invite creator
    public func sendJoinRequest(
        invite: SignedInvite
    ) async throws -> PendingJoinRequest
    
    // MARK: - Join Request Processing (Creator Side)
    
    /// Process all pending join requests across DMs
    public func processPendingJoinRequests() async throws -> [JoinResult]
    
    /// Process a single incoming DM message as a potential join request
    public func processMessage(
        _ message: XMTPiOS.DecodedMessage
    ) async throws -> JoinResult?
    
    // MARK: - Streaming
    
    /// Stream join request results as they're processed
    public func streamJoinResults() -> AsyncStream<JoinResult>
}

// MARK: - Supporting Types

public struct InviteOptions {
    public var name: String?
    public var description: String?
    public var imageURL: URL?
    public var expiresAt: Date?
    public var singleUse: Bool
    public var includePublicPreview: Bool
    
    public init(...)
}

public struct InviteURL {
    public let url: URL
    public let slug: String
    public let signedInvite: SignedInvite
}

public struct JoinResult {
    public let conversationId: String
    public let joinerInboxId: String
    public let conversationName: String?
}

public enum JoinError: Error {
    case invalidSignature
    case expired
    case conversationNotFound
    case conversationExpired
    case alreadyMember
}

// MARK: - Delegate

public protocol InviteCoordinatorDelegate: AnyObject {
    /// Called when a join request is received
    func coordinator(_ coordinator: InviteCoordinator, didReceiveJoinRequest request: JoinRequest)
    
    /// Called when a member is successfully added
    func coordinator(_ coordinator: InviteCoordinator, didAddMember inboxId: String, to conversationId: String)
    
    /// Called when a join request fails
    func coordinator(_ coordinator: InviteCoordinator, didFailJoinRequest request: JoinRequest, error: JoinError)
    
    /// Called when an invalid join request triggers spam blocking
    func coordinator(_ coordinator: InviteCoordinator, didBlockSpammer inboxId: String)
}
```

### 3. Invite Tag Storage

Abstraction for storing invite tags in group metadata:

```swift
public protocol InviteTagStorage {
    func getInviteTag(for group: XMTPiOS.Group) throws -> String
    func setInviteTag(_ tag: String, for group: XMTPiOS.Group) async throws
    func generateNewInviteTag(for group: XMTPiOS.Group) async throws -> String
}

/// Default implementation using XMTP appData
public struct XMTPInviteTagStorage: InviteTagStorage {
    // Uses group.appData to store/retrieve invite tags
    // Handles protobuf serialization
}
```

## Migration Path for Convos

### Phase 1: Extract Core Crypto (1-2 weeks)

1. Create `ConvosInvites` Swift package in a new repo or as a local package
2. Move these files (with minimal changes):
   - `InviteConversationToken.swift` → `Core/InviteToken.swift`
   - `SignedInvite+Signing.swift` → `Core/InviteSigner.swift`
   - `SignedInvite+Validation.swift` → `Core/InviteSigner.swift`
   - `SignedInvite+Encoding.swift` → `Core/InviteEncoding.swift`
   - `InvitePayload+*.swift` → `Core/InvitePayload.swift`
   - `invite.pb.swift` → `Core/Proto/invite.pb.swift`
   - `Data+InviteCrypto.swift` → `Core/Crypto.swift`
3. Add tests for core layer

### Phase 2: Extract XMTP Integration (2-3 weeks)

1. Create `InviteCoordinator` wrapping `InviteJoinRequestsManager` logic
2. Create `XMTPInviteTagStorage` from `XMTPGroup+CustomMetadata` invite tag parts
3. Move `InviteJoinErrorCodec.swift`
4. Define delegate protocol for app callbacks

### Phase 3: Update Convos to Use Package (1-2 weeks)

1. Add `ConvosInvites` package dependency to ConvosCore
2. Replace direct usage with `InviteCoordinator`
3. Implement `InviteCoordinatorDelegate` for app-specific behavior
4. Remove extracted code from ConvosCore

## Dependencies

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/xmtp/libxmtp", ...),  // XMTPiOS
    .package(url: "https://github.com/apple/swift-protobuf", ...),
    .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", ...),
]
```

## Key Design Decisions

### 1. Private Key Management

**Current Convos approach:** Manages its own secp256k1 keys in iOS Keychain, separate from XMTP identity.

**Package approach:** Accept private key as parameter, don't manage storage.

```swift
// App is responsible for key storage
let privateKey = try keychain.getPrivateKey(for: inboxId)
let coordinator = InviteCoordinator(client: client, privateKey: privateKey, delegate: self)
```

**Rationale:** Different apps may have different key storage requirements (Keychain, Secure Enclave, HSM, etc.)

### 2. Invite Tag Namespace

**Decision:** Use a dedicated namespace in appData to avoid conflicts with other metadata.

```protobuf
message InviteMetadata {
    string tag = 1;
    // Future: could add more invite-specific fields
}
```

**Stored at key:** `"xmtp.invites.v1"` in group appData

### 3. Spam Blocking Behavior

**Decision:** Make spam blocking configurable via delegate.

```swift
// Default: block on invalid signature
// App can override:
func coordinator(_ coordinator: InviteCoordinator, shouldBlockSpammer inboxId: String) -> Bool {
    // Custom logic (e.g., allowlist certain inboxes)
    return true
}
```

### 4. Error Feedback

**Decision:** Include `InviteJoinErrorCodec` in the package so join failures can be communicated back to the joiner.

## Open Questions

1. **Package location:** Separate repo (`xmtp-invites-swift`) or part of Convos repo initially?

2. **Versioning:** How to handle breaking changes to invite format? (Current: version byte in token)

3. **Content type authority:** Keep `convos.org` or use neutral `xmtp.org/invites`?

4. **Single-use enforcement:** Currently honor system. Should we add server-side tracking option?

## Test Strategy

### Unit Tests (Core Layer)
- Token encryption/decryption roundtrip
- Signature creation/verification
- URL encoding/decoding
- Expiration checking
- Edge cases (empty strings, max lengths, malformed data)

### Integration Tests (XMTP Layer)
- Create invite → send join request → process → add member
- Revocation (new tag invalidates old invites)
- Spam blocking on invalid signatures
- Error feedback delivery

### Compatibility Tests
- Invites created by old versions can be read by new
- Wire format stability

## Timeline

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| 1. Core extraction | 1-2 weeks | Crypto layer with tests |
| 2. XMTP integration | 2-3 weeks | Full coordinator API |
| 3. Convos migration | 1-2 weeks | Convos using package |
| 4. Documentation | 1 week | README, API docs, examples |

**Total: 5-8 weeks**

## References

- [ADR 001: Invite System Architecture](../adr/001-invite-system-architecture.md)
- [Current implementation](../../ConvosCore/Sources/ConvosCore/Invites%20&%20Custom%20Metadata/)
