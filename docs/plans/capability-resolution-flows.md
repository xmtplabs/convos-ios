# Capability Resolution: End-to-End User Flows

Companion to `docs/plans/capability-resolution.md`. That doc explains the *model*
(subjects, providers, resolutions, federation). This doc walks through what a
user actually sees, tap by tap, when an agent asks for something — for both a
device-backed provider (Apple Health, Apple Calendar, …) and a cloud-backed
provider (Composio: Strava, Google Calendar, …).

Both paths converge on the same wire contract: every request gets a
`capability_request_result` reply. What differs is where the linking work
happens (iOS framework prompt vs. OAuth web view) and which subsystem owns the
"is this provider linked" answer.

## The shared opening

1. **Agent sends a `capability_request`.**
   Wire type `convos.org/capability_request/1.0` carries `requestId`, `subject`,
   `capability` (read / writeCreate / writeUpdate / writeDelete), `rationale`,
   and an optional `preferredProviders` hint.
2. **Client persists the message.**
   `DecodedMessage+DBRepresentation.handleCapabilityRequestContent` writes a
   `DBMessage` row with `contentType = capabilityRequest`. The message is not
   surfaced in the conversation thread —
   `MessagesRepository` returns `nil` for that content type so the picker is
   the sole presentation.
3. **Repository observes and publishes.**
   `CapabilityRequestRepository.pendingRequestPublisher` runs a
   `ValueObservation` that walks the conversation's
   `capability_request` rows in descending `dateNs` and emits the first one
   whose `requestId` doesn't appear in any sibling
   `capability_request_result` row.
4. **View model recomputes the picker layout.**
   `ConversationViewModel.observeCapabilityRequests(for:)` subscribes; on each
   emission it calls
   `CapabilityRequestHandler.computeLayout(request:registry:resolver:conversationId:)`,
   which decides one of five variants
   (`.confirm` / `.singleSelect` / `.multiSelect` / `.connectAndApprove` /
   `.verbConsent`).
5. **`CapabilityPickerCardView` renders.**
   The card sits where the onboarding view normally lives at the bottom of the
   conversation — title `"Assistant wants to <verb> your <noun>"`, the agent's
   rationale verbatim, one row per relevant provider.

The picker dispatches three callbacks back to the view model: `onApprove`,
`onDeny`, `onConnect`. Approve and Deny terminate the request; Connect kicks
off one of the two flows below.

## Device connection flow (e.g. Apple Health)

This is the path for any provider whose id starts with `device.` —
`device.health`, `device.calendar`, `device.contacts`, etc. The "linked" state
maps to an iOS framework permission (HealthKit, EventKit, Contacts, …).

### Setup the user doesn't see

The session bootstrap registers the device-provider catalog into the
session-scoped `CapabilityProviderRegistry`:

- `SessionManager.bootstrapCapabilityProviders()` calls
  `CapabilityProviderBootstrap.registerDeviceProviders(...)` after
  `prewarmUnusedConversation`, with a stub `linkedByUser: { false }`. The
  registry now has every entry from
  `DeviceCapabilityProvider.defaultSpecs` — calendar, contacts, photos, health,
  music, location, homeKit, screenTime — with a known `subject`,
  `displayName`, `iconName`, optional per-provider `subjectNounPhrase`, and the
  set of verbs the device subsystem can fulfill.
- The Info.plist for each scheme (`Convos/Config/Info.{Dev,Local,Prod}.plist`)
  carries the matching usage descriptions
  (`NSHealthShareUsageDescription`, `NSCalendarsFullAccessUsageDescription`,
  …). HealthKit additionally needs the
  `com.apple.developer.healthkit` entitlement (declared in
  `Convos/Convos.entitlements`).

### What the user sees and taps

1. **Picker renders `.connectAndApprove`.**
   No provider is linked yet. Each row shows the provider icon + display name
   + a `Connect` capsule button. There's a single `Deny` button at the bottom.
   *No `Approve` button is offered* — connecting is the approval (see below).
