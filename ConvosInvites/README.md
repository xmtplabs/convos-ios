# ConvosInvites

A Swift package for creating and processing cryptographically secure invite links for XMTP group conversations.

## Overview

ConvosInvites implements a server-less invite system where:

- **Creators** generate signed invite URLs containing encrypted conversation IDs
- **Joiners** send the invite code via DM to the creator
- **Creators** validate the signature, decrypt the conversation ID, and add the joiner

This enables invitation-only groups without requiring a centralized approval server.

## Features

- 🔐 **ChaCha20-Poly1305** encryption for conversation tokens
- ✍️ **secp256k1 ECDSA** signatures with public key recovery
- 📦 **DEFLATE compression** for smaller invite codes
- 🔗 **URL-safe Base64** encoding with iMessage compatibility
- ⏰ **Expiration support** for time-limited invites
- 🛡️ **Spam prevention** via signature validation and DM blocking

## Installation

Add ConvosInvites to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../ConvosInvites"),  // Local package
    // Or when published:
    // .package(url: "https://github.com/xmtplabs/ConvosInvites.git", from: "1.0.0"),
]
```

### Products

| Product | Description | Use Case |
|---------|-------------|----------|
| `ConvosInvitesCore` | Core crypto, no XMTP dependency | Custom integrations, testing |
| `ConvosInvites` | Full package with XMTP integration | Production apps |

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ConvosInvites", package: "ConvosInvites"),
    ]
)
```

## Quick Start

### Creating an Invite (Core API)

```swift
import ConvosInvitesCore

// 1. Encrypt the conversation ID
let tokenBytes = try InviteToken.encrypt(
    conversationId: "group-abc-123",
    creatorInboxId: myInboxId,
    privateKey: myPrivateKey
)

// 2. Build the payload
var payload = InvitePayload()
payload.tag = "unique-invite-tag"
payload.conversationToken = tokenBytes
payload.creatorInboxID = Data(hexString: myInboxId)!
payload.name = "My Group"  // Optional: public preview
payload.expiresAtUnix = Int64(Date().addingTimeInterval(86400).timeIntervalSince1970)

// 3. Sign and encode
let signature = try payload.sign(with: myPrivateKey)

var signedInvite = SignedInvite()
try signedInvite.setPayload(payload)
signedInvite.signature = signature

let inviteCode = try signedInvite.toURLSafeSlug()
// Share: https://convos.org/i/{inviteCode}
```

### Processing a Join Request (Core API)

```swift
import ConvosInvitesCore

// 1. Decode the invite
let signedInvite = try SignedInvite.fromURLSafeSlug(inviteCode)

// 2. Check expiration
guard !signedInvite.hasExpired else { throw MyError.expired }

// 3. Verify signature
let isValid = try signedInvite.verify(with: creatorPublicKey)

// 4. Decrypt conversation ID
let conversationId = try InviteToken.decrypt(
    tokenBytes: signedInvite.invitePayload.conversationToken,
    creatorInboxId: creatorInboxId,
    privateKey: creatorPrivateKey
)

// 5. Add joiner to conversation
```

### Using the Coordinator (Full API)

```swift
import ConvosInvites

// Initialize
let coordinator = InviteCoordinator(
    client: xmtpClient,
    privateKeyProvider: { inboxId in
        try await keychain.getPrivateKey(for: inboxId)
    }
)

// Create invite
let invite = try await coordinator.createInvite(
    for: group,
    options: .expiring(after: 86400)  // 24 hours
)
print("Share this: \(invite.url)")

// Process incoming DM messages
coordinator.delegate = self
for await message in dmStream {
    if let result = try await coordinator.processMessage(message) {
        print("Added \(result.joinerInboxId) to \(result.conversationId)")
    }
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ConvosInvites                        │
│  ┌─────────────────────────────────────────────────┐   │
│  │              InviteCoordinator                   │   │
│  │  • createInvite(for:options:)                   │   │
│  │  • sendJoinRequest(for:)                        │   │
│  │  • processMessage(_:)                           │   │
│  │  • revokeInvites(for:)                          │   │
│  └─────────────────────────────────────────────────┘   │
│                         │                               │
│                         ▼                               │
│  ┌─────────────────────────────────────────────────┐   │
│  │            InviteTagStorage                      │   │
│  │  • getInviteTag(for:)                           │   │
│  │  • setInviteTag(_:for:)                         │   │
│  │  • regenerateInviteTag(for:)                    │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                  ConvosInvitesCore                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ InviteToken  │  │ InviteSigner │  │InviteEncoder │  │
│  │              │  │              │  │              │  │
│  │ • encrypt()  │  │ • sign()     │  │ • encode()   │  │
│  │ • decrypt()  │  │ • verify()   │  │ • decode()   │  │
│  │              │  │ • recover()  │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│         │                 │                 │          │
│         ▼                 ▼                 ▼          │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Cryptographic Primitives            │   │
│  │  • ChaCha20-Poly1305 (CryptoKit)                │   │
│  │  • HKDF-SHA256 (CryptoKit)                      │   │
│  │  • secp256k1 ECDSA (CSecp256k1)                 │   │
│  │  • DEFLATE (Compression framework)              │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## API Reference

### ConvosInvitesCore

#### InviteToken

Encrypts conversation IDs using ChaCha20-Poly1305 with HKDF-derived keys.

```swift
// Encrypt a conversation ID into a token
static func encrypt(
    conversationId: String,
    creatorInboxId: String,
    privateKey: Data
) throws -> Data

