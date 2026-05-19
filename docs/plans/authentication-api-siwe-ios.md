# Authentication API (SIWE) — iOS Implementation Plan

> Backend branch reviewed from `../convos-backend`: `fbac/authentication-api`.
> iOS target repo: `convos-ios`.

## Next-step proof goal

Show, from the Swift app/debug build, that we can:

1. Obtain a backend nonce from `POST /api/v2/auth/nonce`.
2. Build and sign an EIP-4361/SIWE message with the local XMTP Ethereum identity.
3. Exchange `{ deviceId, siwe: { message, signature } }` at `POST /api/v2/auth/token` for a JWT that contains `accountId`.
4. Call a gated API route with `X-Convos-AuthToken: <jwt>` and display success or the backend error.

Important path note: current iOS `AppEnvironment.apiBaseURL` already ends in `/api`, so client paths should remain `v2/auth/nonce`, `v2/auth/token`, etc.

## Backend contract observed

### `POST /api/v2/auth/nonce`

Headers:

- `X-Firebase-AppCheck: <app check token>`

Response:

- Status `200`
- Body `{}`
- `Set-Cookie: __Host-convos_nonce=<hmac>.<nonce>; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=300`

The raw nonce is the 64-hex-character value after the first `.` in the cookie value. It is valid for 5 minutes and single use once submitted to `/auth/token`.

### `POST /api/v2/auth/token`

Headers:

- `X-Firebase-AppCheck: <app check token>`
- `Cookie: __Host-convos_nonce=<hmac>.<nonce>` when using the SIWE path
- `Content-Type: application/json`

Body:

```json
{
  "deviceId": "<DeviceInfo.deviceIdentifier>",
  "siwe": {
    "message": "<exact SIWE message string>",
    "signature": "0x<65-byte recoverable signature hex>"
  }
}
```

Success:

```json
{ "token": "<jwt>" }
```

Token details:

- ES256 JWT.
- Expires in 15 minutes.
- Payload includes `deviceId`; SIWE path also includes `accountId`.

Errors to surface during the proof run:

- `400` invalid request body.
- `401` invalid nonce or invalid SIWE. Nonce may already be burned; retry must restart from `/auth/nonce`.
- `403` disabled device.
- `429` rate limited.

### Account auth-check route

Do **not** change existing `/api/v2/auth-check` yet. iOS/NSE already use it as a backward-compatible JWT liveness check, and backend intentionally mounts it with `authMiddlewareAllowNSE`.

Add a separate account-bound check route:

- name: `GET /api/v2/account-auth-check`
- backend middleware: `authMiddleware, requireAccount`
- success body: `{ "success": true }` (optionally include `accountId` for debug builds only)

This route should:

- return `200` only for JWTs that verify and carry `accountId`,
- return `401` for missing/expired/invalid JWT,
- return `403 { "error": "Account required" }` for legacy device-only JWTs,
- reject NSE-only JWTs because it uses `authMiddleware`, not `authMiddlewareAllowNSE`.

The route is named after what it actually checks (`accountId`), not after the auth method that produced the token. In the current backend, `accountId` implies SIWE because SIWE is the only account creation method, but when a second method is added (passkey, Sign-In with Solana, etc.) the route stays correct without a rename.

## Current iOS gaps

1. `ConvosAPIClient.authenticate(appCheckToken:retryCount:)` uses the legacy body `{ deviceId }`; it will mint a device-only JWT with no `accountId`.
2. The client has no nonce endpoint support and no SIWE request models.
3. `ConvosAPIClient` currently has no access to the XMTP identity/private key when it refreshes a token after a `401`.
4. JWTs are stored by device ID only (`KeychainAccount.jwt(deviceId:)`). With SIWE this can reuse a stale token from a previous identity on the same device.
5. The app config has no explicit `siweDomain`, `siweURI`, or `chainId`; backend SIWE verification is exact-match.
6. Default `HTTPCookieStorage` silently drops the prod cookie on `http://localhost` because the `__Host-` prefix requires `Secure`. The current backend on `fbac/authentication-api` still emits `__Host-convos_nonce; Secure` unconditionally — relaxing it to `convos_nonce` (no `Secure`) outside prod is a **proposed backend coordination item, not yet landed**. iOS must therefore build the SIWE flow assuming the strict prod cookie, i.e. raw-parse `Set-Cookie` and send the `Cookie` header manually on `/auth/token` rather than relying on `HTTPCookieStorage`. If the backend relaxation lands, this code keeps working unchanged.