2. **User taps `Connect` on Apple Health.**
   `CapabilityPickerCardView` calls `onConnect(provider.id)`. The view model's
   `onCapabilityConnect(providerId:)` parses the trailing `<kind>` off
   `device.<kind>` (`ConnectionKind.fromDeviceProviderId`), captures the
   originating `request` from the current layout, and dispatches a `Task`.
3. **OS prompt fires.**
   `session.deviceConnectionAuthorizer().requestAuthorization(for: kind)` is
   the indirection. `DefaultDeviceConnectionAuthorizer` instantiates the right
   `ConvosConnections` data source for the kind (`HealthDataSource`,
   `CalendarDataSource`, …) and calls its `requestAuthorization()`. iOS shows
   the system permission sheet.
4. **User grants (or denies) the permission.**
   The data source returns the resulting `ConnectionAuthorizationStatus`. We
   read `currentAuthorization(for: kind).canDeliverData` to get a single
   "linked yes/no" answer for the picker layer.
5. **Registry refresh.**
   The picker re-registers the provider in the registry with a `linkedByUser`
   closure that captures `(authorizer, kind)` and re-queries the live state on
   every read. (Importantly *not* a fixed Bool — that would go stale if the
   user later revokes access in Settings.) `register(_:)` replaces the
   provider by id and emits `.linkedStateChanged`.
6. **Auto-approve on success.**
   If the prompt was granted, the view model treats the Connect tap itself as
   the user's approval — they came to the card from a `capability_request`,
   just opted in, and there's no second decision to make. The model calls
   `approveCapabilityRequest(request, providerIds: [providerId])` against the
   request *captured in step 2* (not the current `pendingCapabilityPickerLayout`,
   which might have been swapped out by a newer request landing during the OS
   prompt).
   - If the prompt was declined, we instead recompute the layout so the user
     can pick a different provider or tap Deny. The picker stays visible.
7. **Resolver persistence + send.**
   `sendCapabilityResult` writes the resolution to GRDB
   (`GRDBCapabilityResolver.setResolution`) so future tool calls in this
   conversation can short-circuit to the same provider, then encodes a
   `CapabilityRequestResult` and posts it via the
   `CapabilityRequestResultWriter`
   (`client.conversation(with:).send(encodedContent:)`). The result is *always*
   posted, even if the local resolver write fails — the agent's contract is
   "every request gets a reply."
8. **Toast + dismiss.**
   On a successful approve send, the view model briefly shows
   `CapabilityApprovedToastView` ("Connection approved" with
   `checkmark.circle.fill`) for two seconds in the same area the picker
   occupied, then returns to the standard onboarding view.
9. **Repository fires nil.**
   The new `capability_request_result` row matches the request's `requestId`,
   so `CapabilityRequestRepository.pendingRequestPublisher` re-fires with
   `nil`. The view model's
   `locallyHandledCapabilityRequestIds` set already kept the picker dismissed
   between tap and result landing; this is the canonical end-of-flow.

### Subsequent requests in the same conversation

The resolver row from step 7 is durable. When the agent later asks for the
same `(subject, capability)` pair, `computeLayout` sees an existing resolution
and the picker doesn't re-surface; the agent's tool call routes directly. If
the agent asks for a *different* verb on the same subject, `verbConsentLayout`
short-circuits to a single-tap "Allow Apple Health to <new verb>?" card.

If the user later revokes the iOS permission in Settings, the registry's
`linkedByUser` closure (live) returns `false` next time it's polled — the
picker for any new request will reflect that and offer Connect again.

## Cloud connection flow (e.g. Strava, Google Calendar)

This is the path for any provider whose id starts with `composio.`, owned by
the cloud OAuth subsystem. The "linked" state maps to a row in the local
`DBCloudConnection` table, which mirrors a Composio entity managed by our
backend.

### Setup the user doesn't see

The cloud catalog is dynamic — the user has linked some subset, the rest are
just "available to add." Two pieces of state cooperate:

- `CloudConnectionRepository` (GRDB-backed) reads the list of currently linked
  cloud connections.
- `CapabilityProviderBootstrap.syncCloudProviders(connections:registry:)`
  diffs that list against whatever's currently registered under the
  `composio.` namespace. New connections register fresh
  `CloudCapabilityProvider`s; existing ones are refreshed; disconnected ones
  are unregistered. Called whenever the cloud connection list changes (link,
  unlink, status flip from `refreshConnections`).

