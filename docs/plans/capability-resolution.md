# Capability Resolution — Subject / Provider Model

**Status**: Redesign in progress (single-provider model)
**Owner**: @yewreeka
**Depends on**: [`connections-device-vs-cloud.md`](./connections-device-vs-cloud.md)
**Blocks**: `capability_request` content type, ConvosConnections main-app integration, any cross-provider agent tool call

## Problem

Convos has (or will have) two parallel systems that let agents access user resources:

- **ConvosConnections** — native iOS APIs (Calendar via EventKit, Contacts via CNContactStore, Photos via PhotoKit, …)
- **CloudConnections** — OAuth-linked services (Google Calendar, Google Drive, … via Composio in v1)

A single agent intent like "I'd like to access your calendar" can map to either one, both, or neither. Today neither system knows about the other. The client has no principled way to decide which one to use when an agent requests a capability.

This PRD defines how the client resolves agent capability requests to concrete providers, how it presents the choice to the user, how it persists the resolution, and how later agent tool calls route to the right execution path.

## v1 scope cut: federation is opt-in, per subject

Earlier drafts let *every* subject's reads federate across all linked providers. The previous draft swung to "single provider per `(subject, conversation)`, no federation, period." Both extremes are wrong for the same reason — federation is the right answer for some subjects (fitness, where Strava + Fitbit + Apple Health summed across a week is exactly what the agent needs) and the wrong answer for others (calendar, where "which calendar did this event land on?" is a trust-breaking failure mode).

The v1 model lets each subject opt in:

- Each `CapabilitySubject` declares `allowsReadFederation: Bool`.
- For subjects with **`allowsReadFederation == false`** (calendar, contacts, photos, music, location, home, screen_time): a conversation resolves the subject to **exactly one provider**, for every capability verb. Variant 2 picker is single-select.
- For subjects with **`allowsReadFederation == true`** (fitness, plus anything else where summing across providers is the natural read): reads can resolve to a *set* of providers; writes (when the verb supports them) still resolve to exactly one. Variant 2 picker is multi-select for the read flow, single-select for write flows.
- Confirmation card (Variant 1) and connect-and-approve (Variant 3) flows are unchanged — they only render when there's 0 or 1 linked provider, where federation is moot.

Subjects that never make sense to federate (single-provider device-only — `.location`, `.screen_time`) just keep the flag false and skip the multi-select code path entirely.

| Subject | `allowsReadFederation` |
|---|---|
| `calendar` | false |
| `contacts` | false |
| `photos` | false |
| `music` | false |
| `home` | false |
| `mail` | false |
| `tasks` | false |
| `location` | false |
| `screen_time` | false |
| `fitness` | **true** |

The list is conservative on purpose: defaulting a new subject to single-provider matches the safer behavior. We can flip more to true as use cases emerge.

## Non-Goals