## Implementation plan

### 1. Add SIWE configuration to app environment

Files:

- `ConvosCore/Sources/ConvosCore/ConvosConfiguration.swift`
- `ConvosCore/Sources/ConvosCore/AppEnvironment.swift`
- `ConvosCore/Sources/ConvosCore/AppEnvironment+Shared.swift`
- `ConvosCore/Sources/ConvosCore/Config/ConfigManager.swift`
- `Convos/Config/config.*.json`

Add:

```swift
public struct SIWEConfiguration: Codable, Sendable, Equatable {
    public let domain: String
    public let uri: String
    public let chainId: Int
}
```

Recommended initial values must match backend env exactly. Do not infer from `apiBaseURL`.

### 2. Add SIWE message builder + signer helper

New file suggestion:

- `ConvosCore/Sources/ConvosCore/Auth/BackendSIWEAuth.swift`

Responsibilities:

- Derive the Ethereum address from `KeychainIdentity.keys.privateKey.identity.identifier`.
- Build the exact SIWE message string with `\n` line endings:

```text
<domain> wants you to sign in with your Ethereum account:
<address>

Sign in to Convos

URI: <uri>
Version: 1
Chain ID: <chainId>
Nonce: <nonce>
Issued At: <issuedAt>
Expiration Time: <expirationTime>
```

- `issuedAt` should be current time.
- `expirationTime` should be about 5 minutes in the future and always less than backend's 10-minute maximum.
- Sign the exact UTF-8 string with `try await privateKey.sign(message).rawData`. `PrivateKey.sign` already applies the EIP-191 prefix internally (see libxmtp `KeyUtil.ethHash`); do **not** prefix again.
- **Normalize the recovery byte before hex encoding.** `rawData` is `r || s || v` (65 bytes). libxmtp's underlying `secp256k1_ecdsa_sign_recoverable` returns `v ∈ {0, 1}`, but the backend's SIWE verification path uses `ethers` which expects Ethereum-standard `v ∈ {27, 28}`. If `rawData[64] < 27`, add `27` before serializing. Skipping this is the single most likely cause of `401 Invalid SIWE` even when math is correct.
- Hex encode the 65-byte signature as `0x...` (130 hex chars after the prefix).

Add tests with a fixed private key to prove:

- address derivation is stable,
- message construction is byte-for-byte stable,
- signature is 65 bytes and hex encoded with `0x`,
- **the signature round-trips**: sign a known message, recover the public key from the produced `(r, s, v)`, derive the address, and assert it matches `privateKey.walletAddress`. Use `secp256k1` from `ConvosInvites/Sources/ConvosInvitesCore/Core/Crypto.swift`. This is the canary for the `v`-byte issue above and the EIP-191 prefix; if it passes locally, the backend will accept it.

### 3. Add nonce acquisition to API client

Files:

- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient+Models.swift`
- `ConvosCore/Sources/ConvosCore/API/MockAPIClient.swift`

Add an internal method like:

```swift
func requestAuthNonce(appCheckToken: String) async throws -> AuthNonceChallenge
```

`AuthNonceChallenge` should contain:

- `nonce: String`
- `cookieHeader: String` (`__Host-convos_nonce=<hmac>.<nonce>`)

Implementation details:

- `POST v2/auth/nonce`.
- Raw-parse the `Set-Cookie` response header rather than relying on `HTTPCookieStorage`. As of the reviewed backend, the cookie is emitted unconditionally as `__Host-convos_nonce=<hmac>.<nonce>; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=300`, and `HTTPCookieStorage` will silently drop it on `http://localhost` because of `Secure`. Use `HTTPURLResponse.value(forHTTPHeaderField: "Set-Cookie")` plus `HTTPCookie.cookies(withResponseHeaderFields:for:)` so commas inside `Expires=...` don't corrupt parsing, then look up the cookie by exact name. Accept both `__Host-convos_nonce` and the proposed dev form `convos_nonce` so the same code keeps working if/when the backend relaxes the attributes.
- The raw hex nonce is `value.split(".").last` (the part after the HMAC separator); the full `name=value` is what we send back as the `Cookie` header on `/auth/token`.
- Validate nonce with `^[0-9a-f]{64}$`.
- Do **not** log the cookie value or signature.

Use a dedicated `URLSession` configured with `httpCookieStorage = nil, httpShouldSetCookies = false` for the SIWE auth flow. The manually-carried `Cookie` header is the source of truth; this also keeps SIWE auth state from leaking into any other request via shared cookie storage.