The conventional time to register is on session bootstrap and after every
mutation in the connections-list UI. The unified `connections` metadata key on
each `ConversationProfile` is what the agent's runtime reads to know which
cloud grants apply per-conversation.

### Two entry points

There are two places a cloud connection gets created:

**A. From the picker, via Connect.**
Same trigger as device — agent asked for something, the picker has a
`composio.*` row that isn't linked yet, user taps Connect. The picker view
model hands off to a cloud-side handler analogous to
`DeviceConnectionAuthorizer` (this hand-off is the next piece of v1 work; the
device side ships first because Apple Health is the v1 federating example).

**B. Pre-emptively, from app settings.**
`Convos/App Settings/ConnectionsListView.swift` lets a user link any service
in `CloudConnectionServiceCatalog` from settings, before any agent asks. The
service rows live under `ConnectionsListViewModel.connect(serviceId:)`.

Both routes funnel into the same `CloudConnectionManager.connect(serviceId:)`.

### What the user sees and taps (Connect path)

1. **Tap Connect (or "Add" in settings).**
   `CloudConnectionManager.connect(serviceId:)` runs.
2. **Backend initiates.**
   `apiClient.initiateCloudConnection(serviceId:redirectUri:)` returns a
   one-shot `connectionRequestId` + a Composio OAuth URL. The redirect URI is
   `<appUrlScheme>://connections/callback` so iOS can deep-link back to the
   app.
3. **OAuth web view opens.**
   `OAuthSessionProvider.authenticate(url:callbackURLScheme:)` presents an
   `ASWebAuthenticationSession`. The user signs in to Strava / Google /
   whichever, grants scope, and the provider redirects back to our callback.
4. **Backend completes.**
   `apiClient.completeCloudConnection(connectionRequestId:)` swaps the
   one-shot id for the real `CloudConnection` (Composio entity id, connection
   id, status). The slug is normalized back to canonical via
   `CloudConnectionServiceNaming.canonicalService(fromComposioSlug:)`.
5. **Persist locally.**
   The `DBCloudConnection` row is written. Subsequent
   `refreshConnections()` calls or session bootstraps will re-read this and
   feed it through `syncCloudProviders` to the capability registry.
6. **Registry refresh.**
   The picker's view model calls `syncCloudProviders` (or the equivalent
   diff-and-register path) so the freshly-linked `composio.<service>` provider
   appears as `linkedByUser = true`. The picker re-renders.
7. **From here it merges with the device flow.**
   Same auto-approve-on-Connect treatment as device: on success we call
   `approveCapabilityRequest(request, providerIds: [providerId])` against the
   originally-captured request, persist the resolution, post the result, and
   show the toast.

### Why a *separate* per-conversation grant

Cloud connections have an extra wrinkle the device side doesn't: the user
might link Strava globally but only want a specific conversation to be able
to read it. That's `DBCloudConnectionGrant` plus `CloudConnectionGrantWriter`:

- Linking the connection (steps 1-6) populates `DBCloudConnection`.
- Approving the picker for a `(connection, conversation)` pair calls
  `connectionGrantWriter().grantConnection(connectionId, to: conversationId)`,
  which writes `DBCloudConnectionGrant` *and* publishes a `ProfileUpdate`
  message with the updated `connections` metadata so the agent's runtime sees
  the grant.
- Revoking via the conversation settings deletes the row and re-publishes a
  metadata payload without it.

The capability resolver and the grant-writer cooperate but live independently:
the resolver records the user's intent ("`fitness/read` in this conversation
routes to `composio.strava`"), the grant-writer carries the underlying
authorization the agent's runtime needs to actually invoke the connection.

If a user revokes the Composio grant entirely (in app settings → Connections
→ Remove), `CloudConnectionManager.disconnect` calls
`apiClient.revokeCloudConnection`, then republishes the affected
conversations' grant metadata (via the same per-conversation diff in
`CloudConnectionGrantWriter`) so the agent stops trying to use it. Any
resolver rows that referenced that provider get scrubbed via
`resolver.removeProviderFromAllResolutions(_:)`.