- Re-unifying device and cloud connections under a single `DataSource`/`DataSink` abstraction. The [comparison doc](./connections-device-vs-cloud.md) already argued against that.
- Per-verb federation. Reads federate (when the subject opts in); writes always target exactly one provider. The asymmetry is intentional — see the [appendix](#appendix-why-a-single-provider-per-subject-for-v1).
- Per-verb provider differences within a non-federating subject (e.g. read from Apple Calendar, write to Google Calendar in the same conversation). Same `(subject, conversation)` resolution covers all verbs.
- Runtime / backend *implementation* — this PRD defines the `profile.metadata["capabilities"]` contract the runtime reads, but the runtime-side reader is someone else's PR.
- Provider *discovery* — what providers to offer. That's a product decision we make per-subject; this PRD is about routing once providers exist.
- Cross-user federation. A resolution is always scoped to one user's account + one conversation.
- Cross-device sync of resolutions. Per-device for v1; tracked alongside the broader enablement-sync design.

## Core concepts

### Subject

What an agent is asking for. Stable, user-facing, provider-independent.

| Subject | Example providers | Notes |
|---|---|---|
| `calendar` | Apple Calendar (device), Google Calendar, Outlook | Reads events, writes events |
| `contacts` | Apple Contacts (device), Google Contacts | Reads address book, writes contacts |
| `tasks` | Apple Reminders, Google Tasks, Todoist | v2 |
| `mail` | — (Apple Mail has no agent-accessible API) | v2 |
| `photos` | Apple Photos (device), Google Photos | v2 |
| `fitness` | Apple Health (device), Strava, Fitbit | — |
| `music` | Apple Music (device), Spotify | — |
| `location` | Device location only | Only one provider realistically |
| `home` | HomeKit (device), Home Assistant | — |
| `screen_time` | Apple Screen Time (device) | Only one provider |

Subjects are a flat enum in Swift with room to grow. Not tied to the existing `ConnectionKind` enum — `ConnectionKind` continues to describe device-side providers only.

### Provider

A concrete way to fulfill a subject. Provider IDs are dotted strings:

```
device.calendar
device.contacts
device.photos
device.health
...
composio.google_calendar
composio.google_drive
composio.microsoft_outlook
...
```

One user can have N providers linked for a subject. Provider registration is the responsibility of each underlying system — `ConvosConnections` registers device providers at startup, the cloud-connections subsystem registers OAuth providers as users link services.

### Resolution

A persistent decision binding `(subject, conversationId, capability)` to one or more providers:

```
(subject: .calendar, conv: "abc", capability: .read)         -> {ProviderID("device.calendar")}
(subject: .calendar, conv: "abc", capability: .writeCreate)  -> {ProviderID("device.calendar")}
(subject: .fitness, conv: "abc", capability: .read)          -> {ProviderID("composio.strava"),
                                                                  ProviderID("composio.fitbit")}
(subject: .fitness, conv: "abc", capability: .writeCreate)   -> {ProviderID("composio.strava")}
```

The set's allowed cardinality depends on the subject's federation flag and the verb shape:

| Subject's `allowsReadFederation` | Capability verb | Allowed set size |
|---|---|---|
| `false` | `.read` | exactly 1 |
| `false` | `.writeCreate` / `.writeUpdate` / `.writeDelete` | exactly 1 |
| `true` | `.read` | ≥ 1 |
| `true` | `.writeCreate` / `.writeUpdate` / `.writeDelete` | exactly 1 (writes never federate) |

For non-federating subjects, all verbs default to the same provider — the resolution for the *first* approved verb seeds subsequent verb prompts (the verb-only consent card defaults to that provider; the user can still escape to the picker to switch).

For federating subjects, `.read` and the write verbs are independent: read can be `{Strava, Fitbit}` while `.writeCreate` is `{Strava}`. Each verb gets its own picker the first time it's requested.

Absence of a resolution row means "ask the user the next time this verb is invoked."

### Resolver

The coordinator that sits between incoming `capability_request` / `ConnectionInvocation` messages and the two underlying systems. Lives in ConvosCore (not in either package):

```swift
public protocol CapabilityResolver: Sendable {
    /// All providers currently registered for this subject, regardless of whether the user
    /// has linked them.
    func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider]

    /// What the user picked previously for this (subject, conversation, capability). Empty
    /// set means they've never been asked.
    func resolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async -> Set<ProviderID>

    /// User has just approved the picker / confirmation card. The resolver validates the
    /// set against the subject's federation flag and the verb shape (see the table in
    /// [Resolution](#resolution)) and throws if the set is inconsistent.
    func setResolution(
        _ providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws

    /// Clear a resolution for a specific verb (e.g. user revokes write access in
    /// Conversation Info but keeps reads enabled).
    func clearResolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws

    /// Clear every resolution for a subject in a conversation (user toggled the subject off
    /// entirely from Conversation Info).
    func clearAllResolutions(
        subject: CapabilitySubject,
        conversationId: String
    ) async throws
}
```

### Verb-only consent shortcut

When the agent requests a new verb the user hasn't granted yet, but a resolution already exists for *another* verb on the same `(subject, conversation)`, the resolver can default the new verb's resolution to the same provider(s):

- **Non-federating subject** (e.g. `.calendar`): existing read resolution is `{device.calendar}`. New `.writeCreate` request defaults to the same single provider — verb-only consent card "Allow Apple Calendar to write events?" — no picker, no choice. User can still escape to the picker if they want a different provider for writes (which v1 doesn't support, so the picker would be no-op; v2 lifts the same-provider constraint).
- **Federating subject** (e.g. `.fitness`): existing `.read` resolution is `{Strava, Fitbit}`. New `.writeCreate` request *cannot* federate (writes are always single-provider) — so the picker surfaces with both linked providers as options, defaulting to whichever has higher capability priority (TBD; for v1, the most-recently-resolved one).

The result is that the second-verb consent stays cheap when the answer is obvious, and falls back to the picker when there's actual ambiguity.

### Provider registry

A runtime in-memory registry the resolver reads from. Both bodies of work populate it:

```swift
public struct ProviderID: Hashable, Sendable, Codable {
    public let rawValue: String  // "device.calendar" | "composio.google_calendar"
}

public enum CapabilitySubject: String, Hashable, Sendable, Codable, CaseIterable {
    case calendar, contacts, tasks, mail, photos, fitness, music, location, home, screenTime
}

public protocol CapabilityProvider: Sendable {
    var id: ProviderID { get }
    var subject: CapabilitySubject { get }
    var displayName: String { get }         // "Apple Calendar", "Google Calendar"
    var iconName: String { get }            // SF Symbol name for the picker / confirmation card
    var capabilities: Set<ConnectionCapability> { get }  // which verbs this provider supports
    var linkedByUser: Bool { get async }    // does user have credentials for this?
}

public enum ProviderChange: Sendable {
    case added(ProviderID)
    case removed(ProviderID)
    case linkedStateChanged(ProviderID)  // OAuth linked/unlinked, iOS permission granted/denied
}

public protocol CapabilityProviderRegistry: Sendable {
    func register(_ provider: any CapabilityProvider) async
    func unregister(id: ProviderID) async
    func providers(for subject: CapabilitySubject) async -> [any CapabilityProvider]
    func provider(id: ProviderID) async -> (any CapabilityProvider)?

    /// Observable stream of provider-registry changes. The picker / confirmation card UI
    /// subscribes so it can refresh in place when the user taps "Connect another"
    /// mid-display and completes an OAuth flow or a device permission grant.
    var providerChanges: AsyncStream<ProviderChange> { get }
}
```

`ConvosConnections` registers one provider per `ConnectionKind` at manager init. The cloud-connections subsystem registers one provider per OAuth connection on link + removes on unlink.

## UX flow

### First time: agent requests a capability

Agent posts a `capability_request(subject: .calendar, capability: .read, rationale: "To summarize your week")` to the conversation. Client looks up linked providers for `.calendar` and routes to one of three card variants:

#### Variant 1 — exactly one linked provider (the common case)

```
┌─ Assistant wants to read your calendar ──────────┐
│ "To summarize your week"                         │
│                                                  │
│  📅  Apple Calendar                              │
│                                                  │
│  Use a different calendar?  ⌄                    │
│                                                  │
│  [ Approve ]  [ Deny ]                           │
└──────────────────────────────────────────────────┘
```

Default-approve flow: tapping **Approve** stores the resolution `(calendar, conversationId) -> device.calendar` and grants `.read`. The "Use a different calendar?" disclosure expands into Variant 2 with the current pick already selected.

#### Variant 2a — multiple linked providers, non-federating subject or write verb (single-select)

```
┌─ Assistant wants to read your calendar ──────────┐
│ "To summarize your week"                         │
│                                                  │
│  ⦿ Apple Calendar                                │
│  ○ Google Calendar                               │
│  ○ Microsoft Outlook  (tap to connect)           │
│                                                  │
│  [ Approve ]  [ Deny ]                           │
└──────────────────────────────────────────────────┘
```

Radio buttons. `[ Approve ]` stays enabled when one row is checked.

#### Variant 2b — multiple linked providers, federating subject + read verb (multi-select)

```
┌─ Assistant wants to read your fitness data ─────┐
│ "To summarize your training week"                │
│                                                  │
│  ☑ Strava                                        │
│  ☑ Fitbit                                        │
│  ☐ Apple Health  (tap to connect)                │
│                                                  │
│  [ Approve ]  [ Deny ]                           │
└──────────────────────────────────────────────────┘
```

Checkboxes. `[ Approve ]` stays enabled when at least one row is checked. The picker only renders this variant when (a) the subject's `allowsReadFederation == true` AND (b) the requested capability is `.read`. Any write verb on a federating subject falls back to Variant 2a (single-select).

#### Variant 3 — zero linked providers (connect-and-approve)

```
┌─ Assistant wants to read your calendar ──────────┐
│ "To summarize your week"                         │
│                                                  │
│  Connect one to continue:                        │
│                                                  │
│  📅  Apple Calendar    [ Connect ]               │
│  📅  Google Calendar   [ Connect ]               │
│                                                  │
│  [ Deny ]                                        │
└──────────────────────────────────────────────────┘
```

Tapping **Connect** kicks off the iOS permission flow (device) or the OAuth flow (cloud). On completion the registry emits a `linkedStateChanged` event, the card moves to Variant 1 or 2 depending on the resulting count, and the user proceeds to Approve.

### Approval handling

User approves → resolver writes the resolution row → device or cloud subsystem flips its underlying enablement/grant for each provider in the set → client publishes an updated [capabilities manifest](#runtime-capabilities-manifest) on the next `ProfileUpdate` → client posts a `capability_request_result(status: .approved, providers: [...])` reply to the conversation. The reply carries the full set of providers (single-element for non-federating subjects and write verbs, ≥ 1 for federating-subject reads).

### Agent-provided provider hint (`preferredProviders`)

If the `CapabilityRequest` carries a non-empty `preferredProviders`:

1. Filter to the subset that's linked and supports the requested capability.
2. If the filtered subset is non-empty AND its arity matches the verb shape (any size for read on federating subject; size 1 for everything else) → render Variant 1 (size 1) or Variant 2b with rows pre-checked (size > 1 on federating subject) defaulting to that selection.
3. Otherwise → fall through to whichever variant the user's link-state warrants.

`preferredProviders` is an array; for non-federating subjects the array is treated as ordered preference and the first satisfiable element is used. Lets agents that have observed prior user choices via the capabilities manifest skip friction without bypassing user consent.

### Later: agent invokes a tool

Agent posts `ConnectionInvocation(subject: .calendar, capability: .writeCreate, arguments: {...})`.

Router:
1. Look up resolution for `(subject, conversationId, capability)`.
2. **Empty set (no resolution)** → return `ConnectionInvocationResult(status: .capabilityNotEnabled)` with a hint suggesting a `capability_request`.
3. **Resolution exists** → dispatch:
   - **Single-element set, write verb or non-federating read**: route to that provider's execution path (`device.*` → `ConnectionsManager.handleInvocation`; `composio.*` → cloud-connections execution).
   - **Multi-element set, read on federating subject**: fan out the read across every provider in the set, aggregate results, return one combined payload. Per-provider errors are surfaced in a `partialFailures` field on the result rather than failing the whole read.

### Cross-cutting: user changes providers

Three events can invalidate a resolution:

- User unlinks a cloud connection → for every resolution row containing that provider:
  - If the resolution was a single-element set referencing the unlinked provider → delete the row; next invocation re-prompts.
  - If the resolution was a multi-element set (federating-subject read) → remove the unlinked provider from the set. If the set becomes empty, delete the row. If it becomes single-element, the resolution naturally degrades to non-federated read against the remaining provider.
- User revokes iOS permission in Settings → next invocation returns `authorizationDenied` (existing behavior); the resolution itself is *not* cleared (a re-grant in Settings should restore behavior without re-prompting).
- User toggles off a subject from Conversation Info → clear every resolution for `(subject, conversationId)`.
- User toggles off a specific verb from Conversation Info → clear that one row.

### The picker's "connect another" path

Tapping a non-linked provider on the picker (Variant 2) or a "Connect" button (Variant 3):
- Device provider → kicks off iOS permission flow, falls back to Settings link if denied
- OAuth provider → opens `ASWebAuthenticationSession`, completes inline

When the new provider links, it's added to the current card state (not auto-approved — the user still needs to tap Approve).

## Wire-format changes

### Existing types gain a `subject` field

`ConnectionInvocation` (already in the stack) grows an optional `subject`:

```swift
public struct ConnectionInvocation {
    // ...existing fields...
    public let subject: CapabilitySubject?  // NEW — nil means "agent didn't model subject, fall back to kind"
}
```

During a transition period, `ConnectionInvocation.kind == .calendar` implies `subject == .calendar`. Once the cloud-connections side adopts `ConnectionInvocation` for writes, the `kind` field becomes device-specific and `subject` becomes the routing key.

### New content type: `convos.org/capability_request/1.0`

```swift
public struct CapabilityRequest: Codable, Sendable {
    public let requestId: String
    public let subject: CapabilitySubject
    public let capability: ConnectionCapability
    public let rationale: String                  // human-readable
    public let preferredProviders: [ProviderID]?  // agent hint; resolver may override
}
```

### New content type: `convos.org/capability_request_result/1.0`

```swift
public struct CapabilityRequestResult: Codable, Sendable {
    public enum Status: String, Codable { case approved, denied, cancelled }

    public let requestId: String
    public let status: Status
    public let subject: CapabilitySubject
    public let capability: ConnectionCapability
    public let providers: [ProviderID]  // populated only on .approved; size 1 for non-federating, ≥ 1 for federating reads
}
```

## Persistence

Resolutions live in a single GRDB table. The cardinality constraint (size 1 vs. set) is enforced in the resolver, not the schema, because the schema needs to support both shapes uniformly.

```
capabilityResolution(
    subject: String,                // CapabilitySubject.rawValue
    conversationId: String,
    capability: String,             // ConnectionCapability.rawValue
    providerIds: String,            // comma-joined ProviderID.rawValues; resolver enforces arity
    createdAt: Date,
    updatedAt: Date,
    PRIMARY KEY (subject, conversationId, capability)
)
```

The triple `(subject, conversationId, capability)` is the routing key. Each row's `providerIds` is a comma-joined list whose allowed cardinality is determined by the subject's `allowsReadFederation` flag and the capability verb shape (see [the resolution table](#resolution)). The resolver validates on insert/update and throws `ResolutionInconsistent` if a caller hands it a malformed set.

Resolutions are the **source of truth** for routing. The existing `Enablement` table (device side, in `ConvosConnections`) and `DBCloudConnectionGrant` table (cloud side) remain the source of truth for the underlying system's own state. When a resolution is created, the resolver calls into the matching system to flip its state for *each* provider in the set; when state is cleared in the underlying system, the resolver removes that provider from any resolution rows that reference it.

## Runtime capabilities manifest

The client publishes a unified per-sender manifest in conversation metadata so the agent's runtime knows what subjects/providers are available and what's currently granted. This **replaces** the `connections` metadata entry that PR #719 (CloudConnections) was going to publish — the unified shape covers both bodies of work.

### Location

`profile.metadata["capabilities"]` on each sender's own `ProfileUpdate` message. Same delivery pattern CloudConnections was using for its `connections` entry, just under a different key with a unified shape.

### Shape

```jsonc
{
  "version": 1,
  "providers": [
    {
      "id": "device.calendar",
      "subject": "calendar",
      "displayName": "Apple Calendar",
      "available": true,                              // framework reachable / OAuth not expired
      "linked": true,                                  // always true for device; OAuth-active for cloud
      "capabilities": ["read", "writeCreate", "writeUpdate", "writeDelete"],
      // `resolved` is per-capability so the runtime can see exactly which verbs route to
      // this provider in this conversation. For non-federating subjects, all verbs share
      // the same provider. For federating subjects, .read can be true on multiple
      // providers simultaneously while writes route to exactly one.
      "resolved": {
        "read": true,
        "writeCreate": true,
        "writeUpdate": true,
        "writeDelete": true
      }
    },
    {
      "id": "composio.google_calendar",
      "subject": "calendar",
      "displayName": "Google Calendar",
      "available": true,
      "linked": true,
      "capabilities": ["read", "writeCreate", "writeUpdate", "writeDelete"],
      "resolved": { "read": false, "writeCreate": false, "writeUpdate": false, "writeDelete": false }
    },
    {
      "id": "composio.strava",
      "subject": "fitness",
      "displayName": "Strava",
      "available": true,
      "linked": true,
      "capabilities": ["read"],
      // Strava + Fitbit both resolve to .read; agent's read tool fans out across both.
      "resolved": { "read": true }
    },
    {
      "id": "composio.fitbit",
      "subject": "fitness",
      "displayName": "Fitbit",
      "available": true,
      "linked": true,
      "capabilities": ["read"],
      "resolved": { "read": true }
    }
  ]
}
```

The per-capability `resolved` map is what makes federation legible to the runtime — counting how many providers have `resolved.read == true` for a given subject tells the runtime whether to expect a federated read result shape.

### When the manifest is rewritten

Any change that affects the manifest triggers a republish on the next `ProfileUpdate`:

- Provider registered (device permission granted; OAuth service linked)
- Provider unregistered (device permission revoked; OAuth service unlinked)
- Resolution created / modified / cleared
- Grant added / revoked
- Provider's underlying availability flips (e.g. ScreenTime entitlement granted/revoked)

### Runtime behavior (defines the contract for the runtime PR)

On every `ProfileUpdate` arrival, agent infrastructure reads `metadata["capabilities"]`:

- `resolved == true` AND `granted[capability] == true` → agent surfaces the corresponding tool; can call freely.
- `resolved == true` AND `granted[capability] == false` → agent can request that specific verb via `capability_request`; the picker is skipped, just a verb-consent card.
- `resolved == false` AND `linked == true` → agent can request the subject; if the user's resolution is for a different provider, the request still routes there (the agent may ask via `preferredProvider` to nudge a switch).
- `linked == false` → agent can still request the subject; the client picker offers "Connect."
- `available == false` → agent ignores the entry (provider exists conceptually but isn't reachable on this device).

The `preferredProvider` hint in subsequent `capability_request` messages lets the agent reference a specific provider it's seen in prior manifests, defaulting the card to that provider (see [Agent-provided provider hint](#agent-provided-provider-hint-preferredprovider)).

### Relationship to PR #719's `connections` metadata

PR #719 (CloudConnections) was going to publish its own `profile.metadata["connections"]` payload listing OAuth grants. That key becomes redundant — cloud grants now appear as `providers[].granted` entries inside the unified `capabilities` manifest.

**Decision**: CloudConnections skips publishing the `connections` key from day one. Neither side has shipped to the wire yet, so the coordination cost is zero. The runtime reader is built once, against `capabilities`.

### Concerns

- **`ProfileUpdate` write rate**: every resolution or grant change triggers a write. Rate is human-driven (toggling a capability is a deliberate user action), so this is bounded. Worth measuring once real usage is live, but no design change anticipated.
- **Visibility to other conversation members**: the manifest is per-sender, scoped to the sender's own `ProfileUpdate`. Other members see what subjects/providers you have available + granted in the conversation. This is expected — today they see your `connections` metadata for the same reason. No new leak.
- **Manifest size**: at v1 scope (~10 subjects, ≤2-3 providers each), the manifest is small (<2KB JSON). Worth re-evaluating if the provider catalog grows substantially.

## Integration points

| System | Registers providers | Handles invocations |
|---|---|---|
| `ConvosConnections` | One per `ConnectionKind` on `ConnectionsManager` init | Existing `handleInvocation` path |
| `CloudConnections` | One per `CloudConnection` row on `CloudConnectionManager` bootstrap; adds/removes on link/unlink | Routes to Composio tool call (runtime handles this; client just forwards) |

Resolver lives in `ConvosCore/Sources/ConvosCore/CapabilityResolution/` (new directory, no suffix) — belongs to neither package.

## Failure modes

| Scenario | Behavior |
|---|---|
| Agent invokes before any `capability_request` has happened | `capabilityNotEnabled` result with hint |
| Resolution exists for one verb but the requested verb has no resolution row | `capabilityNotEnabled` with hint; the verb-only consent card surfaces next time the user views the conversation, defaulted to the same provider(s) when applicable |
| Resolution points at a provider that's since been unlinked, single-element set | Clear the row, return `capabilityNotEnabled` with hint; next invocation re-prompts |
| Resolution points at a provider that's since been unlinked, multi-element federation set | Remove the unlinked provider from the set; if remaining set is non-empty, continue routing; otherwise treat as the single-element-cleared case |
| User taps Approve but OAuth linking fails | Surface error on the card, stay in pending state; user can retry or Deny |
| User backgrounds app during card display | Card dismisses; client posts `capability_request_result(status: .cancelled)` |
| Resolution points at a provider that's unavailable at call time, single-target | Return `executionFailed` with the provider ID in the error; do not silently fall back to another provider |
| Federated read with mixed success across providers | Return aggregated payload + `partialFailures: [{providerId, error}]` so the agent can decide whether to surface or retry per-provider |

## v1 Success criteria

- [ ] `CapabilitySubject` (with `allowsReadFederation: Bool` extension), `ProviderID`, `CapabilityProvider`, `CapabilityProviderRegistry`, `CapabilityResolver` types defined in `ConvosCore/Sources/ConvosCore/CapabilityResolution/`
- [ ] `ProviderChange` enum + `providerChanges: AsyncStream<ProviderChange>` on the registry
- [ ] GRDB migration adding `capabilityResolution` table
- [ ] Both `ConvosConnections` (device) and `CloudConnections` register providers at their respective bootstrap points
- [ ] `capability_request` and `capability_request_result` content codecs added (`convos.org/capability_request/1.0`, `.../capability_request_result/1.0`)
- [ ] Card renders Variant 1 / 2a / 2b / 3 based on linked-provider count, the subject's federation flag, and the verb shape
- [ ] Card refreshes reactively when a new provider is linked mid-display (subscribes to `providerChanges`)
- [ ] `preferredProviders` hint defaults the card to that selection when satisfiable
- [ ] Verb-only consent card renders when a resolution exists for one verb but not the requested one (defaulted to same provider(s) when applicable)
- [ ] Router dispatches `ConnectionInvocation` by `(subject, capability)` to the resolved provider's execution path; fans out for federated reads
- [ ] Resolutions auto-clear / shrink on provider unlink; do *not* auto-clear on iOS permission revoke
- [ ] Client publishes `profile.metadata["capabilities"]` manifest with the per-capability `resolved` map on every relevant state change
- [ ] CloudConnections stops publishing `profile.metadata["connections"]` (subsumed by `capabilities`)
- [ ] Tests: first-time request → card → approve → invocation routes correctly (single + multi-set); provider unlink shrinks/clears resolution; write with no resolution returns `capabilityNotEnabled`; verb-only consent flow on second-verb request; `preferredProviders` hint defaults the card; federated read fan-out aggregates results; partialFailures surface per-provider errors; manifest republishes after resolution changes; reactive card refresh on `providerChanges`

## Out of scope for v1

- **Federation on subjects flagged `allowsReadFederation: false`**. Calendar, contacts, photos, music, and the rest enforce single-provider for v1. We can flip more subjects to true as use cases emerge.
- **Per-verb provider differences within a non-federating subject** (e.g. read from Apple Calendar, write to Google Calendar in the same conversation). All verbs route to the same provider for non-federating subjects in v1.
- Per-subject default preferences at the user account level ("always use Google Calendar everywhere") — may be added in v2 as a shortcut over per-conversation resolution.
- Conflict resolution when two conversations resolve the same subject to different providers — intentional, each conversation is independent.
- Resolver sync across the user's devices — per-device for v1; cross-device TBD alongside the broader enablement-sync design.
- Collapsing `ConnectionKind` into `CapabilitySubject` — see decision #5 below; deferred to a future cleanup once both systems route by `subject`.

## Future: more subjects opt into federation

The opt-in federation flag means we can ship more federated subjects without a schema change — flipping `.contacts` or `.photos` to `allowsReadFederation: true` later just expands the picker to a multi-select form for those subjects. Things to think through when adding more:

- **Result-shape compatibility.** Federation works well when results from different providers are independently meaningful and can be concatenated (fitness activities, photo metadata, contact entries). It doesn't work for subjects where the providers compete for the same logical entity — e.g. two calendars both claiming "your work calendar." Calendar federation specifically gets stuck on conflict resolution and the "which calendar did this event land on?" trust problem; that's why it's permanently single-provider barring a separate product design.
- **Quota / rate-limit fan-out.** A federated read on a subject with N providers is N API calls; rate-limit budgets need to account for that.
- **Order semantics.** Some subjects have a natural ordering (calendar events by date, photos by capture date). Aggregation needs a defined merge order.

When relaxing more subjects, just update the table at the top of [v1 scope cut](#v1-scope-cut-federation-is-opt-in-per-subject) and write tests for the new fan-out path.

## Design decisions

1. **Resolver location**: lives in `ConvosCore/Sources/ConvosCore/CapabilityResolution/`. Pure core types, no UIKit. The card UI stays in the main app; the resolver vends data only.

2. **Mid-card provider link reactivity**: card refreshes in place via `CapabilityProviderRegistry.providerChanges: AsyncStream<ProviderChange>`. When the user taps "Connect," completes OAuth, and returns to the card, the new provider row appears without dismissing. SwiftUI view subscribes; no manual refresh needed.

3. **Unified runtime visibility**: solved by the [capabilities manifest](#runtime-capabilities-manifest). Both device and OAuth providers appear in `profile.metadata["capabilities"]`. The runtime reads this single key and learns about all subjects/providers/grants/resolutions across both systems.

4. **Agent `preferredProviders` hint**: honored as an array. When the hint is satisfiable, the client renders Variant 1 (single hint) or Variant 2b with rows pre-checked (multi-element hint on a federating subject). The user can still escape to Variant 2 to change the selection.

5. **`CapabilitySubject` vs `ConnectionKind`**: kept separate for v1.
   - `ConnectionKind` is the device-layer identity key inside `ConvosConnections` — routes payloads and invocations within that package; not all `ConnectionKind` values map cleanly to a user-facing subject (`.motion`, for example).
   - `CapabilitySubject` is the cross-system routing key — what the agent asks for; not all subjects have a `ConnectionKind` (`.tasks`, `.mail`).
   - Device providers carry both: `device.calendar` has subject `.calendar` and kind `.calendar`. OAuth providers carry only a subject.
   - Collapsing them would force OAuth providers to invent fake `ConnectionKind` values. Wrong direction.
   - Revisit once both systems route by `subject` at the wire layer.

6. **Federation is per-subject, not global**: see [the scope cut](#v1-scope-cut-federation-is-opt-in-per-subject). Subjects opt in via `allowsReadFederation: Bool`. Default is false (safer); fitness is the v1 yes. Lets us ship aggregated reads where they make product sense (fitness across Strava + Fitbit + Apple Health) without forcing the same UX on subjects where multi-provider is a trust hazard (calendar, contacts).

7. **Writes never federate, regardless of subject**: a write that lands on "whichever calendar" is a trust-breaking outcome — the user opens Apple Calendar and doesn't see the new event, or opens Google Calendar and doesn't see it there either. Forcing single-provider on writes is a hard-won reliability property that holds even on subjects that opt into read federation.

## Migration / ordering

1. **PR #767 renames** symbols/directory from `Connection*` → `CloudConnection*`. ✅ Landed as part of the ConvosConnections PR — needed before the resolver can refer to both systems by clear names.
2. **Capability resolution PR** — this document's v1:
   - Core types (`CapabilitySubject`, `ProviderID`, registry with `providerChanges` stream, resolver)
   - GRDB migration adding `capabilityResolution` and `capabilityGrant`
   - Wire content codecs (`capability_request`, `capability_request_result`)
   - Router with subject-keyed dispatch
   - Capabilities manifest writer (publishes `profile.metadata["capabilities"]` on resolution/registry changes)
3. **ConvosConnections provider registration** — small patch: register providers at `ConnectionsManager` init.
4. **CloudConnections provider registration + manifest cutover** — small patch:
   - Register providers at link time
   - Stop publishing `profile.metadata["connections"]`; rely on the unified `capabilities` manifest
5. **Card UI** — main-app SwiftUI view that observes the resolver, registry, and `providerChanges` stream. Includes Variant 1 / 2 / 3 plus the verb-only consent variant.
6. **Main-app wiring** — codec registration in `InboxStateMachine`'s `ClientOptions(codecs: [...])`, hook `capability_request` messages into the existing decoded-message dispatch.
7. **Runtime PR (someone else)** — agent infrastructure reads `profile.metadata["capabilities"]` and provisions tools accordingly. Not in this PRD's scope but the contract is locked here.

Steps 2–6 are roughly independent after #1; can be stacked or parallel. Step 7 unblocks once steps 2 and 4 land (so the wire format is stable).

## Appendix: why a single provider per subject for v1

## Appendix: why the appropriate federation behavior depends on the subject

The federation question — "if a user has linked multiple providers for a subject, should the agent see all of them at once?" — has three plausible answers, and which one is right depends on what the data looks like.

1. **Pick one, every time.** User commits per conversation. Agent always knows where it's reading and writing. Predictable; matches how users think about questions like "which calendar?"
2. **Federate reads, single-target writes.** Reads merge across all linked providers; writes target one. Maximizes the agent's information without the "which calendar did it land in?" trust problem.
3. **Per-verb selection.** Read from Apple, write to Google. Maximally flexible; maximally complex consent UI.

(3) is uniformly more cost than benefit and isn't on the roadmap. The interesting choice is between (1) and (2), and it's not the same call for every subject:

- **`.fitness` favors (2).** Activity data from Strava, Fitbit, and Apple Health is independently meaningful and union-shaped — a week's runs across all three is a strict superset of any single source, with no conflict. Aggregation is just concatenation. The v1 yes.
- **`.calendar` favors (1).** Two calendars logically compete for the same entity (your work calendar, your personal calendar). Federated reads beg the question "which calendar should the agent file this event suggestion under?" and the federated-write answer is the trust-breaking failure mode the original PRD called out. Apple Calendar's own UI already merges multiple calendar accounts within one app; there's no clean way to *unmerge* at the routing layer. Permanent (1).
- **`.contacts` is closer to `.fitness`.** Apple Contacts and Google Contacts can both have entries; federated reads return both and the agent can dedupe by name. Worth flipping to true once we have product feedback.
- **`.photos` is uncertain.** Apple Photos + Google Photos may have substantial overlap for users who back up both; federation could surface the same photo twice. Needs design work on dedup.
- **`.location`, `.screen_time`, `.home`, `.music`** — single provider per device, federation moot.

The flag-per-subject approach lets us flip these one at a time without changing the routing layer, the wire format, or the picker code. v1 ships fitness federation; the rest are conservative defaults that we revise based on usage.
