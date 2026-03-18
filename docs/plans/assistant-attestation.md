# Assistant Attestation — Cryptographic Verification of Convos Assistants

## Context

When a user requests an assistant via `POST /v2/agents/join`, the backend provisions an agent from the pool and the agent joins the conversation via the invite system. Once joined, the agent appears as a regular XMTP group member with `memberKind: MEMBER_KIND_AGENT`.

Currently, `isAgent` is self-declared — any XMTP client joining a conversation can set `member_kind: MEMBER_KIND_AGENT` in their `ProfileUpdate` and appear as an assistant. There is no cryptographic proof that the member was actually provisioned by the Convos backend. A malicious actor who obtains an invite link could join and impersonate an assistant.

## Goal

Cryptographically verify that a member claiming to be an assistant was provisioned by the Convos backend. Verified assistants get a visual badge; unverified members who claim `isAgent` do not.

## Design

### Attestation scheme

The backend signs the agent's `inboxId` with an Ed25519 private key. The agent includes the signature in its profile metadata. The iOS client verifies the signature against the backend's public key, fetched from a JWKS endpoint.

**What is signed:** `inboxId || timestamp` (Ed25519 handles hashing internally)
- `inboxId`: the agent's XMTP inbox ID (hex string)
- `timestamp`: ISO 8601 UTC string (e.g. `2026-03-11T20:00:00Z`)
- `||`: string concatenation (no separator)
- The message bytes are the UTF-8 encoding of the concatenated string

**Why signing just `inboxId + timestamp` is sufficient:**
- Each agent gets a fresh per-conversation identity (unique `inboxId` per conversation)
- The `inboxId` cannot be reused in another conversation — XMTP enforces identity uniqueness
- The attestation proves "the Convos backend created this identity" which is the core trust assertion
- No dependency on `conversationId` (unknown before join) or `inviteSlug` (rotates over time)

**Replay protection:**
- The `inboxId` is a one-time value — each agent session creates a new XMTP identity
- Timestamp provides additional freshness; clients can reject attestations older than a threshold (e.g. 24 hours)

### Profile metadata fields

The agent sets three metadata fields in its `ProfileUpdate` message:

| Key | Type | Value |
|-----|------|-------|
| `attestation` | string | Base64url-encoded Ed25519 signature (64 bytes) |
| `attestation_ts` | string | ISO 8601 UTC timestamp used in signature |
| `attestation_kid` | string | Key ID from the JWKS endpoint (e.g. `convos-agents-2026-03`) |

These fields flow through the existing profile pipeline:
- `ProfileUpdate` → stored in `DBProfile` → hydrated into `Profile.metadata`
- `ProfileSnapshot` → propagated to new members joining later
- No new content types, no extra messages

### Verification flow (iOS)

1. Observe a member with `isAgent == true`
2. Read `metadata["attestation"]`, `metadata["attestation_ts"]`, and `metadata["attestation_kid"]`
3. If any is missing → unverified
4. Look up the public key by `kid` from the cached JWKS (fetch if not cached)
5. If `kid` not found in cache, re-fetch JWKS once; if still not found → unverified
6. If the key has an `exp` and it is in the past → unverified
7. Reconstruct message: UTF-8 bytes of `inboxId || attestation_ts`
8. Verify Ed25519 signature using the resolved public key
9. If valid and timestamp is within 24 hours of the profile message date → verified assistant
10. Cache the result per `(inboxId, conversationId)` — re-verify only on profile update or JWKS refresh

### Key management

Public keys are hosted at a well-known URL using a JWKS-like format, rather than pinned in the app binary. This enables key rotation, multiple active keys, and reuse by other apps (Android, web).

**Endpoint:** `https://convos.org/.well-known/agents.json`

