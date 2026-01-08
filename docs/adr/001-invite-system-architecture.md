# ADR 001: Decentralized Invite System with Cryptographic Tokens

## Status

Accepted

## Context

Convos is a peer-to-peer messaging app built on XMTP that requires a way for users to invite others to join group conversations. The invite system must:

- Work without a centralized approval server
- Prevent unauthorized joins and spam
- Allow conversation creators to revoke invites
- Support sharing via QR codes, URLs, and messaging apps
- Protect conversation IDs from exposure
- Enable detection of duplicate join attempts

Traditional invite systems rely on backend servers to validate invite codes and manage permissions. However, Convos aims for a decentralized architecture aligned with XMTP's peer-to-peer model.

## Decision

We implemented a serverless invite system using signed cryptographic tokens with the following key components:

### 1. Invite Tags (10-character random strings)

Each conversation has a persistent invite tag stored in XMTP custom metadata that serves multiple purposes:

**Purpose:**
- **Joiner Protection:** When a user is added to a conversation, they can verify the invite tag matches the one from their original invite, ensuring they're being added to the conversation they actually want to join (not maliciously added to an unrelated conversation)
- Conversation identity binding for verification
- Revocation mechanism (update tag to invalidate all existing invites)
- Duplicate join prevention via database lookup
- Outgoing join request detection

**Implementation:**
- Generated using cryptographically random alphanumeric strings (10 characters)
- Stored in conversation's custom metadata (protobuf in XMTP appData field)
- Included in every invite for that conversation
- Queryable from local database to detect existing conversations

**Location:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift:61-66`

### 2. Creator Inbox ID in Invites

The creator's XMTP inbox ID is embedded in every invite as raw bytes (hex-decoded for compactness).

**Purpose:**
- AAD (Additional Authenticated Data) for conversation token encryption
- Context for key derivation via HKDF
- Join request routing (joiner needs to know who to DM)
- Creator verification during join request processing

**Security Benefit:**
Cryptographically binds the encrypted conversation token to the creator's identity, preventing token transplant attacks where an attacker might try to use a valid token with a different creator.

**Privacy Note:**
Exposing the creator's inbox ID in the invite is acceptable in Convos' architecture because every conversation uses a single-purpose identity. Each identity is only ever tied to one conversation, so revealing the inbox ID doesn't expose any information beyond what the invite already contains (the conversation itself).

**Location:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/proto/invite.proto:8-9`

### 3. Invite Slug Generation Process

Invites are generated as URL-safe slugs through a multi-stage process:

**Stage 1: Conversation Token Encryption**
- Conversation ID encrypted with ChaCha20-Poly1305
- Key derived via HKDF-SHA256 with salt "ConvosInviteV1" and info "inbox:<inboxId>"
- AAD: Creator's inbox ID
- Binary format: version (1 byte) | nonce (12 bytes) | ciphertext (variable) | auth_tag (16 bytes)

**Stage 2: Payload Construction**
- Build protobuf InvitePayload containing:
  - Invite tag (10 chars)
  - Encrypted conversation token
  - Creator inbox ID (32 bytes raw)
  - Optional: name, description, imageURL, expiration, single-use flag

**Stage 3: Signature**
- Sign payload with secp256k1 ECDSA with recovery
- Input: SHA256 hash of serialized protobuf
- Output: 65 bytes (64-byte signature + 1-byte recovery ID)

**Stage 4: URL-Safe Encoding**
- Bundle payload + signature into SignedInvite protobuf
- Apply DEFLATE compression if beneficial
- Encode with URL-safe Base64 (using `-` and `_`)
- Insert asterisks (`*`) every 300 chars for iMessage compatibility