// Decrypt a token back to conversation ID
static func decrypt(
    tokenBytes: Data,
    creatorInboxId: String,
    privateKey: Data
) throws -> String
```

**Token Format:**
```
[version: 1 byte][nonce: 12 bytes][ciphertext + tag: 16-32+ bytes]
```

- UUID conversation IDs: 46 bytes (optimized binary encoding)
- String conversation IDs: variable length

#### InviteSigner

Signs and verifies invite payloads using secp256k1 ECDSA.

```swift
// Sign a payload (on InvitePayload)
func sign(with privateKey: Data) throws -> Data

// Verify a signature (on SignedInvite)
func verify(with publicKey: Data) throws -> Bool

// Recover signer's public key (on SignedInvite)
func recoverSignerPublicKey() throws -> Data
```

#### InviteEncoder

URL-safe encoding with optional compression.

```swift
// Encode to URL-safe string
static func encode(_ signedInvite: SignedInvite) throws -> String

// Decode from URL-safe string
static func decode(_ slug: String) throws -> SignedInvite

// Decode from full URL or raw code
static func decodeFromURL(_ urlString: String) throws -> SignedInvite
```

**Supported URL Formats:**
- `convos://join/{code}` (legacy app scheme)
- `convos://invite/{code}` (app scheme)
- `https://domain.com/v2?i={code}` (legacy universal link)
- `https://convos.org/i/{code}` (universal link)
- `https://convos.org/invite?code={code}` (query param)

#### SignedInvite Extensions

```swift
// Convenience accessors
var invitePayload: InvitePayload  // Deserialized payload
var name: String?                  // Public preview name
var description_p: String?         // Public preview description
var imageURL: String?              // Public preview image
var expiresAt: Date?               // Invite expiration
var conversationExpiresAt: Date?   // Conversation expiration
var hasExpired: Bool               // Check if expired
var conversationHasExpired: Bool   // Check if conversation expired

// Encoding
func toURLSafeSlug() throws -> String
static func fromURLSafeSlug(_ slug: String) throws -> SignedInvite
static func fromInviteCode(_ code: String) throws -> SignedInvite
```

### ConvosInvites

#### InviteCoordinator

High-level API for invite management with XMTP integration.

```swift
// Initialize
init(
    client: XMTPiOS.Client,
    privateKeyProvider: @escaping PrivateKeyProvider,
    tagStorage: InviteTagStorageProtocol = XMTPInviteTagStorage(),
    baseURL: URL = URL(string: "https://convos.org/i/")!
)

// Create an invite URL
func createInvite(
    for group: XMTPiOS.Group,
    options: InviteOptions = InviteOptions()
) async throws -> InviteURL

// Revoke all invites for a group
func revokeInvites(for group: XMTPiOS.Group) async throws -> String

// Send a join request (joiner side)
func sendJoinRequest(for signedInvite: SignedInvite) async throws -> XMTPiOS.Dm

// Process a message as potential join request (creator side)
func processMessage(_ message: XMTPiOS.DecodedMessage) async throws -> JoinResult?
```

#### InviteOptions

```swift
struct InviteOptions {
    var name: String?              // Public preview name
    var description: String?       // Public preview description
    var imageURL: URL?             // Public preview image
    var expiresAt: Date?           // Expiration date
    var singleUse: Bool            // One-time use
    var includePublicPreview: Bool // Include preview info (default: true)
    
    static func expiring(after interval: TimeInterval, singleUse: Bool = false) -> InviteOptions
}
```

#### InviteCoordinatorDelegate

```swift
protocol InviteCoordinatorDelegate: AnyObject {
    func coordinator(_ coordinator: InviteCoordinator, didReceiveJoinRequest request: JoinRequest)
    func coordinator(_ coordinator: InviteCoordinator, didAddMember result: JoinResult)
    func coordinator(_ coordinator: InviteCoordinator, didRejectJoinRequest request: JoinRequest, error: JoinRequestError)
    func coordinator(_ coordinator: InviteCoordinator, didBlockSpammer inboxId: String, in dmConversationId: String)
}
```

## Security Considerations

### Invite Tag Rotation

Each group has an "invite tag" stored in its metadata. Regenerating this tag invalidates all existing invites:

```swift
try await coordinator.revokeInvites(for: group)
```

### Spam Prevention

Invalid join requests (bad signature, wrong creator, etc.) result in:
1. DM consent set to `.denied`
2. Delegate notified via `didBlockSpammer`

### Key Management

The package does not store private keys. Apps must provide a `PrivateKeyProvider` callback:

```swift
let coordinator = InviteCoordinator(
    client: xmtpClient,
    privateKeyProvider: { inboxId in
        // Your secure key storage
        return try await keychain.getPrivateKey(for: inboxId)
    }
)
```

### Cryptographic Details

| Component | Algorithm | Purpose |
|-----------|-----------|---------|
| Token encryption | ChaCha20-Poly1305 | Encrypt conversation ID |
| Key derivation | HKDF-SHA256 | Derive encryption key from private key + inbox ID |
| Signatures | secp256k1 ECDSA | Sign/verify invite payloads |
| Compression | DEFLATE | Reduce invite code size |
| Encoding | Base64URL | URL-safe representation |

## Testing

```bash
# Run all tests
cd ConvosInvites
swift test

# Run specific test suite
swift test --filter "InviteTokenTests"
swift test --filter "InviteSignerTests"
swift test --filter "InviteEncodingTests"
```

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please read our contributing guidelines before submitting PRs.
