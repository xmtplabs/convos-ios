# ConvosConnections vs. Integrations (PR #719) — Overlap Analysis

**Status**: Informational / decision memo
**Audience**: Authors of both bodies of work; anyone reviewing either PR
**Related**:
- [`connections-write-capabilities.md`](./connections-write-capabilities.md) — Body A plan
- [`connections-xmtp-adapter.md`](./connections-xmtp-adapter.md) — Body A XMTP bridge
- [`connections-ios.md`](./connections-ios.md) — Body B iOS plan (PR #719)
- [`connections-backend.md`](./connections-backend.md) — Body B backend plan (PR #719)

## TL;DR

Two in-flight bodies of work both use the word "Connections." They are **structurally similar** (per-conversation consent + XMTP wire surface) but **semantically distinct** (device data vs. OAuth-authorized cloud tools). No code-level conflicts today. Recommended actions:

1. **Rename Body B to "Integrations"** — smaller surface area to rename, matches industry convention (Slack, Notion, Linear all distinguish "Connections" from "Integrations" this way).
2. **Keep the two architecturally decoupled** — different trust roots, different write models, different failure semantics. Share a thin UI surface only.
3. **Cross-pollinate one idea** — Body B's "agent posts a card to request a grant" UX pattern is a strict improvement over Body A's current "debug view toggle." Add a `capability_request` content type to Body A in a v0.2 follow-up.

## The two bodies of work

### Body A — `ConvosConnections` (PRs #716, #717, #718)

- Top-level SPM package at `ConvosConnections/` + opt-in sibling `ConvosConnectionsScreenTime` product
- XMTP bridge at `ConvosCore/Sources/ConvosConnectionsXMTP/`
- **Purpose**: stream native iOS sensor data into chats (Health, Calendar, Location, Contacts, Photos, Music, Motion, HomeKit, Screen Time) and let agents drive those same frameworks via structured RPC (Calendar, Contacts, HomeKit, Photos, Health, Music, Screen Time writes)
- **Abstractions**: `DataSource` / `DataSink` protocols, `ConnectionsManager` (actor), `ConnectionPayload`, `ConnectionInvocation`, `ConnectionInvocationResult`, per-`(kind, capability, conversationId)` `Enablement` triples, `ConfirmationHandling` protocol for host-presented confirmation UI
- **Three XMTP content types**: `convos.org/connection_payload/1.0`, `convos.org/connection_invocation/1.0`, `convos.org/connection_invocation_result/1.0`
- **Trust root**: iOS permission prompts + per-framework `authorizationStatus`
- **Write model**: device-side `sink.invoke(invocation)` executes locally, returns a typed 7-status result
- **Consent persistence**: GRDB-local capability triples + optional always-confirm flag (sync across devices TBD)

### Body B — "Connections v0.1" (PR #719, branch `connections`)

- New subsystem at `ConvosCore/Sources/ConvosCore/Connections/`
- **Purpose**: let users OAuth-link third-party SaaS tools (Google Calendar, Google Drive via Composio) and grant per-conversation agent access
- **Abstractions**: `Connection` (OAuth record), `ConnectionGrant(connectionId, conversationId)`, `ConnectionManager` (wraps `ASWebAuthenticationSession`), `ConnectionGrantWriter` (dual-path sync), `ConnectionsMetadataPayload`, `OAuthSessionProvider` (protocol, with `IOSOAuthSessionProvider` in ConvosCoreiOS)
- **One XMTP content type**: `convos.org/connection_grant_request/1.0` — an agent-posted card asking the user to link a service
- **Trust root**: OAuth bearer token held server-side (Convos backend proxies Composio)
- **Write model**: agent calls Composio directly (cloud) — the device never executes the write
- **Consent persistence**: GRDB-local `DBConnectionGrant` + mirrored into XMTP conversation metadata via a `ProfileUpdate` message (atomic rollback on failure) + best-effort appData fallback

## Where they look the same

| Shape | Both bodies |
|---|---|
| Per-conversation consent | ✅ both key consent by `(something, conversationId)` |
| XMTP wire surface | ✅ both add custom content codecs to ConvosCore's registered set |
| Agent ↔ user intermediation | ✅ both let agents access user-scoped resources through Convos |
| Progressive user opt-in | ✅ neither enables anything by default |

The superficial similarity explains why both chose the word "Connections." It's a real observation — the problem shape is the same — but the implementation space is divergent.

## Where they actually differ

| Axis | Body A (ConvosConnections) | Body B (Integrations) |
|---|---|---|
| **Data locus** | On-device (EventKit, HealthKit, CoreLocation, …) | Remote SaaS (Google APIs via Composio) |
| **Trust root** | iOS permission prompt; `authorizationStatus` per framework | OAuth grant in Composio's vault; no iOS permission involved |
| **Credential holder** | N/A — permissions live in the OS | Convos backend (holds `COMPOSIO_API_KEY`); Composio holds tokens |
| **Consent ownership** | Device gates every call before it reaches the OS | Backend gates every call; device never holds the credential |
| **Write model** | `sink.invoke(invocation)` executes locally, returns typed `ConnectionInvocationResult` with 7 discrete statuses | Agent calls Composio; device never executes; result is an ordinary chat message |
| **Per-conversation state** | `Enablement(kind, capability, conversationId)` + optional `alwaysConfirmWrites`, re-checked every invocation | `ConnectionGrant(connectionId, conversationId)` mirrored to ProfileUpdate metadata for agent discovery |
| **Failure model** | Sink never throws; status enum encodes every failure mode | `ConnectionGrantWriter` throws on ProfileUpdate failure and atomically rolls back the DB write |
| **User gesture to enable** | Debug toggle (today); `ConfirmationHandling` sheet at invocation time if always-confirm is on | OAuth via `ASWebAuthenticationSession`, triggered by agent-posted `connection_grant_request` card |
| **Wire content types** | 3 (payload / invocation / invocation result) — machine-to-machine RPC | 1 (grant request) — UI card; writes happen out-of-band |
| **Platform constraints** | Core package compiles on macOS (no UIKit) | Requires iOS (ASWebAuthenticationSession bridged via ConvosCoreiOS) |

## Rename recommendation

Rename **Body B → "Integrations"**. Leave Body A alone.

### Why rename Body B (not A)

- **Blast radius**: Body A has a top-level SPM package, a sibling `ConvosConnectionsScreenTime` product, an XMTP adapter, an example app, two PRDs, ~60+ Swift files, and three committed wire content-types (`convos.org/connection_payload|invocation|invocation_result/1.0`). Body B has ~8 Swift files, 2 DB tables, 1 codec, 2 docs. Roughly an order of magnitude difference.
- **Industry convention**: Slack, Notion, Linear, Zapier, and every large consumer product that does both consistently distinguish "Connections" (device/account-level primitives) from "Integrations" (OAuth-authorized third-party tools). Aligning with that split costs nothing and avoids future product-copy churn.
- **Symbol collision**: `ConnectionManager` (Body B, ConvosCore) vs. `ConnectionsManager` (Body A, ConvosConnections package) differ by a trailing `s`. Guaranteed misread in Grep, autocomplete, and PR review. `ConnectionKind` (device sensor enum in Body A) vs. `Connection` (OAuth record in Body B) will be in scope together in any ConvosCore file that imports both.

### Concrete renames (Body B only)

| Before | After |
|---|---|
| `ConvosCore/Sources/ConvosCore/Connections/` | `ConvosCore/Sources/ConvosCore/Integrations/` |
| `Connection`, `ConnectionStatus` | `Integration`, `IntegrationStatus` |
| `ConnectionGrant` | `IntegrationGrant` |
| `ConnectionManager` | `IntegrationManager` |
| `ConnectionRepository` | `IntegrationRepository` |
| `ConnectionGrantWriter` | `IntegrationGrantWriter` |
| `ConnectionServiceNaming` | `IntegrationServiceNaming` |
| `ConnectionsMetadataPayload` | `IntegrationsMetadataPayload` |
| `MockConnectionManager` | `MockIntegrationManager` |
| `ConnectionGrantRequestCodec` | `IntegrationGrantRequestCodec` |
| DB tables `connection`, `connectionGrant` | `integration`, `integrationGrant` |
| Deep link `convos://connections/grant?…` | `convos://integrations/grant?…` |
| XMTP content type `convos.org/connection_grant_request/1.0` | `convos.org/integration_grant_request/1.0` |
| `docs/plans/connections-ios.md` | `docs/plans/integrations-ios.md` |
| `docs/plans/connections-backend.md` | `docs/plans/integrations-backend.md` |

Since Body B hasn't shipped to the wire yet, the content-type string rename is free.

## Architectural recommendation: keep decoupled

The agents reviewed whether to unify these under a single `DataSource`/`DataSink` abstraction with pluggable transports. Verdict: **don't**. The coincidence that both reduce to "consent-scoped-to-conversation" is the shape of a consent gesture, not the shape of a data pipe. Body B has no source side, no payload emission, no action schema, no sink invocation path. Agents call Composio themselves once the grant exists — the device never executes.

### Where they should touch (thin surface)

1. **Settings UI** — a single per-conversation "Connections" (or whatever the product term becomes) screen listing both device capabilities and OAuth integrations, with a row-level chip indicating consent mode ("Confirm each time" vs. "Connected").
2. **Shared taxonomy types** — a lightweight view-model-level `ConnectionSubject` (or similar) enum that lets the UI say "this row is a device Calendar" vs. "this row is Google Calendar" without importing both manager APIs.
3. **Shared confirmation host** — if Body A's `ConfirmationHandling` ever needs to prompt for an OAuth-backed action (unlikely in v1), the same sheet presenter can serve both.

### Where they must not touch

- Do not merge `EnablementStore` with `ConnectionGrant` persistence. Different invariants, different failure modes.
- Do not route `ConnectionInvocation` through the Composio path or the grant-request path through `ConnectionsManager`. They answer different questions ("may I do X on the device?" vs. "have you linked service Y?").
- Do not introduce a pluggable transport under `DataSink`. Body B isn't a transport variation of Body A — it's a different protocol entirely (agent writes directly; device never invokes).

## Cross-pollination: adopt Body B's agent-initiated card

Body B's best idea (from Body A's POV) is the **`connection_grant_request` card pattern**: the agent posts a card in the conversation asking the user for permission, the user taps Approve, and the grant is flipped on. This is a much better first-time UX than Body A's current debug-view toggles.

### Proposed Body A v0.2 addition

Define a fourth content type `convos.org/capability_request/1.0` carrying:

```swift
struct CapabilityRequest: Codable, Sendable {
    let requestId: String
    let kind: ConnectionKind          // .health, .calendar, .contacts, …
    let capability: ConnectionCapability  // .read | .writeCreate | .writeUpdate | .writeDelete
    let rationale: String             // human-readable justification
    let conversationId: String
}
```

On arrival, the client renders a card in the conversation. On Approve, the client calls `manager.setEnabled(true, kind:, capability:, conversationId:)` and posts a `capability_request_result` (or reuses `ConnectionInvocationResult` with a new status). On Deny, the same but with `status: .denied`.

This replaces the always-confirm toggle as the *first-time* consent moment. Always-confirm remains useful for re-confirming destructive/irreversible writes on an ongoing basis.

Scope note: out of scope for the current three-PR stack. Worth its own PRD and PR.

## Consent-model compatibility

| Consent mode | Best fit | Why |
|---|---|---|
| **Always-confirm (per-call)** | Destructive device writes (Calendar event creation, Health sample writes) | Per-call review has real safety value when the action is irreversible and the framework has no cloud-side undo |
| **One-time OAuth grant** | OAuth-linked services where the provider already enforces scope at its side | Friction cost of re-prompting exceeds safety gain; Composio has its own revocation UX |
| **Enable-with-rationale (proposed `capability_request`)** | First-time enablement of any device kind | Makes the enablement moment explicit and user-visible instead of hidden behind a settings toggle |

Under a shared settings UI, present the active consent state but don't expose the underlying mechanism. A row-level chip showing "Confirm each time" vs. "Connected" is enough.

## Wire-format housekeeping

### Namespace

Both bodies use `convos.org/*` for their codec authority. Consistent. No change needed. (Earlier draft of Body A's xmtp-adapter PRD had a stray `xyz.convos/*` reference — that has been fixed.)

### Content-type file layout

- Body A codecs live in `ConvosCore/Sources/ConvosConnectionsXMTP/Codecs/` (sibling target)
- Body B codec lives in `ConvosCore/Sources/ConvosCore/Custom Content Types/`

Two different homes. After the rename, options are:
- (a) Body B's codec also moves to a sibling `ConvosIntegrationsXMTP/` target — symmetric, and lets each feature own its own XMTP bridge
- (b) Both collapse back into `ConvosCore/Sources/ConvosCore/Custom Content Types/` — simpler, matches the existing convention for the ~8 other Convos codecs
- (c) Leave them split — fine short-term, worth a cleanup later

My bias: (b). Custom XMTP codecs are shallow enough that a sibling target per feature is more ceremony than clarity. The reason Body A has a sibling target is that it wraps the transport-agnostic ConvosConnections package; Body B has no equivalent need.

## Migration / ordering

Body A is already committed as three stacked PRs (#716 → #717 → #718) on top of merged `dev` (post-713). Body B (PR #719) is still open.

There are no code-level merge conflicts between the two. The only shared file surface is `docs/plans/`, where both sides add files without overlap.

**Recommended landing order:**

1. Body B author renames the subsystem on PR #719 (one mechanical commit).
2. PR #719 merges.
3. Body A's stack (#716 → #718) rebases onto the new `dev` — no conflicts expected since filenames and symbol names won't collide post-rename.
4. Body A v0.2: `capability_request` PR stacks on top of #718 once designs are locked.
5. Body A main-app integration PR (the deferred "wire into InboxStateMachine" work) — stacks alongside v0.2.

## Open questions (for product / product-engineering)

1. **Settings surface**: one unified "Connections" tab listing both, or two separate "Connections" + "Integrations" tabs? Unified feels right to me; matches how users think.
2. **Sync across devices**: Body A's `Enablement` table isn't yet synced across the user's installations. Body B's grants are synced via ProfileUpdate (since the runtime reads them). Should Body A's enablement also flow through a ProfileUpdate-style mirror, or stay device-local?
3. **Revocation UX parity**: Body B revokes via Composio (backend call + ProfileUpdate). Body A revokes via a local toggle + OS Settings link. Worth aligning the end-user flow language even if the internals differ.

## Appendix: what each side ships on the wire

### Body A wire content types
```
convos.org/connection_payload/1.0            # device → agent (sensor events)
convos.org/connection_invocation/1.0         # agent → device (write request)
convos.org/connection_invocation_result/1.0  # device → agent (write outcome)
```

### Body B wire content types (before rename)
```
convos.org/connection_grant_request/1.0      # agent → user (UI card)
```

### Body B wire content types (after rename)
```
convos.org/integration_grant_request/1.0
```

### Body A proposed v0.2
```
convos.org/capability_request/1.0            # agent → user (UI card for native iOS capability)
```

Four content types total, cleanly namespaced: `connection_*` = device data/commands, `integration_*` = OAuth tool grants, `capability_*` = agent-initiated consent prompts (the card-pattern family). No collisions, no overloaded prefixes.
