# Capability Resolution — Subject / Provider Model

**Status**: Design locked; ready for implementation
**Owner**: @yewreeka
**Depends on**: [`connections-vs-integrations.md`](./connections-vs-integrations.md)
**Blocks**: `capability_request` content type, ConvosConnections main-app integration, any cross-provider agent tool call

## Problem

Convos has (or will have) two parallel systems that let agents access user resources:

- **ConvosConnections** — native iOS APIs (Calendar via EventKit, Contacts via CNContactStore, Photos via PhotoKit, …)
- **Integrations** — OAuth-linked cloud services (Google Calendar, Google Drive, … via Composio)

A single agent intent like "I'd like to access your calendar" can map to either one, both, or neither. Today neither system knows about the other. The client has no principled way to decide which one to use when an agent requests a capability.

This PRD defines how the client resolves agent capability requests to concrete providers, how it presents the choice to the user, how it persists the resolution, and how later agent tool calls route to the right execution path.

## Non-Goals

- Re-unifying ConvosConnections and Integrations under a single `DataSource`/`DataSink` abstraction. The [comparison doc](./connections-vs-integrations.md) already argued against that.
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

One user can have N providers linked for a subject. Provider registration is the responsibility of each underlying system — ConvosConnections registers device providers at startup, the Integrations system registers OAuth providers as users link services.

### Resolution

A persistent decision binding `(subject, conversationId, capability)` to a set of providers:

- For **reads** (`.read`) — resolution is a *set* of providers. All grant together; the agent gets federated results.
- For **writes** (`.writeCreate`, `.writeUpdate`, `.writeDelete`) — resolution is a *single* provider. You can't silently create on "whichever."

Absence of a resolution means "ask the user the next time the capability is invoked."

### Resolver

The coordinator that sits between incoming `capability_request` / `ConnectionInvocation` messages and the two underlying systems. Lives in ConvosCore (not in either package):

```swift
public protocol CapabilityResolver: Sendable {
    /// All providers currently registered for this subject, regardless of whether the user
    /// has linked them or granted them for this conversation.
    func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider]

    /// What the user picked previously for this (subject, conversation, capability). Nil if
    /// they've never been asked.
    func resolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async -> Resolution?

    /// User has just chosen their providers via the picker card.
    func setResolution(
        _ providerIds: Set<ProviderID>,
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws

    /// Clear a resolution (user unlinks a provider, or revokes a grant).
    func clearResolution(
        subject: CapabilitySubject,
        capability: ConnectionCapability,
        conversationId: String
    ) async throws
}
```

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
    var iconName: String { get }            // SF Symbol name for the picker card
    var capabilities: Set<ConnectionCapability> { get }  // which verbs supported
    var linkedByUser: Bool { get async }    // does user have credentials for this?
}

public enum ProviderChange: Sendable {
    case added(ProviderID)
    case removed(ProviderID)
    case linkedStateChanged(ProviderID)  // e.g. OAuth linked/unlinked, iOS permission granted/denied
}

public protocol CapabilityProviderRegistry: Sendable {
    func register(_ provider: any CapabilityProvider) async
    func unregister(id: ProviderID) async
    func providers(for subject: CapabilitySubject) async -> [any CapabilityProvider]
    func provider(id: ProviderID) async -> (any CapabilityProvider)?

