# ADR 012: Connections Architecture (Device + Cloud)

> **Status**: Accepted (2026-04-28).
> **Related**: [ADR 005 — Member Profile System](./005-member-profile-system.md)
> (cloud-grant payload rides on member-profile metadata),
> [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md)
> (single inbox is what `senderId` resolves to).
> **PRDs**:
> [`docs/plans/connections-device-vs-cloud.md`](../plans/connections-device-vs-cloud.md),
> [`docs/plans/connections-write-capabilities.md`](../plans/connections-write-capabilities.md),
> [`docs/plans/connections-xmtp-adapter.md`](../plans/connections-xmtp-adapter.md),
> [`docs/plans/capability-resolution.md`](../plans/capability-resolution.md)
> (the planned unification surface).

## Context

Agents reach into the user's life in two fundamentally different ways:

1. **Device data sources.** HealthKit, EventKit, Contacts, Photos, Music,
   CoreLocation, CoreMotion, HomeKit, Family Controls. The data lives on the
   user's device, gated by per-framework iOS authorization. Reads and writes
   happen locally in-process; there's no upstream cloud account.
2. **Cloud OAuth services.** Google Calendar, Slack, Notion, etc. The data
   lives on a third-party server, gated by an OAuth grant. Reads and writes
   happen against the third-party API — typically through a broker like
   Composio so we don't ship N OAuth flows.