### 4. Add SIWE token exchange

Add request models:

```swift
struct AuthTokenRequest: Encodable {
    let deviceId: String
    let siwe: SIWEPayload?
}

struct SIWEPayload: Encodable {
    let message: String
    let signature: String
}

struct AuthTokenResponse: Decodable {
    let token: String
}
```

Implement:

```swift
public struct BackendAuthSigningContext: Sendable {
    public let address: String
    public let sign: @Sendable (_ message: String) async throws -> Data  // 65-byte r||s||v
}

func authenticateWithSIWE(
    appCheckToken: String,
    signing: BackendAuthSigningContext,
    retryCount: Int
) async throws -> String
```

**Architecture note**: do not let `ConvosAPIClientProtocol` depend on `KeychainIdentity`. The API client should know nothing about the keychain or libxmtp types. Instead, the caller (SessionStateMachine / AuthorizeInboxOperation) loads the identity, builds a `BackendAuthSigningContext` that closes over the private key, and hands it to the API client. The API client treats it as an opaque "sign this string, return 65 bytes" capability. This keeps the protocol surface small and lets the 401-retry path inside `ConvosAPIClient` re-call the closure for a fresh SIWE auth without ever needing to reach into the identity store itself — critical so refresh doesn't silently downgrade to legacy `{ deviceId }` auth when the closure isn't around.

Flow:

1. Request nonce.
2. Build SIWE message with current environment SIWE config and `signing.address`.
3. Sign message via `try await signing.sign(message)` (the closure encapsulates `privateKey.sign(message).rawData` and the v-byte normalization).
4. `POST v2/auth/token` with AppCheck, JSON body, and `Cookie` header from nonce challenge.
5. Save returned JWT only if payload contains `accountId`.
6. On `401`, discard the challenge and start again from nonce; do not reuse nonce.

### 5. Fix token caching semantics

Files:

- `ConvosCore/Sources/ConvosCore/Shared/ConvosKeychainItem.swift`
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift`

Do not reuse a JWT keyed only by device ID for SIWE auth.

Recommended:

```swift
static func jwt(deviceId: String, address: String) -> String {
    "jwt:\(deviceId):siwe:\(address.lowercased())"
}
```

Then:

- For SIWE flow, read/write token under the address-specific key.
- Decode cached JWT and require `exp` valid and `accountId` present.
- On successful SIWE token exchange, delete the legacy device-only JWT if present.
- On account deletion / Delete All Data, delete SIWE JWT for the current identity before deleting identity keys.

This prevents a stale token from a prior identity being reused during the proof run.

### 6. Wire SessionStateMachine to SIWE auth

Files:

- `ConvosCore/Sources/ConvosCore/Inboxes/SessionStateMachine.swift`
- `ConvosCore/Sources/ConvosCore/Inboxes/AuthorizeInboxOperation.swift`
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`

During `authenticateBackend()`:

1. Load current `KeychainIdentity` from `identityStore`.
2. Call SIWE auth, not legacy auth.
3. Keep legacy `{ deviceId }` auth only as an explicit fallback flag during rollout, not as the default path.

Also update `ConvosAPIClient` re-authentication after `401` so refresh uses the same SIWE signer. Otherwise the client will silently downgrade to a legacy device-only token after expiry.

### 7. NSE (Notification Service Extension) compatibility

The Notification Service Extension stays **outside SIWE**. It cannot run the SIWE flow at all — no XMTP identity unlock in an extension process, no interactive signing, and the extension's strict CPU/time budget rules out a per-push SIWE round-trip even if it could. The contract for NSE is:

- NSE uses the existing backend-minted `metadata.notificationExtensionOnly: true` JWT path (no SIWE, no `accountId`). The backend already supports this; the iOS side already stores and refreshes the NSE token via the legacy device-id JWT slot.
- NSE-issued JWTs **must keep passing** `GET /api/v2/auth-check` (which uses `authMiddlewareAllowNSE`). This is the existing liveness probe and the SIWE rollout must not regress it.
- NSE-issued JWTs **must fail** `GET /api/v2/account-auth-check` with `403 Account required` — the new gated route is mounted with `authMiddleware + requireAccount`, which rejects tokens without `accountId`. This is the desired guardrail: SIWE-gated functionality is never reachable from a notification extension.
- The token cache change in §5 (address-scoped SIWE JWT key) must not touch the legacy `KeychainAccount.jwt(deviceId:)` slot that NSE reads from. NSE and the main app keep using disjoint cache entries.