    /// Observable stream of provider-registry changes. The picker card UI subscribes so it
    /// can refresh in place when the user taps "Connect another" mid-picker and completes
    /// an OAuth flow or a device permission grant. Without this, the user would have to
    /// dismiss the card and wait for the agent to re-request.
    var providerChanges: AsyncStream<ProviderChange> { get }
}
```

ConvosConnections registers one provider per `ConnectionKind` at manager init. The Integrations system registers one provider per OAuth connection on link + removes on unlink.

## UX flow

### First time: agent requests a capability

1. Agent posts a `capability_request(subject: .calendar, capability: .read, rationale: "To summarize your week")` to the conversation.
2. Client receives the content type, renders a **picker card**:

```
┌─ Assistant wants to read your calendar ──────────┐
│ "To summarize your week"                         │
│                                                  │
│  ☑ Apple Calendar      (device)                  │
│  ☑ Google Calendar     (linked)                  │
│  ☐ Microsoft Outlook   (tap to connect)          │
│                                                  │
│  [ Approve ]  [ Deny ]                           │
└──────────────────────────────────────────────────┘
```

Rules:
- **Multi-select** if capability is `.read`
- **Single-select** if capability is `.writeCreate` / `.writeUpdate` / `.writeDelete`
- Unlinked providers show a "tap to connect" affordance; tapping kicks off the OAuth flow (for Integrations) or the iOS permission flow (for ConvosConnections) inline
- If only **one** provider exists for the subject, skip the picker; render a simpler consent card with a single Approve/Deny
- If **zero** providers exist, surface "no calendar providers available; connect one" — effectively the same picker but with only "connect" rows

3. User approves → resolver stores the resolution → `ConvosConnections` or Integrations flips the underlying enablement/grant → client publishes an updated [capabilities manifest](#runtime-capabilities-manifest) on the next `ProfileUpdate` → client posts a `capability_request_result(status: .approved, providers: [...])` reply to the conversation.

### Agent-provided provider hint (`preferredProviders`)

If the `CapabilityRequest` carries a non-empty `preferredProviders` array, the client applies pre-picker logic:

1. Filter `preferredProviders` to those that are registered, linked, and support the requested capability.
2. If the filtered set is non-empty AND its arity matches the capability (single for writes, ≥1 for reads):
   - Render a **confirmation card** instead of the full picker: "Assistant wants to [capability] your [subject] via [provider(s)]. Allow?"
   - User taps Approve → resolution = the filtered set
   - User taps "Other options…" (always exposed as a secondary button) → fall back to the full picker
   - User taps Deny → resolver posts `capability_request_result(status: .denied)`; no resolution stored
3. Otherwise (hint matches nothing available): render the full picker as normal.

This lets agents that have observed prior user choices (via the capabilities manifest) skip friction, while preserving user control — the "Other options…" escape hatch always exists, and the user can Deny outright.

### Later: agent invokes a tool

Agent posts `ConnectionInvocation(subject: .calendar, capability: .writeCreate, arguments: {...})`.

Router:
1. Look up resolution for `(calendar, conversationId, .writeCreate)`.
2. If none → return `ConnectionInvocationResult(status: .capabilityNotEnabled)` with an error hint suggesting the agent first send a `capability_request`.
3. If resolution resolves to `device.calendar` → route to `ConnectionsManager.handleInvocation` (existing path).
4. If resolution resolves to `composio.google_calendar` → hand off to the Integrations execution path.
5. For `.read` reads across a set of providers → fan out, aggregate results, return a single federated payload.

### Cross-cutting: user changes providers

Three events can invalidate a resolution:

- User unlinks an OAuth integration ⇒ clear every resolution that pointed at that provider; next invocation re-prompts.
- User revokes iOS permission in Settings ⇒ next invocation returns `authorizationDenied` (existing behavior); no resolution change (they may grant again without wanting re-prompting).
- User toggles off a capability from Conversation Info ⇒ clear resolution for that `(subject, conversation, capability)`.

### The picker's "connect another" path

Tapping a non-linked provider on the picker card:
- Device provider → kicks off iOS permission flow, falls back to Settings link if denied
- OAuth provider → opens `ASWebAuthenticationSession`, completes inline

When the new provider links, it's added to the current picker state (not auto-approved — the user still needs to tap Approve).

## Wire-format changes

### Existing types gain a `subject` field

`ConnectionInvocation` (already in the stack) grows an optional `subject`:

```swift
public struct ConnectionInvocation {
    // ...existing fields...
    public let subject: CapabilitySubject?  // NEW — nil means "agent didn't model subject, fall back to kind"
}
```

During a transition period, `ConnectionInvocation.kind == .calendar` implies `subject == .calendar`. Once the Integrations side adopts `ConnectionInvocation` for writes, the `kind` field becomes device-specific and `subject` becomes the routing key.

### New content type: `convos.org/capability_request/1.0`

```swift
public struct CapabilityRequest: Codable, Sendable {
    public let requestId: String
    public let subject: CapabilitySubject
    public let capability: ConnectionCapability
    public let rationale: String                 // human-readable
    public let preferredProviders: [ProviderID]? // agent hint; resolver may override
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
    public let providers: [ProviderID]           // populated only on .approved
}
```

## Persistence

Resolutions live in a new GRDB table `capabilityResolution` on the client:

```
capabilityResolution(
    subject: String,                // CapabilitySubject.rawValue
    capability: String,             // ConnectionCapability.rawValue
    conversationId: String,
    providerIds: String,            // comma-joined ProviderID raw values
    createdAt: Date,
    updatedAt: Date,
    PRIMARY KEY (subject, capability, conversationId)
)
```

Resolutions are the **source of truth** for routing. The existing `Enablement` table (ConvosConnections) and `DBConnectionGrant` table (Integrations) remain the source of truth for the underlying system's own state. When a resolution is created, the resolver calls into the matching system to flip its state; when state is cleared in the underlying system, the resolver cleans up the corresponding resolution.

## Runtime capabilities manifest

The client publishes a unified per-sender manifest in conversation metadata so the agent's runtime knows what subjects/providers are available and what's currently granted. This **replaces** the standalone `connections` metadata entry that PR #719 (Integrations) was going to publish — the unified shape covers both bodies of work.

### Location

`profile.metadata["capabilities"]` on each sender's own `ProfileUpdate` message. Same delivery pattern Integrations was using for its `connections` entry, just under a different key with a unified shape.

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
      "granted": {
        "read": true,
        "writeCreate": false,
        "writeUpdate": false,
        "writeDelete": false
      }
    },
    {
      "id": "composio.google_calendar",
      "subject": "calendar",
      "displayName": "Google Calendar",
      "available": true,
      "linked": true,
      "capabilities": ["read", "writeCreate", "writeUpdate", "writeDelete"],
      "granted": {
        "read": true,
        "writeCreate": true,
        "writeUpdate": false,
        "writeDelete": false
      }
    },
    {
      "id": "device.contacts",
      "subject": "contacts",
      "displayName": "Apple Contacts",
      "available": true,
      "linked": true,
      "capabilities": ["read", "writeCreate", "writeUpdate", "writeDelete"],
      "granted": { "read": false, "writeCreate": false, "writeUpdate": false, "writeDelete": false }
    }
  ]
}
```

