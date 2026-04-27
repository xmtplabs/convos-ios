# Cloud Connections v0.1 — Backend Implementation Plan

> **Vocabulary:** "Cloud Connections" = Composio-brokered SaaS integrations. The "Device Connections" pathway (`ConvosConnections` Swift package) lives entirely on-device and has no backend dependency.

## Context

The iOS Cloud Connections feature needs the backend to do **one thing only**: hold the `COMPOSIO_API_KEY` and proxy Composio REST calls. Everything else lives elsewhere:

| State | Where it lives |
|-------|---------------|
| OAuth tokens | Composio's vault |
| Connection metadata | Composio's database |
| Grants | XMTP conversation metadata |
| User identity | XMTP (inbox ID) |
| Triggers / webhooks | Composio → runtime's public URL |

**The backend stores nothing.** It's a stateless HTTP proxy that adds the `COMPOSIO_API_KEY` header and forwards calls to Composio.

---

## Authentication

The backend already has a JWT / signed-request auth mechanism (used by existing endpoints like `v2/invite-codes`, `v2/agents/join`). The JWT is **device-scoped** and already contains the `deviceId`.

For Connections, the backend needs one thing from auth: **the caller's deviceId** (to derive the Composio entity ID). It does NOT need to look up a user record.

---

## Entity ID Convention

`entityId = deviceId` — derived from the JWT on every request, never stored.

**Why deviceId (not inboxId):**
- Connection is an app-level concept ("my iPhone's Google Calendar"), not an inbox concept
- If the device is wiped/replaced → clean slate, user reconnects (acceptable for v0.1)
- Matches existing JWT scoping (backend already thinks in terms of devices)
- The inboxId lives in XMTP metadata (runtime's domain), not Composio

One Composio entity = one Convos installation. The backend doesn't maintain any user ↔ entity mapping; the mapping is implicit.

---

## Endpoints (pure pass-through)

Each endpoint is a ~10-line function: extract inbox ID from auth, call Composio SDK, return the response. No database queries, no writes, no caching.

### `POST /v2/connections/initiate`

```
Request:  { "serviceId": "google_calendar" }
Response: { "connectionRequestId": "...", "redirectUrl": "https://..." }
```

```pseudocode
deviceId = verifyAuth(request)   // from existing JWT
result = composio.connectedAccounts.initiate({
  entityId: deviceId,
  appName: request.body.serviceId,
  redirectUri: "convos://connections/callback"
})
return { connectionRequestId: result.id, redirectUrl: result.redirectUrl }
```

### `POST /v2/connections/complete`

```
Request:  { "connectionRequestId": "..." }
Response: { connectionId, serviceId, serviceName, composioEntityId, composioConnectionId, status }
```

```pseudocode
deviceId = verifyAuth(request)
conn = composio.connectedAccounts.get({ connectionRequestId: request.body.connectionRequestId })
if conn.entityId != deviceId: return 403
return mapComposioToResponse(conn)
```

The entity-ID check is the only "security" logic: it ensures a caller can't complete a connection request belonging to a different device. Pure validation — no state consulted.

### `GET /v2/connections`

```pseudocode
deviceId = verifyAuth(request)
list = composio.connectedAccounts.list({ entityId: deviceId })
return list.map(mapComposioToResponse)
```

### `DELETE /v2/connections/{id}`

```pseudocode
deviceId = verifyAuth(request)
conn = composio.connectedAccounts.get({ connectedAccountId: request.params.id })
if conn.entityId != deviceId: return 403
composio.connectedAccounts.delete({ connectedAccountId: request.params.id })
return 204
```

Same pattern: verify the connection belongs to the caller's device, then delete.

---

## What This Looks Like in Code

The whole thing is roughly 4 handlers + a Composio SDK wrapper. No migrations, no models, no database changes. Add to whatever auth middleware already exists for other endpoints.

---

## Environment Config

Add `COMPOSIO_API_KEY` to:
- `.env.local`
- `.env.dev`
- `.env.prod`

Per-environment Composio projects recommended (so dev testing doesn't touch prod user data).

---

## One-Time Setup (not code)

1. Create Composio account, get API key
2. Register Convos' own Google OAuth app in Google Cloud Console
3. Plug Google OAuth credentials into Composio's integration config
4. Whitelist `convos://connections/callback` as an allowed redirect URI in Composio

---

## Testing

Because there's no state, tests are simple:

1. **Happy path** — mock Composio SDK, verify the 4 handlers forward correctly and derive `entityId` from auth
2. **Entity mismatch** — `complete` / `delete` with a connection belonging to a different device → 403
3. **No auth** — all 4 endpoints → 401

No integration test with a real database needed. No user fixtures. No cleanup.

---

## What This Backend Plan Does NOT Include

- ❌ User tables
- ❌ Connection tables
- ❌ Grant tables
- ❌ Webhook handlers (Composio → runtime, not backend)
- ❌ Background jobs
- ❌ Caching

If the code starts touching any of the above, something has gone wrong.