If NSE later needs additional backend cleanup routes (e.g. unregistering a stale push token), expose them as a narrow NSE-safe surface with an explicit allowlist — not broad `/notifications/*` access. The pattern is: tag those routes with `authMiddlewareAllowNSE`, require explicit per-route opt-in to NSE, and do not bypass `requireAccount` for anything that mutates account-owned state.

iOS tests to add alongside the SIWE suite:

- An NSE-flavoured JWT (manually constructed with `metadata.notificationExtensionOnly: true` against the test ES256 key) hits `/auth-check` and gets `200`.
- The same JWT hits `/account-auth-check` and gets `403 Account required`.
- The SIWE JWT cache writer (§5) never overwrites the NSE token slot.

### 8. Add a debug proof action

Files:

- `Convos/Debug View/DebugView.swift` or a new `DebugAuthProbeView.swift`
- optionally `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift`

Add a non-production debug button: **Run Auth Probe**.

Probe output should show:

- nonce acquired: yes/no,
- SIWE signed: yes/no,
- token acquired: yes/no,
- decoded JWT has `accountId`: yes/no,
- gated route status + response body.

For gated route:

- Use `/api/v2/account-auth-check` once backend adds it.
- Keep `/api/v2/auth-check` only as a legacy/NSE JWT liveness check; do not use it to prove SIWE/account auth.

### 9. Tests

Add ConvosCore tests:

- nonce cookie parsing from sample backend `Set-Cookie` headers — both the prod form (`__Host-convos_nonce; HttpOnly; Secure; SameSite=Strict`) and the dev form (`convos_nonce; HttpOnly; SameSite=Lax`).
- SIWE message byte construction (exact-string fixture).
- signature hex encoding is `0x` + 130 hex chars.
- **signature recovery roundtrip**: sign a known message with a fixed key, recover the address from the produced signature, assert it equals the wallet address. Guards the `v`-byte normalization and EIP-191 prefixing.
- token cache rejects no-`accountId` legacy JWT for SIWE flow.
- API client sends:
  - `X-Firebase-AppCheck`,
  - `Cookie: <name>=...` (prod or dev cookie name),
  - body with `deviceId`, `siwe.message`, `siwe.signature`,
  - `X-Convos-AuthToken` for gated route.

### 10. Manual proof checklist

Prereqs:

- Backend on `fbac/authentication-api`, local or dev. Required env (must exactly match the `siwe*` fields in the iOS `config.<env>.json` for the build under test — the values below are for local/dev/PR builds, which all use the dev domain; prod builds use `convos.org` / `https://convos.org`): `SIWE_DOMAIN=dev.convos.org`, `SIWE_URI=https://dev.convos.org`, `SIWE_ALLOWED_CHAIN_IDS=1`, `NONCE_HMAC_SECRET`, ES256 `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEY`, App Check debug token configured (or `app_attest_enabled=false`).
- Backend has `/api/v2/account-auth-check` mounted with `authMiddleware + requireAccount`.
- Backend is emitting the non-prod cookie form on local/dev (`convos_nonce`, no `Secure`).
- iOS `config.local.json` siwe fields exactly match backend env.
- App is signed-in with an XMTP identity.
- Clear any old JWT keychain entries before the first run.

Happy path — open Debug → **Run Auth Probe**, expect:

```
Loading identity… address=0xabc…
Fetching nonce…            → got <hex64> (cookie convos_nonce stored)
Building SIWE message…     → 8-line EIP-4361 message
Signing…                   → 0x<130 hex>  (v normalized to 27/28)
POST /api/v2/auth/token …  → 200 { token: eyJ… }
Decoded JWT                → sub=<deviceId>, accountId=<uuid>, exp=+15m
GET /api/v2/account-auth-check → 200 { success: true }
```

Negative path:

- Same screen, tap **Probe without auth** → `401 Missing auth token` on `/account-auth-check`.

Failure-mode probes (optional; prove robustness, not required for the initial proof):

- Flip one hex char in the signature before sending → expect `401 Invalid SIWE`, and a follow-up clean run must still succeed (the failed signature already burned the previous nonce; the new run fetches a fresh one).
- Delay 6 minutes between `/auth/nonce` and `/auth/token` → expect `401 Invalid nonce` (TTL expired).
- Run the probe twice back-to-back → both succeed (each fetches its own nonce; no replay).
- Sign with the wrong key (e.g., tweak the message but keep the old signature) → expect `401 Invalid SIWE`.
