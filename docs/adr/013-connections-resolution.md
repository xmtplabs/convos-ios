# ADR 013: Connections — Resolution and Picker

> **Status**: Accepted (2026-05-04).
> **Related**: [ADR 005 — Member Profile System](./005-member-profile-system.md)
> (the capability manifest rides on member-profile metadata),
> [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md)
> (the manifest is published on each sender's own `ProfileUpdate`),
> [ADR 012 — Connections Architecture](./012-connections-architecture.md)
> (the two subsystems this ADR unifies).
> **PRDs**:
> [`docs/plans/capability-resolution.md`](../plans/capability-resolution.md),
> [`docs/plans/capability-resolution-flows.md`](../plans/capability-resolution-flows.md),
> [`docs/plans/connections-v1-prd.md`](../plans/connections-v1-prd.md).

## Context

[ADR 012](./012-connections-architecture.md) shipped two parallel "Connections"
subsystems:

1. `ConvosConnections` — device data sources (HealthKit, EventKit, Photos, …)
   exchanged with agents via `ConnectionInvocation` /
   `ConnectionInvocationResult` content types.
2. `CloudConnections` (in ConvosCore) — Composio-brokered OAuth services
   (Google Calendar, Slack, …) where grants ride on member-profile metadata
   and agents call Composio directly.

ADR 012 explicitly deferred unification to "the planned capability resolver."
That deferral cost the agent runtime two integration patterns (invocation
messages for device, profile inspection plus direct Composio calls for cloud)
and gave users no single answer to "which provider does this conversation use
for my calendar?" when both a device sink and a cloud OAuth account were
linked. It also left the picker UX with no shared vocabulary for "I want to
read fitness data" when fitness can be served by Apple Health, Strava, and
Fitbit simultaneously.

The capability resolver fronts both subsystems behind a single agent-facing
surface (one wire type pair, one routing table, one manifest), without
collapsing them into one runtime. Each subsystem keeps its own execution
path; the resolver only decides *which* path applies for *which* verb in
*which* conversation.

## Decision Drivers

- [x] Single agent contract — one `capability_request` /
      `capability_request_result` pair regardless of whether the answer is
      "Apple Calendar (device)" or "Google Calendar (cloud)".
- [x] Federated reads where it makes sense — fitness data legitimately spans
      Apple Health + Strava simultaneously; calendar reads do not.
- [x] Per-conversation routing — the user's choice of "use Google Calendar in
      this convo, Apple Calendar in that one" is the unit of grant, not a
      global app setting.
- [x] Forward compatibility — the wire types must round-trip across iOS / CLI
      / agent-runtime version skew without a lockstep deploy. `ProviderID`
      values and `CapabilitySubject` cases must be additive only.
- [x] No regression for device-only or cloud-only flows — adding the resolver
      must not require either subsystem to know about the other.
- [x] UX legibility — the picker variant a user sees should match the shape
      of the decision. Confirm-only when there's exactly one linked option;
      multi-select when federation is allowed and multiple linked options
      exist; verb-shortcut when an earlier verb's resolution determines the
      answer.

## Decision

We add a thin coordination layer to ConvosCore that owns four responsibilities
and nothing else:

1. A taxonomy (`CapabilitySubject`) and a flat provider-identity space
   (`ProviderID`) shared across both subsystems.
2. A registry (`CapabilityProviderRegistry`) of currently usable providers,
   populated by each subsystem at session bootstrap and on link/unlink.
3. A resolver (`CapabilityResolver`, GRDB-backed in production) that maps
   `(subject, conversationId, capability) → Set<ProviderID>`.
4. Two wire types (`capability_request` / `capability_request_result`) and a
   manifest payload (`CapabilityManifest`) so agents can ask, the user can
   answer, and the agent can read the resulting routing table.

The resolver does *not* execute anything. Device invocations still flow
through `ConvosConnections`; cloud calls still go agent-side via Composio.
The resolver only persists the user's per-conversation choice and routes the
device side through `CapabilityInvocationRouter`.

### Subjects, providers, and identifiers

`CapabilitySubject` is a flat enum the user understands (`.calendar`,
`.contacts`, `.tasks`, `.mail`, `.photos`, `.fitness`, `.music`, `.location`,
`.home`, `.screenTime`). It is deliberately separate from `ConnectionKind`:

- Not every subject has a device counterpart (`.tasks`, `.mail`).
- Not every `ConnectionKind` is a user-facing subject (`.motion` is a sensor
  primitive, not something to "grant access to").

Each subject carries an `allowsReadFederation: Bool`. **Reads** federate when
this flag is `true` (the picker can render multi-select; the manifest can mark
multiple providers `resolved["read"] == true` simultaneously). **Writes never
federate**, regardless of the subject's flag — write resolutions are always
size 1. Today only `.fitness` opts in. Defaulting to `false` means flipping a
subject on later is a non-breaking expansion; the reverse would be breaking.

`ProviderID` is an opaque, dotted-string identifier (`device.calendar`,
`composio.google_calendar`). The resolver routes by lookup against the
registry, never by parsing the prefix. Two helpers exist for the rare cases
where the *namespace* matters (cloud bootstrap, device-vs-cloud routing in
`CapabilityInvocationRouter`):

- `ProviderID.cloudServiceId` — strips `composio.` and returns the rest, or
  `nil` for non-cloud ids.
- `ConnectionKind.fromDeviceProviderId(_:)` — the inverse for `device.<kind>`.

### `CapabilityProvider` protocol and adapters

`CapabilityProvider` is the subsystem-neutral protocol the registry stores.
Each provider declares `id`, `subject`, `displayName`, `iconName`,
`capabilities: Set<ConnectionCapability>`, plus async `linkedByUser` and
`available` — and an optional `subjectNounPhrase` for picker copy ("read your
*health data*" instead of "read your *fitness*").

Two adapters bridge the existing subsystems:

- **`DeviceCapabilityProvider`** — wraps a `ConnectionKind` exposed by
  `ConvosConnections`. Closure-based `linkedByUser` / `available` so the
  host can poll the actual iOS framework permission (HealthKit auth, EventKit
  status, etc.) without dragging UIKit into the resolver. A static
  `defaultSpecs` table covers every routable kind.
- **`CloudCapabilityProvider`** — built from a `CloudConnection` row.
  `linkedSnapshot` reflects `CloudConnection.status == .active` at
  construction; the bootstrap helper re-registers (or unregisters) on grant
  rotation so the registry always carries a fresh provider rather than asking
  the provider itself to be reactive.

`SupportedConnections` is an explicit allowlist (`supportedDeviceKinds`,
`supportedCloudServiceIds`) used by both the picker registry bootstrap and
the in-app connections list. Adding an entry is a non-breaking expansion;
removing one hides a previously-shown option, so rollouts stay intentional.

### `CapabilityProviderRegistry`

`CapabilityProviderRegistry` is an in-memory actor populated by
`CapabilityProviderBootstrap`:

- `registerDeviceProviders` — walks the spec table, builds providers with
  the host-supplied permission closures, registers each. Idempotent.
- `syncCloudProviders` — diffs the current `CloudConnection` set against the
  registry, registering new ones, refreshing existing ones, unregistering
  vanished ones. Called on every cloud-side state change. A `seedServiceIds`
  parameter inserts placeholder providers (`linked: false`) so the picker can
  still surface `connectAndApprove` rows for services the user *could* link.

The registry exposes `providerChanges: AsyncStream<ProviderChange>`
(`.added` / `.removed` / `.linkedStateChanged`) so picker / confirmation card
UIs can refresh in place when a user taps "Connect another" mid-display and
returns from OAuth.

### `CapabilityResolver`

`CapabilityResolver` is a protocol; production uses `GRDBCapabilityResolver`
backed by the `capabilityResolution` table:

```
(subject, conversationId, capability) → providerIds (delimiter-separated)
PRIMARY KEY (subject, conversationId, capability)
ON DELETE CASCADE from conversation
```

The set's allowed cardinality follows the federation × verb matrix:

| `allowsReadFederation` | verb     | size  |
|------------------------|----------|-------|
| `false`                | `.read`  | 1     |
| `false`                | writes   | 1     |
| `true`                 | `.read`  | ≥ 1   |
| `true`                 | writes   | 1     |

Cardinality is enforced by `CapabilityResolutionValidator.validate(...)`,
called from both the in-memory and GRDB resolvers (and any future wire-decode
path). The schema accepts any non-empty set so single and multi-provider
rows live in the same table without a discriminator.

`InMemoryCapabilityResolver` mirrors the same surface for tests and bring-up.

### Wire types

Two new content types:

| Codec                          | Direction        | Content type                                  |
|--------------------------------|------------------|-----------------------------------------------|
| `CapabilityRequestCodec`       | agent → user     | `convos.org/capability_request/1.0`           |
| `CapabilityRequestResultCodec` | user → agent     | `convos.org/capability_request_result/1.0`    |

Both encode their `Codable` Swift type as JSON (consistent with the
`ConnectionInvocation` codecs from ADR 012). Both reject decode of a higher
`version` than they understand, and `CapabilityRequest` truncates `rationale`
to 500 chars and `preferredProviders` to 16 entries on decode so a hostile
sender can't bloat the picker card.

`CapabilityRequest` carries a `requestId` (correlation), `subject`,
`capability`, `rationale`, and an optional ordered `preferredProviders`
hint. `CapabilityRequestResult` always replies — `.approved` / `.denied` /
`.cancelled` — so the agent can correlate by `requestId` and stop waiting.
The reply's `providers` field carries *what was actually persisted*, not what
the agent asked for, so an agent that supplied a hint can detect whether it
was honored.

### `CapabilityRequestHandler` and picker variants

`CapabilityRequestHandler` is a stateless orchestrator:

- `computeLayout(request, registry, resolver, conversationId) → CapabilityPickerLayout`
- `commit(request, approvedProviderIds, resolver, conversationId)` — only
  call that mutates resolver state.
- `deny(request)` / `cancel(request)` — produce reply envelopes without
  mutating state.

The handler picks one of five `CapabilityPickerLayout.Variant`s based on the
linked-provider count and the federation × verb shape:

- **Variant 1 — `.confirm`** — exactly one linked provider, default-approve
  card with "Use a different one?" disclosure.
- **Variant 2a — `.singleSelect`** — multiple linked providers, single-
  select; renders for any write verb or read on a non-federating subject.
- **Variant 2b — `.multiSelect`** — multiple linked providers, multi-select;
  only renders for read on a federating subject.
- **Variant 3 — `.connectAndApprove`** — zero linked providers; the card
  doubles as a "Connect a calendar" entry point with one row per known
  provider option.
- **`.verbConsent`** — same subject already has a resolution for some other
  verb; the new verb defaults to those providers and the card is a "Allow
  Apple Calendar to *write events*?" consent (no picker).

`preferredProviders` from the agent is honored only when every preferred id
is in the linked set; otherwise the picker falls through to its normal
default. Preferences never override federation rules — a write verb is
single-select even if the agent asks for two providers.

### `CapabilityInvocationRouter`

`ConnectionInvocation`s arriving from agents now flow through
`CapabilityInvocationRouter` rather than being executed directly by
`ConnectionsManager`. The router consults the resolver:

- No subject mapping for the kind → `unknownAction`.
- No capability declared for the action → `unknownAction`.
- Empty resolution for `(subject, capability, conversationId)` →
  `capabilityNotEnabled` (the agent should send a `capability_request`
  first).
- Resolution contains the device's `device.<kind>` provider → device
  dispatches and returns its slice.
- Resolution exists but contains only cloud providers →
  `executionFailed` with a message telling the agent to call those provider
  APIs directly. Cloud federation is the agent's concern, not the device's.

This is the only place where the device subsystem becomes resolution-aware.
`ConvosConnections` itself stays oblivious to subjects, registries, and
resolutions.

### `CapabilityManifest`

After a resolution changes — or a provider's link state flips — the
`CapabilityManifestBuilder` snapshots `(registry, resolver, conversationId)`
into a `CapabilityManifest`, which the host writes to
`profile.metadata["connections"]` on the next `ProfileUpdate`. Each entry
carries `id`, `subject`, `displayName`, `available`, `linked`, the verbs the
provider supports, and a `resolved: [verb: Bool]` map for this conversation.

Provider lists are sorted alphabetically by `id.rawValue` so equivalent state
produces byte-identical JSON, avoiding spurious `ProfileUpdate` writes.

This replaces the cloud-only `connections` payload from ADR 012 with a
unified shape that carries both device and cloud entries. Older readers that
expected the cloud-only shape ignore device entries (they're additive).

### `ConnectionEventSummary` actor channel

System messages for grant / revoke / invocation events use the existing
`connectionEvent` content type but with a typed `ConnectionEventSummary.Actor`
field:

- `.verifiedAssistant` — the conversation's verified-Convos assistant; the
  renderer prepends the assistant's display name.
- `.messageSender` — the message's sender; the renderer resolves via
  `msg.sender`.
- `nil` — render `text` verbatim (backward-compatible path for older rows
  written before the actor field existed).

Carrying the actor as a typed enum rather than baking the name into `text`
means the renderer can show the right name even when the agent's display
name changed mid-conversation, and avoids string-prefix substitution that
broke when verified-assistant attribution moved off "Assistant".

### DEBUG-only attestation override

A separate concern that lands in this PR but is structurally orthogonal.
Verifying an agent as a Convos assistant requires Ed25519 signature
verification against the Railway-hosted JWKS endpoint, whose private key
isn't accessible locally. To enable end-to-end testing of verified-assistant
flows in DEBUG builds:

- A locally-minted Ed25519 keypair lives at `~/.convos-debug-attest.pem`.
- The matching JWKS is pinned in the shared `.env` as `AGENT_DEBUG_JWKS`
  and materialized by the build phase into `Secrets.AGENT_DEBUG_JWKS`.
- `DebugAgentKeysetOverride.parse(_:)` decodes the JWKS at app launch.
- `AgentKeyset(endpointURL:fallbackKey:)` accepts an optional fallback key,
  caches it on init for synchronous lookups, and consults it in `resolveKey`
  whenever the live endpoint has no entry for the requested `kid`.

The fallback path is `#if DEBUG`-gated in `ConvosApp`. Production builds set
`fallbackKey: nil` and behave exactly as before. The CLI side ships a
`--attestation-private-key <path>` flag that signs `sha256(inboxId || ts)`
at session start using the matching private key.

## Consequences

### Positive

- **One agent contract.** A `capability_request` carries the same shape
  whether it eventually resolves to `device.calendar` or
  `composio.google_calendar`. The reply is the same. The on-the-wire
  manifest is the same.
- **Per-conversation routing is durable.** GRDB persistence means a user's
  "use Google here, Apple there" choice survives restart and migrations,
  enforced by the same validator everywhere.
- **Federation is a property of the subject, not a per-call decision.**
  Adding `.fitness` to the federating set was a one-line change; adding
  another federating subject is the same. Writes can never accidentally
  federate because the validator says so.
- **Picker UX matches the shape of the decision.** Five variants cover
  zero-linked, one-linked, many-linked × single-select, many-linked ×
  multi-select, and "you already answered for the other verb." The handler
  picks; the view renders.
- **Subsystems still own their data.** `ConvosConnections` doesn't know
  what a subject is; `CloudConnections` doesn't know how to talk to
  HealthKit. The resolver is the only thing that knows about both.
- **Manifest produces byte-stable output.** Sorted entries +
  alphabetized capability lists mean `ProfileUpdate` republishes only
  fire when something actually changed.
- **Verified-assistant attribution is a typed channel.** Renderers no
  longer parse `text.hasPrefix("Assistant ")` — the `Actor` enum says
  what to substitute and the renderer picks the name.

### Negative

- **Two databases of record (still).** Cloud grants persist on the member
  profile (canonical, sync via XMTP) *and* the resolver row persists on the
  device only (no cross-device sync today). A user who linked Google
  Calendar on iPhone and switches to iPad sees the link but not the
  per-conversation routing — they'll re-pick on first request.
- **`ProviderID` is opaque-by-convention.** Two helpers parse the namespace
  prefix. A future third subsystem (e.g. an app-extension provider)
  would either have to claim its own prefix or extend those helpers.
- **`SupportedConnections` is a static allowlist.** Adding a provider
  requires an iOS deploy. A server-driven allowlist is plausible but not
  shipped — the deploy gate is a conscious staging tool right now.
- **Manifest skew is recoverable but not invisible.** An agent reading a
  newer manifest entry (extra fields, unknown verbs) gracefully ignores
  the unknown bits, but the resolver wire types reject newer `version`
  values outright — too risky to silently accept since the picker UX
  depends on the contract.
- **DEBUG attestation override is one more knob.** Production builds set
  `fallbackKey: nil` so it's inert, but engineers debugging a
  verification failure still have to reason about whether `Secrets.AGENT_DEBUG_JWKS`
  was correctly baked into the binary on a clean rebuild.

### Neutral

- The resolver intentionally has no "default provider" concept. A user with
  exactly one linked option still gets a one-tap confirm card; a user with
  zero linked options gets `connectAndApprove`. Everything else is an
  explicit choice.
- `CapabilityRequestResult.availableActions` is currently always empty —
  reserved for a future round where we publish concrete action schemas
  alongside the approval. The shape is in the wire type so we don't bump
  a version when we start populating it.

## Implementation Notes

**Module map**:

```
ConvosCore/Sources/ConvosCore/CapabilityResolution/
  CapabilitySubject.swift              — taxonomy + federation flag
  ProviderID.swift                     — opaque dotted-string id
  CapabilityProvider.swift             — provider protocol + ProviderChange
  CapabilityProviderRegistry.swift     — actor + AsyncStream<ProviderChange>
  CapabilityProviderBootstrap.swift    — registerDeviceProviders / syncCloudProviders
  DeviceCapabilityProvider.swift       — ConvosConnections adapter + defaultSpecs
  CloudCapabilityProvider.swift        — CloudConnection adapter + service maps
  SupportedConnections.swift           — picker allowlist
  CapabilityResolver.swift             — protocol + InMemoryCapabilityResolver
  GRDBCapabilityResolver.swift         — production impl
  CapabilityResolution.swift           — value type + Validator
  CapabilityResolutionsRepository.swift— Combine publisher / read-side
  CapabilityRequest.swift              — wire type, agent → user
  CapabilityRequestResult.swift        — wire type, user → agent
  CapabilityRequestHandler.swift       — picker variant + commit/deny/cancel
  CapabilityRequestRepository.swift    — outstanding-requests inbox
  CapabilityRequestResultWriter.swift  — sends result envelope
  CapabilityPickerLayout.swift         — view-model snapshot
  CapabilityManifest.swift             — wire shape on member-profile metadata
  CapabilityManifestBuilder.swift      — snapshots registry + resolver
  CapabilityInvocationRouter.swift     — gates ConnectionInvocation by resolution
  DeviceConnectionAuthorizer.swift     — host adapter for iOS framework status

ConvosCore/Sources/ConvosCore/Custom Content Types/
  CapabilityRequestCodec.swift
  CapabilityRequestResultCodec.swift

ConvosCore/Sources/ConvosCore/Storage/
  SharedDatabaseMigrator.swift         — createCapabilityResolution migration

Convos/Capabilities/
  CapabilityPickerCardView.swift       — renders all 5 variants
  CapabilityApprovedToastView.swift    — post-commit affordance
```

**Wire format examples**:

A `capability_request` (agent → user, `convos.org/capability_request/1.0`):

```json
{
  "version": 1,
  "requestId": "req-abc-123",
  "subject": "calendar",
  "capability": "read",
  "rationale": "Help plan your trip itinerary.",
  "preferredProviders": ["composio.google_calendar"]
}
```

A `capability_request_result` (user → agent,
`convos.org/capability_request_result/1.0`):

```json
{
  "version": 1,
  "requestId": "req-abc-123",
  "status": "approved",
  "subject": "calendar",
  "capability": "read",
  "providers": ["composio.google_calendar"],
  "availableActions": []
}
```

A `connections` manifest entry on member-profile metadata:

```json
{
  "version": 1,
  "providers": [
    {
      "id": "composio.google_calendar",
      "subject": "calendar",
      "displayName": "Google Calendar",
      "available": true,
      "linked": true,
      "capabilities": ["read", "write_create", "write_update", "write_delete"],
      "resolved": { "read": true }
    },
    {
      "id": "device.calendar",
      "subject": "calendar",
      "displayName": "Apple Calendar",
      "available": true,
      "linked": true,
      "capabilities": ["read", "write_create", "write_update", "write_delete"],
      "resolved": { "read": false }
    }
  ]
}
```

**Migration ordering**:

`createCapabilityResolution` runs before `createConnectionEnablement` (the
device-side enablement table) so the resolver can be the canonical surface
from a fresh install. Existing rows in older `connectionEnablement` /
cloud-grant tables remain — they're the device subsystem's per-source
enablement and the cloud OAuth grant store, both of which the resolver reads
via `linkedByUser` rather than supplanting.

**CLI integration** (the agent-runtime side):

- Send `capability_request` with subject + capability + rationale; subscribe
  to `capability_request_result` to learn the answer.
- Read the `connections` field on the sender's member profile to enumerate
  the routing table — the manifest tells you which provider serves which
  verb in this conversation.
- For federating reads, expect multiple providers with `resolved["read"] ==
  true` and merge results agent-side.
- For writes, expect exactly one provider; if you see more, validate or
  treat as a bug.

**Versioning posture**:

- `CapabilitySubject` cases are additive only. Older readers that don't
  recognize a new case skip the corresponding manifest entry (forward-
  compat through `Codable`'s case-decoding rules).
- `ProviderID` values are opaque strings; new namespaces are additive.
- Wire-type `version` bumps are reserved for breaking changes
  (semantics shift, required-field rename); decoders reject newer `version`
  to fail loudly rather than silently dropping a field.
- New optional fields on existing wire types do *not* bump the version.

## Related Decisions

- [ADR 005 — Member Profile System](./005-member-profile-system.md): the
  `connections` manifest is one of the per-conversation profile metadata
  payloads.
- [ADR 011 — Single-Inbox Identity Model](./011-single-inbox-identity-model.md):
  the manifest is published on each sender's own `ProfileUpdate`, addressed
  by their single XMTP inbox.
- [ADR 012 — Connections Architecture](./012-connections-architecture.md):
  the two subsystems this resolver fronts, including the device-side
  `ConnectionInvocation` plumbing that `CapabilityInvocationRouter` now
  gates.

## References

- PRDs in this repo:
  - [`docs/plans/capability-resolution.md`](../plans/capability-resolution.md)
  - [`docs/plans/capability-resolution-flows.md`](../plans/capability-resolution-flows.md)
  - [`docs/plans/connections-v1-prd.md`](../plans/connections-v1-prd.md)
- PR landing the resolver, picker, manifest, router, and DEBUG attestation
  override: [xmtplabs/convos-ios#771](https://github.com/xmtplabs/convos-ios/pull/771)
- Earlier subsystem PRs that this one unifies:
  device subsystem [#767](https://github.com/xmtplabs/convos-ios/pull/767),
  cloud subsystem [#719](https://github.com/xmtplabs/convos-ios/pull/719).