**Response format** (modeled on [JSON Web Key Sets](https://auth0.com/docs/secure/tokens/json-web-tokens/json-web-key-sets)):

```json
{
  "keys": [
    {
      "kid": "convos-agents-2026-03",
      "kty": "OKP",
      "crv": "Ed25519",
      "x": "<base64url-encoded public key>",
      "use": "sig",
      "exp": "2027-03-01T00:00:00Z"
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `kid` | Key ID — referenced in attestations so clients know which key to verify with |
| `kty` | Key type — `OKP` (Octet Key Pair) per RFC 8037 for Ed25519 |
| `crv` | Curve — `Ed25519` |
| `x` | Base64url-encoded 32-byte public key |
| `use` | Key use — `sig` (signing) |
| `exp` | Optional expiry — clients should reject signatures from expired keys |

**Attestation references the key:** the agent includes `attestation_kid` in its profile metadata so clients know which key to verify against without trying all keys.

**Client-side caching:**
- Fetch and cache the JWKS on first verification (or app launch)
- Cache duration: 24 hours, with background refresh
- If a `kid` is not in the cache, re-fetch once before failing
- Fallback: if the endpoint is unreachable, use the most recently cached keyset

**Key rotation workflow:**
1. Generate a new key pair, add to the JWKS endpoint with a new `kid`
2. Start signing new attestations with the new key
3. Both old and new keys are active during the transition period
4. After all old agents have expired (ephemeral identities are short-lived), remove the old key

**Security considerations for JWKS:**
- The endpoint is served over HTTPS from `convos.org` — TLS protects against MITM
- An attacker who compromises the domain could substitute keys, but that is the same threat model as any web-based key distribution (and no worse than a compromised app update)
- The client caches keys, so a transient compromise does not retroactively affect previously verified agents
- For defense in depth, the app ships with a hardcoded fallback key that is always trusted, ensuring verification works even if the endpoint is unreachable on first launch

## Implementation

### Phase 1: iOS — Crypto & verification (no backend dependency)

All iOS work can be built and tested with locally generated test key pairs before the backend signs anything.

#### New: `AgentKeyset`

Fetches and caches the JWKS from `https://convos.org/.well-known/agents.json`:

```swift
public actor AgentKeyset {
    public func publicKey(for kid: String) async -> Curve25519.Signing.PublicKey?
}
```

- Caches for 24 hours, refreshes in background
- Re-fetches on cache miss for unknown `kid`
- Falls back to last cached keyset if endpoint is unreachable
- Ships with a hardcoded fallback key for offline first-launch

#### New: `AssistantAttestationVerifier`

Utility in ConvosCore that verifies attestations:

```swift
public enum AssistantAttestationVerifier {
    public static func verify(
        inboxId: String,
        attestation: String,
        attestationTimestamp: String,
        kid: String,
        keyset: AgentKeyset,
        referenceDate: Date = Date()
    ) async -> Bool
}
```

Uses `CryptoKit.Curve25519.Signing.PublicKey` — no external dependencies beyond CryptoKit.

#### Modified: `Profile`

Add a method (async due to keyset lookup):

```swift
public func verifyAssistantAttestation(keyset: AgentKeyset) async -> Bool
```

#### Modified: `ConversationMember`

Add `isVerifiedAssistant: Bool` field, populated during hydration. Two tiers of trust:

- `isAgent` — XMTP `MEMBER_KIND_AGENT`, self-declared. Used for layout and generic agent treatment (different color, "Agent" label).
- `isVerifiedAssistant` — attestation verified. Used for Convos assistant branding (`.colorLava`, "Assistant" label, full assistant UI).

#### Modified: UI — verified vs unverified visual treatment

| Property | `isAgent` (unverified) | `isVerifiedAssistant` (verified) |
|----------|----------------------|--------------------------------|
| Display name | "Agent" (generic) | Assistant name from profile |
| Accent color | TBD (not `.colorLava`) | `.colorLava` |
| Badge | Generic agent indicator | Convos assistant badge |
| Capabilities UI | Hidden | Full assistant info (tools, about, etc.) |

Current assistant UI (`.colorLava`, branded features) becomes the verified treatment. Unverified agents get a distinct, downgraded visual treatment.

### Phase 2: CLI — Testable attestation generation (no backend dependency)

The CLI can generate attestations locally for end-to-end testing without the backend.

1. Add a CLI command to generate an Ed25519 key pair (for testing)
2. Add a CLI command or flag to sign `inboxId || timestamp` with a local Ed25519 private key
3. Agent includes `attestation`, `attestation_ts`, `attestation_kid` in its `ProfileUpdate` metadata

This lets us test the full iOS verification flow with real XMTP conversations.

### Phase 3: Backend — Production key management & signing

Once iOS and CLI are validated:

1. Host the JWKS endpoint at `https://convos.org/.well-known/agents.json` with the production signing key(s)
2. After provisioning, sign `inboxId || timestamp` with the active Ed25519 private key
3. Pass the signature, timestamp, and `kid` to the agent as part of its configuration
4. The agent includes them in its `ProfileUpdate` metadata when joining

The signing is a single crypto operation. The JWKS endpoint is a static JSON file that only changes during key rotation.

### Files changed

| File | Change |
|------|--------|
| `ConvosCore/.../AgentKeyset.swift` | **New** — JWKS fetch, cache, and key lookup |
| `ConvosCore/.../AssistantAttestationVerifier.swift` | **New** — Ed25519 verification logic |
| `ConvosCore/.../Profile.swift` | Add `verifyAssistantAttestation` method |
| `ConvosCore/.../ConversationMember.swift` | Add `isVerifiedAssistant`, wire through hydration |
| `ConvosCore/.../Conversation.swift` | Use verified status for assistant-specific checks |
| UI files (various) | Bifurcate agent vs verified assistant visual treatment |

## Security considerations

- **HTTPS key distribution**: public keys are fetched over TLS from `convos.org`. An attacker would need to compromise the domain or obtain a valid TLS certificate to substitute keys.
- **Hardcoded fallback key**: a single key is compiled into the app as a last resort, ensuring verification works on first launch without network access. This key can be rotated via app updates.
- **Client-side caching**: keys are cached for 24 hours. A transient endpoint compromise does not affect previously verified agents, and the attacker's window is limited to the cache refresh interval.
- **No private key on device**: the device only verifies — it never signs. Compromising a device does not compromise the attestation system.
- **Timestamp window**: rejecting attestations older than 24 hours limits the window for replay, though replay is already prevented by inbox ID uniqueness.
- **Backward compatibility**: agents provisioned before this feature have no attestation. They still show as agents (`isAgent == true`) but not as verified. This is a graceful degradation — no breakage.
- **Multi-platform**: the JWKS endpoint can be consumed by Android, web, or any other client — not tied to iOS app releases.

## Out of scope

- Revoking individual attestations (the agent identity is ephemeral — just deprovision it)
- Verifying assistants in push notifications (attestation is in profile metadata, not in the notification payload)
- Server-side attestation verification (only the client verifies)
- Certificate transparency or key pinning beyond the hardcoded fallback