Both subsystems share a vocabulary ("a capability the user has granted to a
conversation") but the wire shape, the storage shape, and the runtime are
materially different. The two integrations were initially scoped together
as one "Connections" feature, then split into two parallel tracks because
the cloud-OAuth flow needed to ship before the device-sink package was
ready, and because the agent-runtime contract for each is different.

The risk of leaving them undocumented is the naming collision we already
have: a top-level package named `ConvosConnections` (device) and a
ConvosCore subsystem named `Connections` (cloud) that look related but
aren't unified at the agent interface.

## Decision Drivers

- [x] Cross-platform reusability — the device package should be usable
      outside of the main Convos app.
- [x] Clean module boundaries — XMTP wire concerns shouldn't leak into
      domain types.
- [x] Forward compatibility — agents and devices ship on independent
      cadences via different repositories (convos-ios, convos-cli, agent
      runtimes); schema evolution must not require lockstep deploys.
- [x] Authorization isolation — iOS framework permissions and OAuth
      grants have different consent UX and persistence semantics; one
      shouldn't have to know about the other.
- [x] Future unification path — the
      [Capability Resolution PRD](../plans/capability-resolution.md)
      eventually fronts both subsystems behind a single agent-facing
      surface; today's design must not foreclose that.

## Decision

We ship **two distinct subsystems** under one conceptual umbrella, each
optimized for its own runtime, and unify them later via the planned
capability resolver. Both subsystems are described below.

### Subsystem A — `ConvosConnections` (device data sources)

Top-level Swift package at `ConvosConnections/`. Cross-platform (iOS +
macOS), no XMTP dependency.

**Domain types** (`Core/`):
- `ConnectionKind` — taxonomy of supported sources (`.health`, `.calendar`,
  `.location`, `.contacts`, `.photos`, `.music`, `.motion`, `.homeKit`,
  `.screenTime`).
- `ConnectionPayload` — sensor read envelope (device → agent). Carries
  `schemaVersion`, `ConnectionPayloadBody` (per-kind body), `capturedAt`.
- `ConnectionInvocation` — agent → device write request. Carries an
  `invocationId`, `kind`, `ConnectionAction(name:, arguments:)`, and a
  `schemaVersion`.
- `ConnectionInvocationResult` — device → agent reply, always emitted,
  always carries the originating `invocationId`. Status enum:
  `success | capabilityNotEnabled | capabilityRevoked |`
  `requiresConfirmation | authorizationDenied | executionFailed |`
  `unknownAction`.
- `ActionSchema` / `ActionParameter` — declarative per-action metadata
  published by each sink (`name`, `inputs`, `outputs`, `capability`).
- `ArgumentValue` — tagged value union (`{type, value}` on the wire) so
  argument types are explicit and safely extensible.

**Sink contract** (`DataSink`):
- `actionSchemas() async -> [ActionSchema]` — what this sink exposes.
- `invoke(_ invocation:) async -> ConnectionInvocationResult` — execute
  one write. Sinks are responsible for their own iOS authorization checks
  and translation of arguments into framework calls (e.g. `EKEvent`).

**Source contract** (`DataSource`):
- Owns the iOS framework client (e.g. `EKEventStore`, `HMHomeManager`),
  observes change notifications, emits `ConnectionPayload`s through the
  injected `ConnectionDelivering` whenever the host says a payload should
  be delivered for an enabled conversation.

**Manager** (`ConnectionsManager`):
- Registers sources and sinks per `ConnectionKind`.
- Gates incoming `ConnectionInvocation`s against an `EnablementStore` that
  tracks per-`(kind, capability, conversationId)` toggles.
- Fan-outs payloads to every conversation enabled for that source's read
  capability.
- Serializes the result through the host-supplied `ConnectionDelivering`.

**ScreenTime is gated behind a separate library product**
(`ConvosConnectionsScreenTime`) because the
`com.apple.developer.family-controls` entitlement requires Apple's
explicit approval; apps that don't have it depend on `ConvosConnections`
alone and skip the ScreenTime sink registration.

**Authorization is per-source.** There is no central permission flow.
Each `DataSource` owns its own `requestAuthorization()` and reports back
through `ConnectionAuthorizationStatus { notDetermined | denied | partial`
`| authorized }`. This mirrors iOS — HealthKit, EventKit, and Contacts
each have different consent UIs that we don't try to homogenize.

### Subsystem B — Cloud Connections (Composio OAuth)

Lives inside ConvosCore at `Sources/ConvosCore/CloudConnections/`. Tied to
ConvosCore because grants persist in GRDB and ride on member-profile
custom metadata.

**Domain types**:
- `CloudConnection` / `CloudConnectionGrant` — value objects representing a service
  a user has linked (Google Calendar, Slack, Notion, …) and the per-
  conversation grant that lets agents act on it.
- `CloudConnectionsMetadataPayload` — JSON-string payload stored on the
  member-profile under the `connections` key. Contains the sender's
  grants only (each member writes their own profile).
- `CloudConnectionGrantEntry` — one entry inside that payload, shape matches
  the agent runtime's expected format exactly so an agent reading the
  member profile can route directly to a Composio entity.

**Wire**:
- `convos.org/connection_grant_request/1.0` — agent → user content type.
  Renders as a `CloudConnectionGrantRequestCardView` in the conversation; the
  user taps "Open Settings" to start the OAuth flow.
- The grant itself is **not** transmitted as a message. Once the OAuth
  flow completes via `ConvosAPIClient.completeCloudConnection`, a
  `CloudConnectionGrantEntry` is appended to the sender's
  `CloudConnectionsMetadataPayload` and re-published as part of the next
  `ProfileUpdate`. Agents observe grants by reading the member profile;
  there is no separate handshake.

**Authorization**: a single OAuth flow per service per device, brokered
by Composio. The user authorizes once for an account; the
`CloudConnectionGrantEntry` records the per-conversation scope (currently
fixed at `"conversation"`).

**Storage**: GRDB tables (`DBCloudConnection`, `DBCloudConnectionGrant`) for the
local materialized view; the canonical state is the member-profile
metadata, which the sync layer keeps in sync with the runtime.

**Authority**: the runtime (`runtime/convos-platform/skills/connections/`)
calls Composio with the `composioEntityId` /
`composioConnectionId` it reads off the member-profile `connections`
field. The iOS device is **not** in the loop for cloud calls — the agent
acts directly against the third-party API.

### XMTP wire layer (`ConvosConnectionsXMTP`)

A **second, separate package** under `ConvosCore/Sources/ConvosConnections-`
`XMTP/` that sits between Subsystem A's Swift types and XMTPiOS. Three
codecs:

| Codec                              | Direction        | Content type                             |
|------------------------------------|------------------|------------------------------------------|
| `ConnectionPayloadCodec`           | device → agent   | `convos.org/connection_payload/1.0`      |
| `ConnectionInvocationCodec`        | agent → device   | `convos.org/connection_invocation/1.0`   |
| `ConnectionInvocationResultCodec`  | device → agent   | `convos.org/connection_invocation_result/1.0` |

All three encode their `Codable` Swift type as JSON. JSON over protobuf
because (a) human-readable for debugging; (b) easier schema evolution
than fixed protobuf field numbers; (c) the agent runtime's natural
form is JSON tool calls anyway.

`XMTPConnectionDelivery` implements `ConnectionDelivering` over an
injected conversation-lookup closure — the package never sees ConvosCore's
GRDB-backed conversation storage.

`XMTPInvocationListener` filters incoming messages by content type, gates
schema versions, and routes valid invocations into `ConnectionsManager`.
Schema-version skew (incoming `schemaVersion` newer than the package
knows) replies with a synthetic `executionFailed` so the agent gets a
structured no rather than silence.

`ConvosConnectionsXMTP.codecs()` is a one-line registration helper for
the host's `ClientOptions(codecs: [...])` call.

The split exists so the device-data-source package stays free of any
XMTP dependency. A future host that wants to ship ConvosConnections over
a different transport (e.g. for tests, or a non-XMTP runtime) can do so
without forking.

### Discovery (today)

**Agents do not discover capabilities at runtime.** They have a priori
knowledge of action schemas via the convos-cli vendoring the same
domain types as TypeScript / Bun equivalents (or whatever native
representation the runtime uses).

The fallbacks for skew:
- Unknown action name → device replies with status `unknownAction`.
- Newer `schemaVersion` than the device knows → device replies with
  status `executionFailed` describing the version mismatch.
- Action exists but the user hasn't enabled the capability for this
  conversation → status `capabilityNotEnabled`.

For cloud connections, agents discover available services by reading
the `connections` field on the sender's member-profile metadata. This is
already a runtime discovery mechanism, just one specific to the cloud
subsystem.

The unified discovery surface — a `capability_request` /
`capability_request_result` content-type pair plus a runtime capabilities
manifest published on `ProfileUpdate` — is described in the
[Capability Resolution PRD](../plans/capability-resolution.md). It's
explicitly out of scope for this ADR.

## Consequences

### Positive

- **Subsystems evolve independently.** A new device sink doesn't affect
  cloud connections; a new Composio service doesn't affect device sinks.
- **Authorization stays close to the data.** Each iOS framework's quirks
  (foreground-only HealthKit, EventKit's full-vs-write-only access, etc.)
  are owned by the relevant `DataSource`/`DataSink` and don't leak into
  ConvosCore.
- **The XMTP package is the only place that knows about XMTP.** The
  device-data-source package can be shipped, tested, and reused outside
  the main app.
- **Forward-compat is explicit, not implicit.** `JSONValue` capture in
  `ConnectionPayloadBody.unknown` and `schemaVersion` gating in
  `ConnectionInvocation` mean older builds round-trip newer payloads
  without crashing or losing structure.
- **Naming, while overloaded, is intentional.** `ConvosConnections` is
  the device package; `Connections` (under ConvosCore) is the cloud
  subsystem. Cross-references through the
  [device-vs-cloud PRD](../plans/connections-device-vs-cloud.md).

### Negative

- **Two parallel surfaces.** Until the capability resolver lands, agent
  authors deal with two integration patterns: invocation messages for
  device data and member-profile inspection plus direct Composio calls
  for cloud data.
- **Schema discovery is a priori.** Agents must keep their schema
  knowledge in sync with the device build. The `unknownAction` fallback
  catches drift but doesn't help an agent know what *new* actions exist.
- **No central authorization story.** A user who wants to revoke "all
  agent access" has to walk through device permissions and Composio
  grants separately.
- **Two databases of record.** Cloud grants live in member-profile
  metadata (canonical) and GRDB (cache). Device enablements live only
  in the host's `EnablementStore` implementation — they don't sync
  across devices today.

### Neutral

- The naming collision with ADR 005's profile-metadata terminology
  ("connections" key on member profile) is something the
  capability-resolution work will need to revisit.
- ScreenTime requires App Store entitlement approval and ships behind
  its own library product so the rest of the package isn't blocked.

## Implementation Notes

**Module map**:

```
ConvosConnections/                       — Subsystem A, device data sources
  Sources/ConvosConnections/              — main library
  Sources/ConvosConnectionsScreenTime/    — Family Controls add-on
  Tests/ConvosConnectionsTests/
  Example/                                — designer/eng evaluation harness

ConvosCore/Sources/ConvosConnectionsXMTP/  — XMTP adapter for Subsystem A
ConvosCore/Tests/ConvosConnectionsXMTPTests/

ConvosCore/Sources/ConvosCore/CloudConnections/  — Subsystem B, cloud OAuth
ConvosCore/Sources/ConvosCore/Custom Content Types/CloudConnectionGrantRequestCodec.swift
```

**Wire format examples**:

A `connection_invocation` (agent → device, `convos.org/connection_invocation/1.0`):

```json
{
  "id": "...",
  "schemaVersion": 1,
  "invocationId": "agent-1-001",
  "kind": "calendar",
  "action": {
    "name": "create_event",
    "arguments": {
      "title":     {"type": "string",          "value": "Lunch with Sam"},
      "startDate": {"type": "iso8601",         "value": "2026-05-02T12:00:00-07:00"},
      "endDate":   {"type": "iso8601",         "value": "2026-05-02T13:00:00-07:00"},
      "timeZone":  {"type": "string",          "value": "America/Los_Angeles"}
    }
  },
  "issuedAt": "2026-04-28T18:00:00Z"
}
```

A `connection_invocation_result` (device → agent,
`convos.org/connection_invocation_result/1.0`):

```json
{
  "id": "...",
  "schemaVersion": 1,
  "invocationId": "agent-1-001",
  "kind": "calendar",
  "actionName": "create_event",
  "status": "success",
  "result": {
    "eventId":    {"type": "string", "value": "ABC123"},
    "calendarId": {"type": "string", "value": "..."}
  },
  "completedAt": "2026-04-28T18:00:01Z"
}
```

**Convos CLI integration** (the agent-runtime side):
- Vendor the canonical schema list (currently `CalendarActionSchemas.all`,
  `HealthActionSchemas.all`, etc.) as a versioned export.
- Send invocations as `connection_invocation` content-type messages with
  the matching `invocationId`.
- Subscribe to `connection_payload` (sensor reads) and
  `connection_invocation_result` (replies) content types.
- Read the `connections` field on the sender's member profile to
  enumerate cloud grants; route Composio-eligible tool calls
  agent-side, not over XMTP.
- Treat `unknownAction` and version-skew `executionFailed` as graceful
  no-ops, not retryable errors.

**Versioning posture**:
- Bump a `schemaVersion` on a payload type when adding required fields
  or changing semantics.
- Add new optional fields freely without a version bump; older readers
  ignore them.
- Add new `ConnectionPayloadBody` cases freely; older readers fall
  through to `.unknown(rawType, JSONValue)` and drop the body.
- Add new action names freely; older devices reply `unknownAction`.

## Related Decisions

- [ADR 005 — Member Profile System](./005-member-profile-system.md):
  cloud grants ride on member-profile metadata; the same machinery
  publishes them across the conversation.
- [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md):
  defines the `senderId` an agent uses to address an invocation back
  to a specific user.

## References

- PRDs in this repo:
  - [`docs/plans/connections-device-vs-cloud.md`](../plans/connections-device-vs-cloud.md)
  - [`docs/plans/connections-write-capabilities.md`](../plans/connections-write-capabilities.md)
  - [`docs/plans/connections-xmtp-adapter.md`](../plans/connections-xmtp-adapter.md)
  - [`docs/plans/capability-resolution.md`](../plans/capability-resolution.md)
- PR landing the device subsystem and XMTP adapter:
  [xmtplabs/convos-ios#767](https://github.com/xmtplabs/convos-ios/pull/767)
- PR landing the cloud subsystem:
  [xmtplabs/convos-ios#719](https://github.com/xmtplabs/convos-ios/pull/719)
- CLI integration for the device subsystem:
  [xmtplabs/convos-cli#35](https://github.com/xmtplabs/convos-cli/pull/35)
