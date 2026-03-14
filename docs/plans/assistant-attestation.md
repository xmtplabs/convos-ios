# Assistant Attestation — Cryptographic Verification of Convos Assistants

## Context

When a user requests an assistant via `POST /v2/agents/join`, the backend provisions an agent from the pool and the agent joins the conversation via the invite system. Once joined, the agent appears as a regular XMTP group member with `memberKind: MEMBER_KIND_AGENT`.

Currently, `isAgent` is self-declared — any XMTP client joining a conversation can set `member_kind: MEMBER_KIND_AGENT` in their `ProfileUpdate` and appear as an assistant. There is no cryptographic proof that the member was actually provisioned by the Convos backend. A malicious actor who obtains an invite link could join and impersonate an assistant.

## Goal

Cryptographically verify that a member claiming to be an assistant was provisioned by the Convos backend. Verified assistants get a visual badge; unverified members who claim `isAgent` do not.

## Design

### Attestation scheme

The backend signs the agent's `inboxId` with an Ed25519 private key. The agent includes the signature in its profile metadata. The iOS client verifies the signature against a pinned public key.

**What is signed:** `sha256(inboxId || timestamp)`
- `inboxId`: the agent's XMTP inbox ID (hex string)
- `timestamp`: ISO 8601 UTC string (e.g. `2026-03-11T20:00:00Z`)
- `||`: string concatenation (no separator)

**Why signing just `inboxId + timestamp` is sufficient:**
- Each agent gets a fresh per-conversation identity (unique `inboxId` per conversation)
- The `inboxId` cannot be reused in another conversation — XMTP enforces identity uniqueness
- The attestation proves "the Convos backend created this identity" which is the core trust assertion
- No dependency on `conversationId` (unknown before join) or `inviteSlug` (rotates over time)

**Replay protection:**
- The `inboxId` is a one-time value — each agent session creates a new XMTP identity
- Timestamp provides additional freshness; clients can reject attestations older than a threshold (e.g. 24 hours)

### Profile metadata fields

The agent sets two metadata fields in its `ProfileUpdate` message:

| Key | Type | Value |
|-----|------|-------|
| `attestation` | string | Base64-encoded Ed25519 signature (64 bytes → 88 chars) |
| `attestation_ts` | string | ISO 8601 UTC timestamp used in signature |

These fields flow through the existing profile pipeline:
- `ProfileUpdate` → stored in `DBProfile` → hydrated into `Profile.metadata`
- `ProfileSnapshot` → propagated to new members joining later
- No new content types, no extra messages

### Verification flow (iOS)

1. Observe a member with `isAgent == true`
2. Read `metadata["attestation"]` and `metadata["attestation_ts"]`
3. If either is missing → unverified
4. Reconstruct message: `sha256(inboxId || attestation_ts)`
5. Verify Ed25519 signature using pinned public key
6. If valid and timestamp is within 24 hours of the profile message date → verified assistant
7. Cache the result per `(inboxId, conversationId)` — re-verify only on profile update

### Key management

- **Ed25519 key pair** generated once, stored securely on the backend
- **Public key** pinned in the iOS app as a constant (base64 string)
- **Key rotation**: if needed, bundle multiple public keys with validity periods; try each until one verifies
- The public key is not secret — it only verifies, never signs

## Implementation

### Backend changes

The backend already provisions agents and knows their `inboxId`. Changes:

1. After provisioning, sign `sha256(inboxId || timestamp)` with the Ed25519 private key
2. Pass the signature and timestamp to the agent as part of its configuration
3. The agent includes them in its `ProfileUpdate` metadata when joining

The signing is a single crypto operation — no new endpoints or data stores needed.

### CLI / Agent changes

The agent's `ProfileUpdate` already supports `--metadata key=value`. Changes:

1. Accept `attestation` and `attestation_ts` from backend config
2. Include them in the `update-profile` call after joining:
   ```
   --metadata attestation=<base64sig> --metadata attestation_ts=<iso8601>
   ```

### iOS changes

#### New: `AssistantAttestationVerifier`

Utility in ConvosCore that verifies attestations:

```swift
public enum AssistantAttestationVerifier {
    public static func verify(
        inboxId: String,
        attestation: String,
        attestationTimestamp: String,
        referenceDate: Date = Date()
    ) -> Bool
}
```

Uses `CryptoKit.Curve25519.Signing.PublicKey` — no external dependencies.

#### Modified: `Profile`

Add a computed property:

```swift
public var isVerifiedAssistant: Bool {
    guard isAgent,
          let attestation = metadata?["attestation"],
          let timestamp = metadata?["attestation_ts"],
          case .string(let sig) = attestation,
          case .string(let ts) = timestamp
    else { return false }
    return AssistantAttestationVerifier.verify(
        inboxId: inboxId,
        attestation: sig,
        attestationTimestamp: ts
    )
}
```

#### Modified: `ConversationMember`

Replace `isAgent` usage with `isVerifiedAssistant` where trust matters (badge display, assistant-specific UI). Keep `isAgent` for non-security uses (UI layout, counting).

#### Modified: Assistant badge UI

Show a verified badge (e.g. checkmark overlay) only when `isVerifiedAssistant == true`. Unverified agents still show as agents (for backward compatibility) but without the trust badge.

### Files changed

| File | Change |
|------|--------|
| `ConvosCore/.../AssistantAttestationVerifier.swift` | **New** — Ed25519 verification logic |
| `ConvosCore/.../Profile.swift` | Add `isVerifiedAssistant` computed property |
| `ConvosCore/.../ConversationMember.swift` | Expose `isVerifiedAssistant` from profile |
| `ConvosCore/.../Conversation.swift` | Use verified status for assistant count/checks |
| `Convos/.../AssistantBadgeView.swift` | Verified vs unverified visual treatment |

## Security considerations

- **Public key pinning**: the Ed25519 public key is compiled into the app binary. An attacker would need to modify the binary to substitute their own key, which is infeasible on non-jailbroken devices.
- **No private key on device**: the device only verifies — it never signs. Compromising a device does not compromise the attestation system.
- **Timestamp window**: rejecting attestations older than 24 hours limits the window for replay, though replay is already prevented by inbox ID uniqueness.
- **Backward compatibility**: agents provisioned before this feature have no attestation. They still show as agents (`isAgent == true`) but not as verified. This is a graceful degradation — no breakage.

## Out of scope

- Key rotation UI or OTA key updates (future enhancement)
- Revoking individual attestations (the agent identity is ephemeral — just deprovision it)
- Verifying assistants in push notifications (attestation is in profile metadata, not in the notification payload)
- Server-side attestation verification (only the client verifies)
