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

## v1 scope cut: one provider per (subject, conversation)

Earlier drafts of this PRD let a conversation resolve a subject to a *set* of providers — reads federated across all of them, writes targeted one. After scoping work we landed on a simpler v1 model:

- **A conversation resolves each subject to exactly one provider** for v1, regardless of capability verb.
- **If exactly one provider is linked** for a subject when an agent first asks, the client renders a lightweight confirmation card defaulting to that provider — the user just approves.
- **If multiple providers are linked**, the client renders a single-select picker — the user picks one.
- **If zero providers are linked**, the picker doubles as a "Connect a calendar" entry point with an OAuth/permission row per known provider.

Federated reads ("merge Apple Calendar + Google Calendar so the agent sees both") and per-verb provider differences ("read from Apple, write to Google") are deferred. They're real product asks, but the implementation cost (fan-out, partial-success error shapes, two-database resolution, picker UX with semi-checked rows) doesn't pencil for v1. See [Future: federated reads / split-verb resolutions](#future-federated-reads--split-verb-resolutions).

## Non-Goals

- Re-unifying device and cloud connections under a single `DataSource`/`DataSink` abstraction. The [comparison doc](./connections-device-vs-cloud.md) already argued against that.
- Multi-provider resolutions. One conversation, one subject, one provider — see [the scope cut above](#v1-scope-cut-one-provider-per-subject-conversation).
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

A persistent decision binding `(subject, conversationId)` to a single provider:

```
(subject: .calendar, conversationId: "abc") -> ProviderID("device.calendar")
```

A resolution covers every capability verb the agent will exercise on that subject. Once the user approves "read calendar via Apple Calendar," subsequent write requests in the same conversation target Apple Calendar too — but each new verb still requires explicit consent. (See [Verb consent vs. provider routing](#verb-consent-vs-provider-routing).)

Absence of a resolution means "ask the user the next time the capability is invoked."

### Resolver

The coordinator that sits between incoming `capability_request` / `ConnectionInvocation` messages and the two underlying systems. Lives in ConvosCore (not in either package):

```swift
public protocol CapabilityResolver: Sendable {
    /// All providers currently registered for this subject, regardless of whether the user
    /// has linked them.
    func availableProviders(for subject: CapabilitySubject) async -> [any CapabilityProvider]

    /// What the user picked previously for this (subject, conversation). Nil if they've
    /// never been asked.
    func resolution(
        subject: CapabilitySubject,
        conversationId: String
    ) async -> ProviderID?

    /// Has the user granted this specific verb on the resolved provider for this conversation?
    func hasGranted(
        capability: ConnectionCapability,
        subject: CapabilitySubject,
        conversationId: String
    ) async -> Bool

    /// User has just approved the picker / confirmation card.
    func setResolution(
        _ providerId: ProviderID,
        capability: ConnectionCapability,
        subject: CapabilitySubject,
        conversationId: String
    ) async throws

    /// Clear a resolution (user unlinks a provider, or revokes a grant via Conversation Info).
    func clearResolution(
        subject: CapabilitySubject,
        conversationId: String
    ) async throws
}
```

### Verb consent vs. provider routing

Two dimensions are tracked separately because they have different rotation cadences:

- **Resolution** = which provider handles this subject in this conversation. Sticky across capability verbs; only changes if the user explicitly switches providers or revokes the resolution.
- **Grant** = whether the user has approved a specific verb (`.read` / `.writeCreate` / `.writeUpdate` / `.writeDelete`) on the resolved provider. Tracked per verb because reading and writing carry different consent weight.

When the agent invokes a tool, the router looks up the resolution to pick the path, then checks the per-verb grant to decide whether to execute or return `capabilityNotEnabled`.

When the agent *requests* a verb the user hasn't granted yet, the resolver renders a verb-only consent card ("Allow [Apple Calendar] to write events?") — no provider picker, since the resolution is already fixed.

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

#### Variant 2 — multiple linked providers (single-select picker)

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

Single-select; `[ Approve ]` stays enabled when one row is checked.

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

User approves → resolver writes the resolution → device or cloud subsystem flips its underlying enablement/grant → client publishes an updated [capabilities manifest](#runtime-capabilities-manifest) on the next `ProfileUpdate` → client posts a `capability_request_result(status: .approved, provider: "device.calendar")` reply to the conversation.

### Agent-provided provider hint (`preferredProvider`)

If the `CapabilityRequest` carries a non-empty `preferredProvider`:

1. If it matches a linked, capability-supporting provider → render Variant 1 with that provider as the default; "Use a different calendar?" still escapes back to Variant 2.
2. Otherwise → fall through to whichever variant the user's link-state warrants.

Single-valued (matching the single-resolution model). Lets agents that have observed prior user choices via the capabilities manifest skip friction without bypassing user consent.

### Later: agent invokes a tool

Agent posts `ConnectionInvocation(subject: .calendar, capability: .writeCreate, arguments: {...})`.

Router:
1. Look up resolution for `(calendar, conversationId)`.
2. **No resolution** → return `ConnectionInvocationResult(status: .capabilityNotEnabled)` with a hint suggesting a `capability_request`.
3. **Resolution exists, verb not granted** → render a verb-only consent card on the *next* user view of the conversation (e.g. "Apple Calendar — allow writes?"). Until consent is granted, return `requiresConfirmation`. The agent can choose to send a fresh `capability_request` to surface the card eagerly.
4. **Resolution exists, verb granted** → dispatch to the resolved provider's execution path:
   - `device.*` → `ConnectionsManager.handleInvocation` (existing path).
   - `composio.*` → cloud-connections execution.

### Cross-cutting: user changes providers

Three events can invalidate a resolution:

- User unlinks a cloud connection → clear every resolution that pointed at that provider; next invocation re-prompts.
- User revokes iOS permission in Settings → next invocation returns `authorizationDenied` (existing behavior); the resolution itself is *not* cleared (a re-grant in Settings should restore behavior without re-prompting).
- User toggles off a subject from Conversation Info → clear resolution for `(subject, conversationId)` and revoke all verb grants.

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
    public let rationale: String                 // human-readable
    public let preferredProvider: ProviderID?    // agent hint; resolver may override
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
    public let provider: ProviderID?  // populated only on .approved
}
```

## Persistence

Two GRDB tables on the client. Resolutions and per-verb grants are split because they're updated at different cadences (resolution changes rarely; grants change every new verb the agent requests).

```
capabilityResolution(
    subject: String,                // CapabilitySubject.rawValue
    conversationId: String,
    providerId: String,             // ProviderID.rawValue (single)
    createdAt: Date,
    updatedAt: Date,
    PRIMARY KEY (subject, conversationId)
)

capabilityGrant(
    subject: String,
    conversationId: String,
    capability: String,             // ConnectionCapability.rawValue
    grantedAt: Date,
    PRIMARY KEY (subject, conversationId, capability),
    FOREIGN KEY (subject, conversationId) REFERENCES capabilityResolution
        ON DELETE CASCADE
)
```

Resolutions are the **source of truth** for routing. The existing `Enablement` table (device side, in `ConvosConnections`) and `DBCloudConnectionGrant` table (cloud side) remain the source of truth for the underlying system's own state. When a resolution is created, the resolver calls into the matching system to flip its state; when state is cleared in the underlying system, the resolver cleans up the corresponding resolution.

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
      "resolved": true,                                // is THIS provider the resolution for this conversation?
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
      "resolved": false,                               // user picked Apple Calendar for this conversation
      "granted": { "read": false, "writeCreate": false, "writeUpdate": false, "writeDelete": false }
    },
    {
      "id": "device.contacts",
      "subject": "contacts",
      "displayName": "Apple Contacts",
      "available": true,
      "linked": true,
      "capabilities": ["read", "writeCreate", "writeUpdate", "writeDelete"],
      "resolved": false,
      "granted": { "read": false, "writeCreate": false, "writeUpdate": false, "writeDelete": false }
    }
  ]
}
```

The `resolved` flag is the v1 addition — runtime can tell at a glance which provider per subject is the routed one and skip surfacing alternates as tools.

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
| Resolution exists but the requested verb hasn't been granted | `requiresConfirmation` result; verb-only consent card surfaces on next user view |
| Resolution points at a provider that's since been unlinked | Clear stale resolution, return `capabilityNotEnabled` with hint; next invocation re-prompts |
| User taps Approve but OAuth linking fails | Surface error on the card, stay in pending state; user can retry or Deny |
| User backgrounds app during card display | Card dismisses; client posts `capability_request_result(status: .cancelled)` |
| Resolution points at a provider that's unavailable at call time | Return `executionFailed` with the provider ID in the error; do not silently fall back to another provider |

## v1 Success criteria

- [ ] `CapabilitySubject`, `ProviderID`, `CapabilityProvider`, `CapabilityProviderRegistry`, `CapabilityResolver` types defined in `ConvosCore/Sources/ConvosCore/CapabilityResolution/`
- [ ] `ProviderChange` enum + `providerChanges: AsyncStream<ProviderChange>` on the registry
- [ ] GRDB migration adding `capabilityResolution` and `capabilityGrant` tables
- [ ] Both `ConvosConnections` (device) and `CloudConnections` register providers at their respective bootstrap points
- [ ] `capability_request` and `capability_request_result` content codecs added (`convos.org/capability_request/1.0`, `.../capability_request_result/1.0`)
- [ ] Confirmation card renders Variant 1 / 2 / 3 based on linked-provider count
- [ ] Card refreshes reactively when a new provider is linked mid-display (subscribes to `providerChanges`)
- [ ] `preferredProvider` hint defaults the card to that provider when satisfiable
- [ ] Verb-only consent card renders when the resolution exists but the verb isn't granted yet
- [ ] Router dispatches `ConnectionInvocation` by subject to the resolved provider's execution path
- [ ] Resolutions auto-clear on provider unlink; do *not* auto-clear on iOS permission revoke
- [ ] Client publishes `profile.metadata["capabilities"]` manifest with the `resolved` flag on every relevant state change
- [ ] CloudConnections stops publishing `profile.metadata["connections"]` (subsumed by `capabilities`)
- [ ] Tests: first-time request → confirmation card → approve → invocation routes correctly; provider unlink clears resolution; write with no resolution returns `capabilityNotEnabled`; verb-only consent flow on second-verb request; `preferredProvider` hint defaults the card; manifest republishes after resolution changes; reactive card refresh on `providerChanges`

## Out of scope for v1

- **Federated reads** across multiple providers in one conversation. Single resolution per subject for now; see [Future: federated reads / split-verb resolutions](#future-federated-reads--split-verb-resolutions).
- **Split-verb resolutions** (e.g. read from Apple, write to Google in the same conversation). Same future-work bucket.
- Per-subject default preferences at the user account level ("always use Google Calendar everywhere") — may be added in v2 as a shortcut over per-conversation resolution.
- Conflict resolution when two conversations resolve the same subject to different providers — intentional, each conversation is independent.
- Resolver sync across the user's devices — per-device for v1; cross-device TBD alongside the broader enablement-sync design.
- Collapsing `ConnectionKind` into `CapabilitySubject` — see decision #5 below; deferred to a future cleanup once both systems route by `subject`.

## Future: federated reads / split-verb resolutions

The single-provider scope cut keeps v1 simple but leaves real product asks on the table:

- **Federated reads.** A user with both Apple Calendar and Google Calendar linked plausibly wants the agent to see both. v1 forces a choice; v2 would let the resolution be a *set* for read-shaped capabilities, with results merged at the router.
- **Split-verb resolutions.** A user might trust Apple Calendar for reads but only want writes going to a specific Google Calendar shared with their partner. v1 forces both to the same provider; v2 would let each verb resolve independently.

When we revisit:
- The resolution shape becomes a map keyed by capability instead of a single `ProviderID`.
- The picker grows back the multi-select read variant from earlier drafts of this PRD.
- The router gains fan-out logic for read-shaped invocations, with partial-success error reporting.
- The capabilities manifest's `resolved` flag becomes per-capability instead of per-subject.

The v1 wire formats and persistence schema are designed so that the v2 expansion is additive (new optional fields), not a rewrite.

## Design decisions

1. **Resolver location**: lives in `ConvosCore/Sources/ConvosCore/CapabilityResolution/`. Pure core types, no UIKit. The card UI stays in the main app; the resolver vends data only.

2. **Mid-card provider link reactivity**: card refreshes in place via `CapabilityProviderRegistry.providerChanges: AsyncStream<ProviderChange>`. When the user taps "Connect," completes OAuth, and returns to the card, the new provider row appears without dismissing. SwiftUI view subscribes; no manual refresh needed.

3. **Unified runtime visibility**: solved by the [capabilities manifest](#runtime-capabilities-manifest). Both device and OAuth providers appear in `profile.metadata["capabilities"]`. The runtime reads this single key and learns about all subjects/providers/grants/resolutions across both systems.

4. **Agent `preferredProvider` hint**: honored. When the agent supplies a satisfiable hint, the client renders the Variant 1 confirmation card pointing at that provider. The user can still escape to Variant 2 to switch.

5. **`CapabilitySubject` vs `ConnectionKind`**: kept separate for v1.
   - `ConnectionKind` is the device-layer identity key inside `ConvosConnections` — routes payloads and invocations within that package; not all `ConnectionKind` values map cleanly to a user-facing subject (`.motion`, for example).
   - `CapabilitySubject` is the cross-system routing key — what the agent asks for; not all subjects have a `ConnectionKind` (`.tasks`, `.mail`).
   - Device providers carry both: `device.calendar` has subject `.calendar` and kind `.calendar`. OAuth providers carry only a subject.
   - Collapsing them would force OAuth providers to invent fake `ConnectionKind` values. Wrong direction.
   - Revisit once both systems route by `subject` at the wire layer.

6. **Single provider per (subject, conversation) for v1**: see [the scope cut](#v1-scope-cut-one-provider-per-subject-conversation). The simpler model lets us ship the routing surface and the manifest in one PR; federated reads and split-verb resolutions get their own PR once we have usage data.

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

When the user links both Apple Calendar and Google Calendar, three product behaviors are plausible:

1. **Pick one, every time.** User commits per conversation. Agent always knows where it's reading and writing. Simple, predictable, matches how users think about the question "which calendar?"
2. **Federate reads, single-target writes.** Reads merge across all linked calendars; writes target one chosen one. Maximizes the agent's information without the "which calendar did it land in?" trust problem.
3. **Per-verb selection.** Read from Apple, write to Google. Maximally flexible; maximally complex consent UI.

(2) and (3) are real asks, but the implementation cost is high (fan-out, merge logic, partial-success error shapes, multi-select picker UX, audit trail). v1 ships (1) because it's enough for almost every conversation an agent will have, and we can extend to (2) and (3) without rewriting the wire format.

The [Future](#future-federated-reads--split-verb-resolutions) section traces the path forward.
