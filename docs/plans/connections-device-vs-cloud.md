# Connections — Device vs. Cloud (PR #719) — Overlap Analysis

**Status**: Informational / decision memo
**Audience**: Authors of both bodies of work; anyone reviewing either PR
**Related**:
- [`connections-write-capabilities.md`](./connections-write-capabilities.md) — Body A plan (device side)
- [`connections-xmtp-adapter.md`](./connections-xmtp-adapter.md) — Body A XMTP bridge
- [`connections-ios.md`](./connections-ios.md) — Body B iOS plan (PR #719)
- [`connections-backend.md`](./connections-backend.md) — Body B backend plan (PR #719)

## TL;DR

Two in-flight bodies of work both contribute to the user-facing **Connections** feature. They are **structurally similar** (per-conversation consent + XMTP wire surface) but **semantically distinct** along the *device vs. cloud* axis. No code-level conflicts today. Recommended actions:

1. **Pick a shared product term and engineering taxonomy.** Product surface stays "Connections" (one umbrella). Internal types use `Device` / `Cloud` as sibling labels under that umbrella.
2. **Rename Body B's symbols** to use the `CloudConnection*` prefix so they read clearly alongside Body A's `Connection*`-shaped symbols (and don't collide with `ConvosConnections` package-level types).
3. **Keep the two architecturally decoupled** — different trust roots, different write models, different failure semantics. Share a thin UI surface only.
4. **Cross-pollinate one idea** — Body B's "agent posts a card to request a grant" UX pattern is a strict improvement over Body A's current "debug view toggle." That idea graduates into the unified `capability_request` content type defined in [`capability-resolution.md`](./capability-resolution.md).

## The two bodies of work

### Body A — `ConvosConnections` / device side (PRs #716, #717, #718)

- Top-level SPM package at `ConvosConnections/` + opt-in sibling `ConvosConnectionsScreenTime` product
- XMTP bridge at `ConvosCore/Sources/ConvosConnectionsXMTP/`
- **Purpose**: stream native iOS sensor data into chats (Health, Calendar, Location, Contacts, Photos, Music, Motion, HomeKit, Screen Time) and let agents drive those same frameworks via structured RPC (Calendar, Contacts, HomeKit, Photos, Health, Music, Screen Time writes)
- **Abstractions**: `DataSource` / `DataSink` protocols, `ConnectionsManager` (actor), `ConnectionPayload`, `ConnectionInvocation`, `ConnectionInvocationResult`, per-`(kind, capability, conversationId)` `Enablement` triples, `ConfirmationHandling` protocol for host-presented confirmation UI
- **Three XMTP content types**: `convos.org/connection_payload/1.0`, `convos.org/connection_invocation/1.0`, `convos.org/connection_invocation_result/1.0`
- **Trust root**: iOS permission prompts + per-framework `authorizationStatus`
- **Write model**: device-side `sink.invoke(invocation)` executes locally, returns a typed 7-status result
- **Consent persistence**: GRDB-local capability triples + optional always-confirm flag (sync across devices TBD)

### Body B — Cloud side (PR #719, branch `connections`)

- New subsystem at `ConvosCore/Sources/ConvosCore/Connections/` (to be renamed `CloudConnections/`)
- **Purpose**: let users OAuth-link third-party SaaS tools (Google Calendar, Google Drive via Composio) and grant per-conversation agent access
- **Abstractions** (current symbols → recommended renames in [Concrete renames](#concrete-renames-body-b-only)): `Connection` (OAuth record), `ConnectionGrant(connectionId, conversationId)`, `ConnectionManager` (wraps `ASWebAuthenticationSession`), `ConnectionGrantWriter` (dual-path sync), `ConnectionsMetadataPayload`, `OAuthSessionProvider` (protocol, with `IOSOAuthSessionProvider` in ConvosCoreiOS)
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

The superficial similarity explains why both naturally landed on the word "Connections." It's a real observation — the problem shape is the same. The implementation space is divergent.

## Where they actually differ

| Axis | Body A (Device) | Body B (Cloud) |
|---|---|---|
| **Data locus** | On-device (EventKit, HealthKit, CoreLocation, …) | Remote SaaS (Google APIs via Composio) |
| **Trust root** | iOS permission prompt; `authorizationStatus` per framework | OAuth grant in Composio's vault; no iOS permission involved |
| **Credential holder** | N/A — permissions live in the OS | Convos backend (holds `COMPOSIO_API_KEY`); Composio holds tokens |
| **Consent ownership** | Device gates every call before it reaches the OS | Backend gates every call; device never holds the credential |
| **Write model** | `sink.invoke(invocation)` executes locally, returns typed `ConnectionInvocationResult` with 7 discrete statuses | Agent calls Composio; device never executes; result is an ordinary chat message |
| **Per-conversation state** | `Enablement(kind, capability, conversationId)` + optional `alwaysConfirmWrites`, re-checked every invocation | `CloudGrant(cloudConnectionId, conversationId)` mirrored to ProfileUpdate metadata for agent discovery |
| **Failure model** | Sink never throws; status enum encodes every failure mode | `CloudGrantWriter` throws on ProfileUpdate failure and atomically rolls back the DB write |
| **User gesture to enable** | Debug toggle (today); `ConfirmationHandling` sheet at invocation time if always-confirm is on | OAuth via `ASWebAuthenticationSession`, triggered by agent-posted `connection_grant_request` card |
| **Wire content types** | 3 (payload / invocation / invocation result) — machine-to-machine RPC | 1 (grant request) — UI card; writes happen out-of-band |
| **Platform constraints** | Core package compiles on macOS (no UIKit) | Requires iOS (ASWebAuthenticationSession bridged via ConvosCoreiOS) |

## Naming recommendation

Keep **"Connections"** as the user-facing umbrella term. Both bodies live under it. Internally distinguish them along the `Device` / `Cloud` axis.

### Why `Device` / `Cloud`

- **Same axis**: both labels describe location. Symmetric pairs read more clearly than mixed pairs (e.g. `Local` / `ThirdParty` mixes location with relationship).
- **What users already say**: "on my device" is normal English; "in the cloud" is normal English. If either label ever leaks into UI copy ("Apple Calendar — on device"), it reads naturally.
- **Aligns with Apple's house style**: iOS Settings uses "Device" framing (Privacy report, on-device storage, Device Management).
- **Reads cleanly in code**: `DeviceProvider` / `CloudProvider`, `device.calendar` / `cloud.google_calendar`. No name collisions with the `ConvosConnections` package or `ConnectionsManager`.

### Why rename Body B (not A)

- **Blast radius**: Body A has a top-level SPM package, a sibling `ConvosConnectionsScreenTime` product, an XMTP adapter, an example app, two PRDs, ~60+ Swift files, and three committed wire content-types (`convos.org/connection_payload|invocation|invocation_result/1.0`). Body B has ~8 Swift files, 2 DB tables, 1 codec, 2 docs. Roughly an order of magnitude difference.
- **Symbol collision**: `ConnectionManager` (Body B, ConvosCore) vs. `ConnectionsManager` (Body A, ConvosConnections package) differ by a trailing `s`. Guaranteed misread in Grep, autocomplete, and PR review. `ConnectionKind` (device sensor enum in Body A) vs. `Connection` (OAuth record in Body B) will be in scope together in any ConvosCore file that imports both.
- **Body A's symbols are agent-facing wire format**. Renaming `ConnectionInvocation` would force every agent integration (current and future) to migrate. Renaming Body B's symbols touches only Convos client code.

### Concrete renames (Body B only)

| Before | After |
|---|---|
| `ConvosCore/Sources/ConvosCore/Connections/` | `ConvosCore/Sources/ConvosCore/CloudConnections/` |
| `Connection`, `ConnectionStatus` | `CloudConnection`, `CloudConnectionStatus` |
| `ConnectionGrant` | `CloudGrant` |
| `ConnectionManager` | `CloudConnectionManager` |
| `ConnectionRepository` | `CloudConnectionRepository` |
| `ConnectionGrantWriter` | `CloudGrantWriter` |
| `ConnectionServiceNaming` | `CloudServiceNaming` |
| `ConnectionsMetadataPayload` | (delete — manifest moves to unified `capabilities` payload; see [`capability-resolution.md`](./capability-resolution.md)) |
| `MockConnectionManager` | `MockCloudConnectionManager` |
| `ConnectionGrantRequestCodec` | `CloudGrantRequestCodec` |
| DB tables `connection`, `connectionGrant` | `cloudConnection`, `cloudGrant` |
| Deep link `convos://connections/grant?…` | `convos://connections/grant/cloud?…` (still under the `connections` namespace; cloud is the qualifier) |
| `docs/plans/connections-ios.md` | unchanged (PRD covers the cloud half of the Connections feature; filename stays generic) |
| `docs/plans/connections-backend.md` | unchanged (same reason) |

### Wire content-type naming

The XMTP content type `convos.org/connection_grant_request/1.0` **stays as-is**. Agents shouldn't have to know whether a grant they're requesting is device-backed or cloud-backed — both are "connections" from the agent's POV. The card the user sees handles the routing internally.

This is also why the future card-pattern card lives under the unified `capability_request` namespace (see [`capability-resolution.md`](./capability-resolution.md)) rather than splitting into `device_capability_request` + `cloud_capability_request`.

## Architectural recommendation: keep decoupled

The agents reviewed whether to unify these under a single `DataSource`/`DataSink` abstraction with pluggable transports. Verdict: **don't**. The coincidence that both reduce to "consent-scoped-to-conversation" is the shape of a consent gesture, not the shape of a data pipe. Body B has no source side, no payload emission, no action schema, no sink invocation path. Agents call Composio themselves once the grant exists — the device never executes.

### Where they should touch (thin surface)

1. **Settings UI** — a single per-conversation **Connections** screen listing both device capabilities and cloud connections, with a row-level chip indicating consent mode ("Confirm each time" vs. "Connected") and provider locus (a small device or cloud glyph).
2. **Capability resolver** — both register providers against `CapabilityProviderRegistry`; the resolver routes agent capability requests across both. Detail in [`capability-resolution.md`](./capability-resolution.md).
3. **Shared confirmation host** — if Body A's `ConfirmationHandling` ever needs to prompt for a cloud-backed action (unlikely in v1), the same sheet presenter can serve both.

### Where they must not touch

- Do not merge `EnablementStore` with `CloudGrant` persistence. Different invariants, different failure modes.
- Do not route `ConnectionInvocation` through the Composio path or the cloud-grant-request path through `ConnectionsManager`. They answer different questions ("may I do X on the device?" vs. "have you linked service Y?"). The capability resolver dispatches by subject across both — but each subsystem's internals stay isolated.
- Do not introduce a pluggable transport under `DataSink`. Body B isn't a transport variation of Body A — it's a different protocol entirely (agent writes directly; device never invokes).

## Cross-pollination: agent-initiated card pattern

Body B's best idea (from Body A's POV) is the **`connection_grant_request` card pattern**: the agent posts a card in the conversation asking the user for permission, the user taps Approve, and the grant is flipped on. This is a much better first-time UX than Body A's current debug-view toggles.

That idea has graduated into the unified [`capability_request`](./capability-resolution.md#new-content-type-convosorgcapability_request10) content type. One agent-side request shape covers both the "give me access to your calendar" device case and the "link your Google Calendar" cloud case; the picker-card UI handles the routing.

`connection_grant_request/1.0` continues to exist for now as the cloud-only card Body B was already shipping. Once the unified `capability_request` lands and the picker card is in place, `connection_grant_request` can be deprecated in favor of the unified card. Two-step migration so Body B can ship without waiting on the resolver work.

## Consent-model compatibility

| Consent mode | Best fit | Why |
|---|---|---|
| **Always-confirm (per-call)** | Destructive device writes (Calendar event creation, Health sample writes) | Per-call review has real safety value when the action is irreversible and the framework has no cloud-side undo |
| **One-time OAuth grant** | Cloud connections where the provider already enforces scope at its side | Friction cost of re-prompting exceeds safety gain; Composio has its own revocation UX |
| **Enable-with-rationale (`capability_request`)** | First-time enablement of any device capability or cloud connection | Makes the enablement moment explicit and user-visible instead of hidden behind a settings toggle |

Under a shared settings UI, present the active consent state but don't expose the underlying mechanism. A row-level chip showing "Confirm each time" vs. "Connected" is enough.

## Wire-format housekeeping

### Namespace

Both bodies use `convos.org/*` for their codec authority. Consistent. No change needed.

### Content-type file layout

- Body A codecs live in `ConvosCore/Sources/ConvosConnectionsXMTP/Codecs/` (sibling target — wraps the transport-agnostic `ConvosConnections` package)
- Body B codec lives in `ConvosCore/Sources/ConvosCore/Custom Content Types/`

After the rename:
- Body A stays where it is — sibling target structure is justified by wrapping a separate package
- Body B's codec stays in `Custom Content Types/` — symmetric with the ~8 other Convos codecs there; cloud doesn't have a wrapped-package equivalent

## Migration / ordering

Body A is already committed as three stacked PRs (#716 → #717 → #718) on top of merged `dev` (post-713). Body B (PR #719) is still open.

There are no code-level merge conflicts between the two. The only shared file surface is `docs/plans/`, where both sides add files without overlap.

**Recommended landing order:**

1. Body B author renames its symbols to `CloudConnection*` per the [renames table](#concrete-renames-body-b-only). One mechanical commit.
2. PR #719 merges.
3. Body A's stack (#716 → #718) rebases onto the new `dev` — no conflicts expected since filenames and symbol names won't collide post-rename.
4. Capability resolution PR ([`capability-resolution.md`](./capability-resolution.md)) stacks on top of #718, adding the `CapabilityProviderRegistry`, the resolver, the `capability_request` content type, the picker card, and the unified `capabilities` manifest.
5. Body A `capability_request` adoption — small follow-up replacing the debug-view toggle as the first-time-consent UX moment.
6. Body A main-app integration PR (the deferred "wire into InboxStateMachine" work).

## Open questions (for product / product-engineering)

1. **Sync across devices**: Body A's `Enablement` table isn't yet synced across the user's installations. Body B's grants are synced via ProfileUpdate (since the runtime reads them). Should Body A's enablement also flow through a ProfileUpdate-style mirror, or stay device-local? (The unified [capabilities manifest](./capability-resolution.md#runtime-capabilities-manifest) covers the agent-discovery case but doesn't sync user state across devices.)
2. **Revocation UX parity**: Body B revokes via Composio (backend call + ProfileUpdate). Body A revokes via a local toggle + OS Settings link. Worth aligning the end-user flow language even if the internals differ.
3. **Settings surface**: a single per-conversation Connections list with one row per provider feels right. Worth a design pass on the row chips that distinguish device vs. cloud and show the active consent mode.

## Appendix: what each side ships on the wire

### Body A (device) wire content types
```
convos.org/connection_payload/1.0            # device → agent (sensor events)
convos.org/connection_invocation/1.0         # agent → device (write request)
convos.org/connection_invocation_result/1.0  # device → agent (write outcome)
```

### Body B (cloud) wire content types
```
convos.org/connection_grant_request/1.0      # agent → user (UI card)
```
(Unchanged through the symbol-level rename — agents don't need to know whether a grant is device-backed or cloud-backed.)

### Unified addition (in [`capability-resolution.md`](./capability-resolution.md))
```
convos.org/capability_request/1.0            # agent → user (picker card across device + cloud)
convos.org/capability_request_result/1.0     # device → agent (resolution outcome)
```

Five content types total, single namespace under `connection_*` and `capability_*`. The `capability_*` family handles agent-initiated picker UX; the `connection_*` family handles per-provider plumbing (payloads, RPC, grants). No collisions.