## Wire format

### Content types

| Direction | Content type                              | Carries |
|-----------|-------------------------------------------|---------|
| Agent → device | `convos.org/capability_request/1.0`        | `version`, `requestId`, `subject`, `capability`, `rationale`, optional `preferredProviders` |
| Device → agent | `convos.org/capability_request_result/1.0` | `version`, `requestId`, `status` (approved / denied / cancelled), `subject`, `capability`, `providers` (size 1 for non-federating; ≥1 for federating reads; empty on deny / cancel) |

Both codecs live in `ConvosCore/Sources/ConvosCore/Custom Content Types/`.
JSON-encoded payloads are stored as `DBMessage.text` so the result-matching
walk in `CapabilityRequestRepository` can decode them with a plain
`JSONDecoder` query.

### Payload examples

**Agent → device.** Asking for fitness reads, with a Composio hint:

```json
{
  "version": 1,
  "requestId": "req-2026-04-28-abc",
  "subject": "fitness",
  "capability": "read",
  "rationale": "To summarize your training week",
  "preferredProviders": ["composio.strava", "composio.fitbit"]
}
```

Asking for calendar writes (no hint, write verbs never federate):

```json
{
  "version": 1,
  "requestId": "req-2026-04-28-def",
  "subject": "calendar",
  "capability": "write_create",
  "rationale": "To add tomorrow's standup"
}
```

Subjects use the `CapabilitySubject` raw values
(`calendar | contacts | tasks | mail | photos | fitness | music | location | home | screen_time`).
Capabilities use `read | write_create | write_update | write_delete`.
`rationale` is rendered verbatim in the picker card and is hard-truncated to
500 characters on encode and decode. `preferredProviders` is hard-truncated
to 16 entries.

**Device → agent.** Approve, federating subject (`fitness`), single provider
selected:

```json
{
  "version": 1,
  "requestId": "req-2026-04-28-abc",
  "status": "approved",
  "subject": "fitness",
  "capability": "read",
  "providers": ["device.health"]
}
```

Approve, federating subject, multi-provider:

```json
{
  "version": 1,
  "requestId": "req-2026-04-28-abc",
  "status": "approved",
  "subject": "fitness",
  "capability": "read",
  "providers": ["composio.fitbit", "composio.strava", "device.health"]
}
```

Deny (and cancel — same shape, different status):

```json
{
  "version": 1,
  "requestId": "req-2026-04-28-def",
  "status": "denied",
  "subject": "calendar",
  "capability": "write_create",
  "providers": []
}
```

Provider IDs are stable: `device.<ConnectionKind.rawValue>` for iOS-framework
providers (`device.health`, `device.calendar`, `device.contacts`, …) and
`composio.<canonical_service_name>` for cloud providers
(`composio.strava`, `composio.google_calendar`, …). `providers` is sorted
ascending by raw value so the wire payload is deterministic.

## What a `convos-cli` agent sees

The `convos agent serve` command runs a long-lived ndjson session:
events stream out of stdout, commands go in on stdin (see the convos-cli
SKILL doc for the full agent protocol). Capability requests are sent and
received as messages with custom content types — the agent observes them via
the same `message` events it would for text or reactions.

### Agent sends a request

The agent doesn't have to construct the JSON or pick a content type by hand —
the CLI exposes a dedicated subcommand:

```bash
convos conversation send-capability-request <conversation-id> \
  --subject fitness \
  --capability read \
  --rationale "To summarize your training week" \
  --preferred-providers composio.strava,composio.fitbit \
  --request-id req-2026-04-28-abc \
  --json
```

`--request-id` is optional; the CLI mints a random one if omitted. The agent
stashes it locally so it can correlate the eventual reply.

### Agent observes the reply

While `convos agent serve` is running the agent receives every conversation
message as a `message` event on stdout. A `capability_request_result` lands
as:

```json
{
  "event": "message",
  "id": "ae41f0705f3f8067bd30a5406977e64d320262ee178db157432021412a9e22be",
  "senderInboxId": "8b706fde5719bf9060ec2363cf8faed9ead642ce962f7fb047a2cc326577bc72",
  "senderProfile": { "name": "Jarod" },
  "contentType": {
    "authorityId": "convos.org",
    "typeId": "capability_request_result",
    "versionMajor": 1,
    "versionMinor": 0
  },
  "content": "{\"version\":1,\"requestId\":\"req-2026-04-28-abc\",\"status\":\"approved\",\"subject\":\"fitness\",\"capability\":\"read\",\"providers\":[\"device.health\"]}",
  "sentAt": "2026-04-28T15:24:43.938Z"
}
```

The agent's job is:

1. Filter events to `event == "message"` and
   `contentType.typeId == "capability_request_result"`.
2. JSON-decode `content` and pick out `requestId` to find the in-flight
   request it correlates with.
3. Branch on `status`:
   - `approved` → invoke the matching tool. For federating subjects (`fitness`
     reads), the agent should iterate `providers` and combine results; for
     non-federating subjects or any write, `providers` has size 1.
   - `denied` / `cancelled` → tell the user the request was declined and
     stop.

### Sketch: minimal end-to-end agent loop

```bash
convos agent serve --name "Coach" --profile-name "Coach" | while IFS= read -r event; do
  type=$(echo "$event" | jq -r '.event')
  case "$type" in
    ready)
      conv=$(echo "$event" | jq -r '.conversationId')
      # Ask the user to authorize fitness reads:
      convos conversation send-capability-request "$conv" \
        --subject fitness --capability read \
        --rationale "I'd like to summarize your training week." \
        --request-id req-week-summary
      ;;
    message)
      tid=$(echo "$event" | jq -r '.contentType.typeId')
      if [ "$tid" = "capability_request_result" ]; then
        result=$(echo "$event" | jq -r '.content')
        rid=$(echo "$result" | jq -r '.requestId')
        status=$(echo "$result" | jq -r '.status')
        providers=$(echo "$result" | jq -r '.providers | join(",")')
        if [ "$rid" = "req-week-summary" ] && [ "$status" = "approved" ]; then
          # … invoke the matching tool against $providers, then send the
          # summary as a normal text message via stdin:
          printf '%s\n' '{"type":"send","text":"On it — pulling your week now."}'
        elif [ "$rid" = "req-week-summary" ]; then
          printf '%s\n' '{"type":"send","text":"No worries, I won'\''t look."}'
        fi
      fi
      ;;
  esac
done
```

The `send-capability-request` subcommand returns once the request message has
been published. The reply lands asynchronously when the user approves /
denies / connects-and-approves on the device side. There is no polling; the
agent just keeps reading from `convos agent serve`'s stdout. (Reconnects auto-
catchup, so a transient disconnect during the OS prompt won't drop the
result.)

### Inspecting on the side

When iterating, dumping the current capability traffic in a conversation is
useful:

```bash
convos conversation messages <conversation-id> \
  --sync \
  --content-type custom \
  --json
```

…then `jq` over `.[] | select(.contentType.typeId | startswith("capability_"))`
to see the back-and-forth. The same content-type filter works on
`convos conversation stream` for live tailing.

## State ownership at a glance

| Concern | Source of truth |
|---------|-----------------|
| Which providers exist for which subject (this session) | `CapabilityProviderRegistry` (in-memory) |
| Whether a device permission is granted | iOS framework, queried live by `DeviceCapabilityProvider.linkedByUser` |
| Whether a cloud OAuth grant exists | `DBCloudConnection` (mirrored from Composio via backend) |
| Which provider the user picked for `(subject, conversation, capability)` | `DBCapabilityResolution` |
| Per-conversation cloud grant | `DBCloudConnectionGrant` (+ published `ProfileUpdate.metadata.connections`) |
| Which `capability_request` is still unanswered | computed on the fly by `CapabilityRequestRepository` (no separate table) |

The picker view model is intentionally stateless across requests — the only
local UI bookkeeping is `latestObservedCapabilityRequest` (race-discard for
out-of-order layout completions) and `locallyHandledCapabilityRequestIds`
(keeps the picker dismissed between tap and result-row-landing).