### When the manifest is rewritten

Any change that affects the manifest triggers a republish on the next `ProfileUpdate`:

- Provider registered (device permission granted; OAuth service linked)
- Provider unregistered (device permission revoked; OAuth service unlinked)
- Resolution created / modified / cleared
- Provider's underlying availability flips (e.g. ScreenTime entitlement granted/revoked)

### Runtime behavior (defines the contract for the runtime PR)

On every ProfileUpdate arrival, agent infrastructure reads `metadata["capabilities"]`:

- `granted[capability] == true` → agent surfaces the corresponding tool; can call freely.
- `linked == true` AND `granted[capability] == false` → agent can request via `capability_request`; user has the credential but hasn't granted this conversation.
- `linked == false` → agent can still request the subject; the client picker offers "Connect another."
- `available == false` → agent ignores the entry (provider exists conceptually but isn't reachable on this device).

The `preferredProviders` hint in subsequent `capability_request` messages lets the agent reference specific provider IDs it's seen in prior manifests, skipping the picker (see [Agent-provided provider hint](#agent-provided-provider-hint-preferredproviders)).

### Relationship to PR #719's `connections` metadata

PR #719 (Integrations) was going to publish its own `profile.metadata["connections"]` payload listing OAuth grants. That key becomes redundant — Integrations grants now appear as `providers[].granted` entries inside the unified `capabilities` manifest.

**Decision**: Integrations skips publishing the `connections` key from day one. Neither side has shipped to the wire yet, so the coordination cost is zero. The runtime reader is built once, against `capabilities`.

### Concerns

- **ProfileUpdate write rate**: every resolution change triggers a write. Rate is human-driven (toggling a capability is a deliberate user action), so this is bounded. Worth measuring once real usage is live, but no design change anticipated.
- **Visibility to other conversation members**: the manifest is per-sender, scoped to the sender's own ProfileUpdate. Other members see what subjects/providers you have available + granted in the conversation. This is expected — today they see your `connections` metadata for the same reason. No new leak.
- **Manifest size**: at v1 scope (~10 subjects, ≤2-3 providers each), the manifest is small (<2KB JSON). Worth re-evaluating if the provider catalog grows substantially.

## Integration points

| System | Registers providers | Handles invocations |
|---|---|---|
| `ConvosConnections` | One per `ConnectionKind` on `ConnectionsManager` init | Existing `handleInvocation` path |
| Integrations (PR #719 → rename to Integrations) | One per `Connection` row on `ConnectionManager` bootstrap; adds/removes on link/unlink | Routes to Composio tool call (runtime handles this; client just forwards) |

Resolver lives in `ConvosCore/Sources/ConvosCore/CapabilityResolution/` (new directory, no suffix) — belongs to neither package.

## Failure modes

| Scenario | Behavior |
|---|---|
| Agent invokes before any `capability_request` has happened | `capabilityNotEnabled` result with hint |
| Resolution points at a provider that's since been unlinked | Clear stale resolution, return `capabilityNotEnabled` with hint; next invocation will re-prompt |
| User taps Approve but OAuth linking fails | Surface error on the card, stay in pending state; user can retry or Deny |
| User backgrounds app during picker display | Card dismisses; client posts `capability_request_result(status: .cancelled)` |
| `.read` fan-out with mixed success (e.g. device OK, Google failed) | Return partial result + per-provider error breakdown; do not fail the whole read |
| `.writeCreate` resolution points at a provider that's unavailable at call time | Return `executionFailed` with the provider ID in the error; do not silently fall back to another provider |

## v1 Success criteria

- [ ] `CapabilitySubject`, `ProviderID`, `CapabilityProvider`, `CapabilityProviderRegistry`, `CapabilityResolver` types defined in `ConvosCore/Sources/ConvosCore/CapabilityResolution/`
- [ ] `ProviderChange` enum + `providerChanges: AsyncStream<ProviderChange>` on the registry
- [ ] GRDB migration adding `capabilityResolution` table
- [ ] Both ConvosConnections and Integrations register providers at their respective bootstrap points
- [ ] `capability_request` and `capability_request_result` content codecs added (`convos.org/capability_request/1.0`, `.../capability_request_result/1.0`)
- [ ] Picker card renders with single-select / multi-select behavior driven by capability verb
- [ ] Picker card refreshes reactively when a new provider is linked mid-display (subscribes to `providerChanges`)
- [ ] `preferredProviders` hint short-circuits the full picker into a confirmation card when the hint is satisfiable
- [ ] Router dispatches `ConnectionInvocation` by subject to the right execution path
- [ ] Resolutions auto-clear on provider unlink / grant revoke
- [ ] Reads federate across a set of providers; writes target a single provider
- [ ] If only one provider exists, picker is replaced by a simpler single-choice consent
- [ ] Client publishes `profile.metadata["capabilities"]` manifest on every relevant state change
- [ ] Integrations stops publishing `profile.metadata["connections"]` (subsumed by `capabilities`)
- [ ] Tests covering: first-time request → picker → approve → invocation routes correctly; provider unlink clears resolution; read fan-out aggregates; write with no resolution returns `capabilityNotEnabled`; `preferredProviders` hint short-circuit; manifest republishes after resolution changes; reactive picker refresh on `providerChanges`

## Out of scope for v1

- Per-subject default preferences at the user account level ("always use Google Calendar everywhere") — may be added in v2 as a shortcut over per-conversation resolution.
- Conflict resolution when two conversations resolve the same subject to different providers — intentional, each conversation is independent.
- Resolver sync across the user's devices — per-device for v1; cross-device TBD alongside the broader enablement-sync design.
- Collapsing `ConnectionKind` into `CapabilitySubject` — see decision #5 below; deferred to a future cleanup once both systems route by `subject`.

## Design decisions

All five questions raised during design have been resolved:

1. **Resolver location**: lives in `ConvosCore/Sources/ConvosCore/CapabilityResolution/`. Pure core types, no UIKit. The picker card's UI stays in the main app; the resolver vends data only.

2. **Mid-conversation provider link reactivity**: picker refreshes in place via `CapabilityProviderRegistry.providerChanges: AsyncStream<ProviderChange>`. When the user taps "Connect another," completes OAuth, and returns to the card, the new provider row appears without dismissing. SwiftUI view subscribes; no manual refresh needed.

3. **Device enablement runtime visibility**: solved by the unified [capabilities manifest](#runtime-capabilities-manifest). Both device and OAuth providers appear in `profile.metadata["capabilities"]`. The runtime reads this single key and learns about all subjects/providers/grants across both systems.

4. **Agent `preferredProviders` hint**: honored. When the agent supplies a satisfiable hint, the client renders a lightweight confirmation card instead of the full picker, with an "Other options…" escape hatch back to the full picker. Detail in [Agent-provided provider hint](#agent-provided-provider-hint-preferredproviders).

5. **`CapabilitySubject` vs `ConnectionKind`**: kept separate for v1.
   - `ConnectionKind` is the device-layer identity key inside `ConvosConnections` — routes payloads and invocations within that package; not all `ConnectionKind` values map cleanly to a user-facing subject (`.motion`, for example).
   - `CapabilitySubject` is the cross-system routing key — what the agent asks for; not all subjects have a `ConnectionKind` (`.tasks`, `.mail`).
   - Device providers carry both: `device.calendar` has subject `.calendar` and kind `.calendar`. OAuth providers carry only a subject.
   - Collapsing them would force OAuth providers to invent fake `ConnectionKind` values. Wrong direction.
   - Revisit once both systems route by `subject` at the wire layer.

## Migration / ordering

1. **PR #719 renames** "Connections" → "Integrations" (see the comparison doc). Prerequisite so "Connections" can unambiguously refer to the device path.
2. **Capability resolution PR** — this document's v1:
   - Core types (`CapabilitySubject`, `ProviderID`, registry with `providerChanges` stream, resolver)
   - GRDB migration adding `capabilityResolution`
   - Wire content codecs (`capability_request`, `capability_request_result`)
   - Router with subject-keyed dispatch
   - Capabilities manifest writer (publishes `profile.metadata["capabilities"]` on resolution/registry changes)
3. **ConvosConnections provider registration** — small patch on top of #718 to register providers at `ConnectionsManager` init.
4. **Integrations provider registration + manifest cutover** — small patch on the renamed Integrations branch:
   - Register providers at link time
   - Stop publishing `profile.metadata["connections"]`; rely on the unified `capabilities` manifest
5. **Picker card UI** — main-app SwiftUI view that observes the resolver, registry, and `providerChanges` stream. Includes the `preferredProviders` confirmation-card variant.
6. **Main-app wiring** — codec registration in `InboxStateMachine`'s `ClientOptions(codecs: [...])`, hook `capability_request` messages into the existing decoded-message dispatch.
7. **Runtime PR (someone else)** — agent infrastructure reads `profile.metadata["capabilities"]` and provisions tools accordingly. Not in this PRD's scope but the contract is locked here.

Steps 2–6 are roughly independent after #1; can be stacked or parallel. Step 7 unblocks once steps 2 and 4 land (so the wire format is stable).

## Appendix: why federated reads but not federated writes

When the user links both Apple Calendar and Google Calendar and says "yes, agent can read my calendar," the intent is clearly "read all of my calendars." Showing partial data (only device) would be worse than showing a merged view.

When the user says "agent can add events to my calendar," the intent is "I want events on *a* calendar I control." Which one? If we silently picked, the user would never trust the agent — they'd open Google Calendar and not find the new event. Or open Apple Calendar and not find it there either. Forcing a single-provider choice for writes is a hard-won reliability property.

(A future extension could be "create events on both and hold them consistent" — but that's its own product design, not a routing concern. Out of scope.)