**Location:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift`

### 4. Join Flow

**Invite Creation:**
1. Creator generates invite with current conversation metadata
2. Invite signed with creator's private key
3. URL-safe slug shared via QR code, link, or message

**Joining:**
1. Joiner decodes and verifies signature
2. Recovers creator's public key from signature
3. Decrypts conversation token using derived key
4. Checks local database for existing conversation with matching tag
5. If not found, sends DM join request to creator with signature

**Join Request Processing:**
1. Creator receives DM with join request
2. Verifies signature and creator inbox ID match
3. Validates invite hasn't expired or been used (if single-use)
4. Adds joiner to conversation via XMTP

**Post-Add Verification:**
When the joiner is added to the new conversation, they verify that the conversation's invite tag matches the tag from their original invite. This protects against malicious scenarios where someone might try to add them to an unrelated conversation. Since XMTP allows anyone to add you to a conversation, the invite tag provides crucial proof that "I requested to join this specific conversation" and "I was added to this conversation" are the same.

**Spam Prevention:**
Invalid join requests (bad signature, malformed data, wrong creator) trigger automatic DM blocking using XMTP consent states.

### 5. Additional Architectural Decisions

**Protobuf Wire Format:**
- Compact binary representation for QR codes and URLs
- Schema evolution support
- Cross-platform compatibility

**Public Key Recovery:**
- Recovers signer's public key from signature instead of including it
- Saves 33-65 bytes per invite
- Uses secp256k1 ECDSA recovery

**Compression Strategy:**
- DEFLATE compression applied only when beneficial (payload >100 bytes and compression reduces size)
- Compression marker byte (`0x1F`) indicates compressed data
- Maximum decompressed size limits (1MB invites, 10MB metadata) prevent decompression bombs

**Constant-Time Comparison:**
- Cryptographic operations use constant-time comparison
- Prevents timing attacks

**Custom Metadata Storage:**
- Conversation metadata stored in XMTP's 8KB appData field
- Compressed protobuf typically achieves 40-60% size reduction
- No backend required for metadata storage

## Consequences

### Positive

- **Fully Decentralized:** No backend required for invite validation or join approval
- **Privacy-Preserving:** Conversation IDs encrypted, only creator can decrypt
- **Spam-Resistant:** Invalid join requests trigger automatic DM blocking
- **Revocable:** Update invite tag to invalidate all existing invites
- **Compact:** Optimized encoding enables QR code sharing
- **Secure:** Cryptographic signatures prevent forgery and tampering
- **Duplicate-Safe:** Invite tags enable detection of existing conversations
- **Flexible:** Support for optional expiration and single-use flags

### Negative

- **Complexity:** Cryptographic operations and multi-stage encoding add implementation complexity
- **8KB Metadata Limit:** XMTP appData field constrains amount of metadata (tags, profiles, expiration)
- **No Centralized Analytics:** Can't track invite usage without backend
- **Revocation Lag:** Updating invite tag only affects future joins, can't force-expire already-shared invites

**Note on Creator Inbox ID Exposure:**
While the creator's inbox ID is visible in invites, this is not a privacy concern in Convos' architecture. Every conversation uses a single-purpose identity, and each identity is only ever tied to one conversation. Therefore, revealing the inbox ID doesn't expose any information beyond what the invite already conveys (the conversation itself).

### Security Model

| Threat | Mitigation |
|--------|-------------|
| Invite forgery | secp256k1 ECDSA signature verification |
| Token reuse across identities | AAD binding in ChaCha20-Poly1305 |
| Conversation ID exposure | Encrypted with creator's derived key |
| Malicious conversation adds | Invite tag verification - joiner can confirm they're being added to the conversation they requested |
| Timing attacks | Constant-time comparison |
| Decompression bombs | Maximum decompressed size limits |
| Spam/fake join requests | DM blocking on invalid invites |
| Replay attacks | Optional invite expiration and single-use flags |

## Related Files

- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/proto/invite.proto` - Protobuf schemas
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/InviteConversationToken.swift` - Token encryption
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift` - Slug generation
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Validation.swift` - Signature verification
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Encoding.swift` - URL-safe encoding
- `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift` - Metadata storage
- `ConvosCore/Sources/ConvosCore/Syncing/InviteJoinRequestsManager.swift` - Join request processing
- `ConvosCore/Sources/ConvosCore/Inboxes/ConversationStateMachine.swift` - Join flow state machine

## Related ADRs

- ADR 002: Per-Conversation Identity Model (explains the per-conversation inbox architecture used for invite creators)
- ADR 003: Inbox Lifecycle Management (explains how pre-created inboxes optimize the join flow)
- ADR 005: Profile Storage in Conversation Metadata (also uses XMTP custom metadata, shares the 8KB appData limit)

## References

- XMTP Protocol: https://xmtp.org
- ChaCha20-Poly1305 AEAD: RFC 8439
- HKDF: RFC 5869
- secp256k1 ECDSA: https://www.secg.org/sec2-v2.pdf
- Protocol Buffers: https://protobuf.dev
