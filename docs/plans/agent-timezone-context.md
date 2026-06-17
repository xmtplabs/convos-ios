# Design: Give a Convos AI agent the user's time zone, invisibly

Date: 2026-06-17
Status: Draft

Goal: when a user adds an AI agent (e.g. "Kai") to a conversation, the agent
should know the user's IANA time zone (so it answers "what time is it" / "remind
me at 9am" correctly and handles DST) without any visible chat message.


## 1. iOS availability + what to send

YES -- iOS gives this for free, no permission, no entitlement, no prompt.

  - IANA identifier (the only payload we send):
        TimeZone.current.identifier            // e.g. "Europe/Paris"

None of this touches CoreLocation / CLLocationManager, so there is no
`NSLocationWhenInUseUsageDescription` requirement and no system permission
dialog. It reads the device's regional settings synchronously, on the main
thread, with zero authorization. This is categorically different from GPS.

What to send and why (decision: Q4):

  - Send only the IANA identifier ("Europe/Paris"). Nothing else.
  - We do not send a UTC offset, a seconds-from-GMT snapshot, or a local
    timestamp at send time. The identifier alone lets the agent compute the
    correct local time for any date and handle daylight-saving transitions
    itself, so the offset/seconds/local-time companions are redundant: the
    agent derives them from the identifier on its side. A bare "+02:00" offset
    is only correct until the next DST change and is useless for scheduling, so
    there is no reason to carry it.
  - We also do not send `locale`. The IANA identifier is the agent's source of
    truth for time-relative reasoning; locale-based formatting (12h/24h) is out
    of scope for this change.

Privacy framing: a time zone is low-sensitivity but it is coarse location
(continent / multi-country band). It is shared silently, with no user-facing
prompt; this is a deliberate, documented product decision. See section 5.


## 2. Two-channel design: join-request default + per-sender ProfileUpdate

The design uses two complementary channels for different purposes:

  - **Channel A -- agents/join request body (new):** the conversation creator's
    IANA timezone is included in the HTTP join request. The agent runtime uses
    this as its default timezone from the moment the agent joins, replacing the
    hardcoded Eastern fallback. One-shot at join time; covers the common case
    immediately.
  - **Channel B -- per-sender ProfileUpdate.metadata (existing pattern):** each
    member's timezone is kept current via the existing per-sender profile
    publish. This handles ongoing updates: travel, DST, per-member differences
    in group conversations, and any republish after the initial join.

Both channels carry the same IANA identifier string. The join-request value
seeds the default; the ProfileUpdate values are the ongoing source of truth per
sender.


### Channel A: agents/join request body (creator default timezone)

The join request body is `ConvosAPI.AgentJoinRequest`:
    ConvosCore/Sources/ConvosCore/API/ConvosAPIClient+Models.swift:170-180
        slug: String, templateId: String?, options: AgentJoinOptions?
Construction choke point (single place to add a field):
    ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift:760-781

Add a `creatorTimezone` field to `AgentJoinRequest`:
    public let creatorTimezone: String?
populated at the call site with `TimeZone.current.identifier`. This requires a
coordinated backend change: the `v2/agents/join` endpoint must accept the new
field and the agent runtime must use it as the initial default instead of the
hardcoded `USER_TIMEZONE` / `"America/New_York"` value
(agent_runner.py:52-57, see section 7).

Rationale: the join endpoint is the agent's first contact with the conversation.
Getting the creator's timezone at join time means the agent answers correctly
from the very first turn, even before the ProfileUpdate channel has delivered
a per-sender value. This replaces a hardcoded Eastern default with a real value
for most conversations (where the creator is the primary user). The creator's
timezone is the right default because the creator is also the one who invites
the agent and typically the primary participant.

One-shot constraint: the join-request value is set once at join time. It does
not update for DST or travel -- that is Channel B's job. The runtime should
prefer a per-sender ProfileUpdate value when present, and fall back to the
join-request default when the per-sender map has no timezone key yet.


### Channel B: per-sender ProfileUpdate.metadata map (ongoing per-member)

The cleanest ongoing channel is the existing per-sender `ProfileUpdate.metadata`
map -- a `map<string, MetadataValue>` that the client already publishes per
conversation and that the server-side agent/runtime can read per sender.

Evidence:
  - Proto definition (arbitrary string keys):
      ConvosCore/Sources/ConvosCore/Profiles/Proto/profile_messages.proto:25-30
        message ProfileUpdate {
            optional string name = 1;
            optional EncryptedProfileImageRef encrypted_image = 2;
            MemberKind member_kind = 3;
            map<string, MetadataValue> metadata = 4;   // arbitrary keys
        }
  - Swift type:
      ConvosCore/Sources/ConvosCore/Profiles/ProfileMessages/ProfileMessageHelpers.swift:63-84
        public typealias ProfileMetadata = [String: ProfileMetadataValue]
        // ProfileMetadataValue == .string | .number | .bool
  - It is not rendered as a chat message: ProfileUpdate is a custom XMTP content
    type (ProfileUpdateCodec) consumed as profile state, never composed into the
    message list.
  - It is the same per-sender map iOS already uses for the `connections` key.
    iOS publishes connection grants there today via the same publish primitive:
      ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift:89
        "The runtime reads grants from `profile.metadata.connections` per sender."
    (On the runtime side this surfaces as the per-member metadata map; see
    section 7 for the exact read surface and a correction to that comment's
    optimistic phrasing.)
  - It is per-sender and spoof-resistant (sender is the XMTP message author, not
    a self-asserted field), unlike a shared group blob.

So a timezone is just one more key in the same per-sender map:
    metadata["timezone"] = .string("Europe/Paris")

### Exact client insertion point (Channel B)

The publish primitive already exists and is the single choke point:

    ConvosCore/Sources/ConvosCore/Storage/Writers/MyProfileWriter.swift:85
        func updateAndPublish(metadata: ProfileMetadata?, conversationId: String) async throws

This:
  - merges metadata into the sender's DBMemberProfile (line 92-103),
  - sends the ProfileUpdate over XMTP (line 104, sendProfileUpdateThrowing),
  - best-effort mirrors it into appData (line 106, group.updateProfile).

The exact pattern to copy is how `connections` is published today:

    ConvosCore/Sources/ConvosCore/CloudConnections/CloudConnectionGrantWriter.swift:472-495
        var merged: ProfileMetadata = existingMetadata ?? [:]
        merged[Constant.connectionsKey] = .string(grantsJson)        // line 486
        try await myProfileWriter.updateAndPublish(
            metadata: merged.isEmpty ? nil : merged,
            conversationId: conversationId
        )                                                            // lines 491-494

Recommended insertion: a tiny new writer (or a method on an existing profile
writer) that mirrors lines 484-494 but sets `merged["timezone"] =
.string(TimeZone.current.identifier)`, scoped and triggered per the scope and
refresh rules below.

### Scope: agent conversations only (decision: Q1)

Publish the timezone (Channel B) only in conversations that contain an agent
member. Do not publish it in human-only conversations: a time zone has no
purpose for human peers and should not leak to them. The agent-join sites are
the natural place to detect "this conversation has an agent":
  - In-conversation / Agent Builder join:
      Convos/Agent Builder/AgentBuilderViewModel.swift:784 and :996
      (calls session.requestAgentJoin(...))
  - Generic join path:
      Convos/Conversation Detail/ConversationViewModel.swift:3584 requestAgentJoin(templateId:)
        -> performAgentJoinCall (ConversationViewModel.swift:3827)
        -> SessionManager.requestAgentJoin (ConvosCore/.../Sessions/SessionManager.swift:599)

Publish the timezone ProfileUpdate right after a successful join returns (so it
lands once the agent is a member and will sync it). For republish (below), gate
on the conversation already having an agent member so human-only conversations
are never touched.

### Refresh: republish opportunistically and on agent-join, foreground main app only (decision: Q2)

Republish the timezone (Channel B) in two situations, so travel and DST changes
stay current:
  - when an agent joins a conversation (the initial publish above), and
  - opportunistically on app foreground, for conversations that already contain
    an agent.

Concrete trigger and throttle for opportunistic republish:
  - Trigger: in `SceneDelegate.sceneDidBecomeActive(_:)`, enqueue a
    low-priority `Task` that iterates all agent conversations and republishes
    after a short delay (e.g. 5 seconds) to let the app settle first.
  - Throttle: only republish for a given conversation if
    `TimeZone.current.identifier` differs from the last published value for
    that conversation. Persist the last-published identifier in `UserDefaults`
    (or an `@AppStorage`-backed property) keyed by conversation ID, so the
    check survives session restarts.
  - Session state: track a per-session boolean flag (`hasRepublishedTimezone`)
    so the app republishes at most once per foreground session even if the
    user background-foregrounds the app repeatedly.

Critical constraint -- single serialized writer to avoid clobbering the map:
the `ProfileUpdate.metadata` map is per-sender, but a publish rewrites the
whole merged map for that sender (read existing -> merge key -> publish). Two
async tasks in the same app process can interleave on this read-merge-write
sequence: a timezone publish and a `connections` publish in
`CloudConnectionGrantWriter` both perform a non-atomic read-merge-write against
the same `DBMemberProfile`. If they overlap, the later write overwrites the
earlier with a stale copy of the key the other task just set -- silent data
loss. To prevent this, all metadata map writes for the same sender/conversation
must be serialized through a single shared `ProfileMetadataWriter` actor (not
just the cross-process process-level constraint below).

The implementation approach: introduce `ProfileMetadataWriter` as a
`@MainActor public final class` in
`ConvosCore/Sources/ConvosCore/Storage/Writers/ProfileMetadataWriter.swift`.
It owns the single choke point: read existing metadata, apply a caller-supplied
closure that mutates the map, then call `myProfileWriter.updateAndPublish`.
Both the existing connections code (`CloudConnectionGrantWriter`) and the new
timezone code must go through this shared instance -- they must not call
`myProfileWriter.updateAndPublish` directly. Because the class is
`@MainActor`-bound, all reads and writes are serialized on the main actor;
concurrent callers queue behind each other automatically. See section 4 for
the concrete actor pattern and both call sites.

In addition, to keep writes to the foreground main app:

  - Publish the timezone only from the foregrounded main app.
  - Never publish it from the Notification Service Extension.
  - Never publish it from a background task / background refresh.

The foreground-only constraint prevents cross-process races (NSE vs. main app).
The actor/serial-queue constraint prevents intra-process races between the
timezone writer and the connections writer running concurrently in the same app.
The cost is only that a timezone change made while the app is backgrounded is
picked up on the next foreground interaction rather than instantly -- acceptable,
since the IANA identifier already lets the agent handle DST without any client
update, and travel is reflected the next time the user opens the app.


### Other alternatives considered

ALT B -- a typed field on ConversationCustomMetadata.
    Proto: ConvosAppData/Sources/ConvosAppData/Proto/conversation_custom_metadata.proto:15-25
    Write path: ConvosCore/.../Invites & Custom Metadata/XMTPGroup+CustomMetadata.swift:357,397
    Why it loses:
      - It is a statically-typed protobuf with no map field; you must add a new
        numbered field and regenerate -> proto change + backend decode change.
      - It is a shared, conversation-scoped 8KB blob (per-sender data only via the
        profiles[] array), and the code itself treats appData as a best-effort
        secondary mirror, not the agent's primary read path. More invasive, less
        idiomatic, same backend dependency.

ALT C -- a dedicated hidden custom content type (a "system message").
    The codebase has a family of mostly-non-rendered custom content types
    (MessageContentType: ConvosCore/.../Storage/Models/MessageContentType.swift:5-16;
    most set shouldPush=false; filtered from previews in
    DBConversation.swift:189-235 and from rendering in
    MessagesRepository.swift:507-561). assistantJoinRequest is the closest analog.
    Why it loses:
      - Highest effort: new codec + decode + runtime routing + a guarantee it
        never renders. The ProfileUpdate.metadata map already gives you a
        non-rendered, agent-read channel with zero new content types.


## 3. The backend / agents contract needed

Reality check: iOS can only send. The agent runtime is server-side (the
convos-assistants repo: Herald + the Hermes runtime), not in this repo, so the
agent must be taught to consume the value. The two halves:

(a) What iOS can do alone (ships independently, after the backend accepts the
    new join field):
    - Channel B: Read TimeZone.current.identifier and publish it as
      metadata["timezone"] on the per-sender ProfileUpdate via
      MyProfileWriter.updateAndPublish, scoped to agent conversations and
      written only from the foreground main app (sections above). This rides the
      existing ProfileUpdate channel, so the data physically reaches the runtime
      with no new endpoint or schema. It is also stored locally on
      DBMemberProfile so it is durable and refreshable.
    - This means the bytes arrive even before the backend does anything with them;
      the agent simply ignores an unknown key until taught.

(b) What requires backend contract changes:
    - Channel A: The `v2/agents/join` endpoint must accept a `creatorTimezone`
      field in the request body. The agent runtime must store
      this value and use it as the per-conversation default timezone instead of
      the hardcoded `"America/New_York"` / `USER_TIMEZONE` env value
      (agent_runner.py:52-57). This is a required coordinated change -- the iOS
      side can add the field to `AgentJoinRequest` but the value has no effect
      until the backend reads it.
    - Channel B: The agent runtime must read metadata["timezone"] for the human
      member and fold it into its context / system prompt (e.g. "The user's time
      zone is Europe/Paris; interpret relative times accordingly"). Concrete
      proposal in section 7.
    - Both changes are additive and do not break existing readers.

Minimal contract (write it down once, both sides agree):

Note on field name vs. metadata key: the join-request field is named
`creatorTimezone` (it carries the creator's timezone and is unambiguously
creator-scoped). The per-sender ProfileUpdate metadata map key is `"timezone"`
(it is a map key, not a struct field; it is keyed per sender, so there is no
ambiguity about whose timezone it is). These are two different names for two
different channels -- do not conflate them.

  Join-request field (Channel A):
    Field:    "creatorTimezone" in AgentJoinRequest JSON body
    Value:    IANA tz database identifier, e.g. "Europe/Paris". Optional; absent
              means the backend falls back to its existing default.
    Semantics: used by the agent runtime as the conversation's initial default
              timezone. Superseded per-turn by any ProfileUpdate value present
              for the message sender (Channel B).
    Backend:  store per-conversation (e.g. alongside agent slug / templateId);
              feed into agent context at join and on each turn as the fallback.

  Per-sender metadata (Channel B):
    Channel:  per-sender ProfileUpdate.metadata map (XMTP), key "timezone".
    Key:      "timezone"   (string)
    Value:    IANA tz database identifier, e.g. "Europe/Paris". Required when
              present; no companion keys.
    Semantics: latest ProfileUpdate wins; absence = unknown, agent falls back to
              join-request default (Channel A), then UTC.
    Writer:   the foreground main app only; never the NSE or a background task;
              all writes go through the shared `ProfileMetadataWriter` actor to
              prevent concurrent read-merge-write races with other metadata
              writers (e.g. connections).
    Agent behavior: parse the IANA id with its own tz library; do not trust any
              offset for future dates (recompute from the identifier so DST is
              correct). On a malformed/unknown id, degrade gracefully (treat as
              unknown / fall back to join-request default or UTC).


## 4. Minimal client-side implementation sketch

### Channel A (join request)

Add `creatorTimezone: String?` to `ConvosAPI.AgentJoinRequest`
(ConvosCore/Sources/ConvosCore/API/ConvosAPIClient+Models.swift:170) and
populate it at the construction choke point
(ConvosAPIClient.swift:775-780):

    ConvosAPI.AgentJoinRequest(
        slug: slug,
        templateId: templateId,
        options: options,
        creatorTimezone: TimeZone.current.identifier
    )

This is a single-line addition at the one construction site. The field is
optional / nil-omitted by Codable, so existing callers and tests need no change
and the wire format stays backward-compatible until the backend reads the field.

### Channel B (per-sender ProfileUpdate)

The race-safe implementation requires a shared actor that serializes all
metadata map writes. Introduce `ProfileMetadataWriter` as the single choke
point. Both the existing connections code and the new timezone code must use
it -- neither should call `myProfileWriter.updateAndPublish` directly.

Sketch (not committed; file path and type signatures are illustrative):

    // ConvosCore/Sources/ConvosCore/Storage/Writers/ProfileMetadataWriter.swift
    @MainActor
    public final class ProfileMetadataWriter {
        private let myProfileWriter: MyProfileWriter
        private let databaseReader: DatabaseReaderProtocol

        // Single choke point for all metadata map writes.
        // @MainActor serializes concurrent callers; the closure makes
        // read-modify-write atomic from each caller's perspective.
        public func updateMetadata(
            conversationId: String,
            inboxId: String,
            update: @escaping (inout ProfileMetadata) -> Void
        ) async throws {
            let existing = try await databaseReader.read { db in
                try DBMemberProfile.fetchOne(
                    db, conversationId: conversationId, inboxId: inboxId
                )?.metadata
            }
            var merged: ProfileMetadata = existing ?? [:]
            update(&merged)
            try await myProfileWriter.updateAndPublish(
                metadata: merged.isEmpty ? nil : merged,
                conversationId: conversationId
            )
        }
    }

Connections caller (CloudConnectionGrantWriter refactored to use the actor):

    // Replaces the direct myProfileWriter.updateAndPublish call at
    // CloudConnectionGrantWriter.swift:472-495.
    try await profileMetadataWriter.updateMetadata(
        conversationId: conversationId,
        inboxId: senderId
    ) { metadata in
        if let grantsJson {
            metadata[Constant.connectionsKey] = .string(grantsJson)
        } else {
            metadata.removeValue(forKey: Constant.connectionsKey)
        }
    }

Timezone caller (new timezone publish code):

    // Capture TimeZone.current.identifier on the main actor before any async
    // hop, then pass the captured value into the closure.
    @MainActor let currentTimezone = TimeZone.current.identifier
    try await profileMetadataWriter.updateMetadata(
        conversationId: conversationId,
        inboxId: myInboxId
    ) { metadata in
        metadata["timezone"] = .string(currentTimezone)
    }

Why this works:
  - `@MainActor` on `ProfileMetadataWriter` means every `updateMetadata` call
    runs on the main actor. Concurrent callers are queued behind each other by
    the Swift concurrency runtime -- no two read-merge-write sequences can
    interleave.
  - The closure-based API makes the read-modify-write atomic from each caller's
    perspective: the caller only describes what key(s) to set; the actor owns
    the read and the publish.
  - Both the `connections` key and the `timezone` key funnel through one choke
    point, so a connections publish and a timezone publish cannot race.

Call the timezone variant right after a successful agent join, at the join
sites in section 2, and on opportunistic foreground refresh for conversations
that already contain an agent. Gate every call on:
  - the conversation contains an agent member (scope, Q1), and
  - the caller is the foreground main app (single-writer, Q2) -- do not wire
    this into the Notification Service Extension or any background path.
Keep it best-effort (log on failure; do not block the join).

Note: ProfileMetadataValue currently supports .string / .number / .bool only
(ProfileMessageHelpers.swift:63-84) -- the IANA id as .string fits cleanly.


## 5. Privacy note

  - No permission is requested or required, and there is no user-facing toggle
    or opt-in (decision: Q6). The timezone is shared silently in agent
    conversations. This is an intentional, documented product decision for a
    low-sensitivity value, not an accident.
  - A time zone is coarse location (it reveals roughly which part of the world
    the user is in). It is far less precise than GPS but it is not "nothing", so
    it should be documented in agent/privacy copy ("agents you add can see your
    time zone so they can answer time questions correctly").
  - The share is scoped to agent conversations only and never reaches human-only
    conversations (Q1). The channel is per-sender and spoof-resistant, and rides
    existing encrypted XMTP transport, so there is no new exposure beyond the
    value itself.
  - If the user changes time zone (travel) or DST flips, re-publishing on next
    foreground interaction keeps the agent current; the IANA id means the agent
    handles DST without any further client update.


## 6. Resolved decisions (formerly open questions)

  1. Scope of publish -- RESOLVED. Publish the timezone only in conversations
     that contain an agent member, never in human-only conversations. The
     agent-join sites (section 2) are the trigger / detection point. (Folded into
     section 2 "Scope" and section 5.)
  2. Refresh + race avoidance -- RESOLVED. Republish opportunistically (app
     foreground via `sceneDidBecomeActive`, throttled by last-published value in
     UserDefaults and a per-session flag) and when an agent joins. To avoid
     concurrent edits clobbering the per-sender metadata map:
     (a) write only from the foregrounded main app (cross-process constraint:
         never from the Notification Service Extension or a background task);
     (b) route all metadata map writes for a given sender/conversation through
         a single shared `ProfileMetadataWriter` `@MainActor` actor (intra-
         process constraint: prevents a timezone publish and a connections
         publish from racing on the non-atomic read-merge-write sequence).
         A shared `ProfileMetadataWriter` instance is the required mechanism --
         not just "any actor or serial queue." `CloudConnectionGrantWriter` must
         be refactored to use it for the `connections` key, and the timezone
         code must use it for the `timezone` key. The foreground-only constraint
         alone is not sufficient -- two async tasks in the same foreground app
         can still interleave. (Folded into section 2 "Refresh" and section 4.)
  3. Backend ownership / agent contract -- RESOLVED with a concrete proposal.
     Two halves: (a) join-request default: the `v2/agents/join` endpoint accepts
     a `creatorTimezone` field; the runtime uses it as the per-conversation
     default instead of the hardcoded `"America/New_York"`. (b) per-sender read:
     the runtime reads metadata["timezone"] for the human member and folds it
     into the agent context. See section 7 for the proposed read site,
     validation, injection point, absence handling, and per-turn re-read.
     Confirm the key name and semantics with the agents team before the iOS side
     ships.
  4. Payload / companion keys -- RESOLVED. Send only the IANA identifier (e.g.
     "Europe/Paris"). Drop the optional UTC offset / tzOffsetSeconds /
     local-time-at-send and locale -- the agent derives anything else it needs
     from the identifier. (Folded into section 1 "What to send".)
  5. Value type (IANA-id-as-string acceptable; malformed ids must degrade
     gracefully) -- ACCEPTED as proposed. IANA-id-as-string is fine; there is no
     enum/validation on the wire today, so a malformed id just fails to parse
     agent-side and the agent treats it as unknown (defaults to UTC). No change
     to the proposal. (Reflected in the section 3 contract and section 7.)
  6. Consent surface -- RESOLVED. No explicit user-facing toggle / opt-in. The
     timezone is shared silently in agent conversations; the share is documented
     in privacy copy but there is no opt-in control. (Folded into section 5.)


## 7. Agent runtime handling (convos-assistants)

This section is the required server-side half (Q3). It covers both the
join-request default (Channel A) and the per-sender per-turn read (Channel B).
It is a suggestion -- paths plus approach, not a prescriptive diff. iOS can
only put the bytes on the wire; without this, adding metadata["timezone"] on
iOS has no observable effect.

The agent runtime lives in the convos-assistants repo (a TypeScript pnpm
monorepo for the workers/webhooks; the agent reasoning runtime "Hermes" is
Python under runtime/hermes/). Read-only investigation; nothing modified.

### How an incoming message is processed (entry points)

  - The Cloudflare worker receives the Herald webhook and enqueues it to a
    Durable Object:
      workers/assistant/src/api/webhooks/herald.ts (handler ~lines 64-200).
      No profile data is extracted at this boundary -- it forwards the envelope.
  - The Python runtime dispatches the webhook and handles the message:
      runtime/hermes/src/convos/herald/runtime.py
        handle_webhook(...)            ~line 422  (dispatch by event_type)
        _handle_message(payload, ...)  ~lines 450-531  (parses MessageEvent,
                                       builds the InboundMessage)
  - The message is then formatted and run through the agent:
      runtime/hermes/src/server/agent_runner.py
        _format_envelope(...)          ~lines 892-919  (builds the per-message
                                       header string the model sees)

### The existing hardcoded timezone default (Channel A target)

The runtime currently hardcodes a default zone at process start:
    runtime/hermes/src/server/agent_runner.py:52-57
        _tz_name = os.environ.get("USER_TIMEZONE", "America/New_York")
        try:
            _USER_TZ = ZoneInfo(_tz_name)
        except KeyError:
            logger.warning("Unknown timezone %r - falling back to UTC", _tz_name)
            _USER_TZ = timezone.utc
`_USER_TZ` is consumed in `_format_envelope` (agent_runner.py:909-910) to
render the current time and message timestamp into the header the model sees
("[Current time: Thu, Mar 20, 2026, 10:30 AM EDT]").

Channel A change: when the `v2/agents/join` request includes `creatorTimezone`
(an IANA identifier string, e.g. `"Europe/Paris"`), the runtime stores it
per-conversation and uses it as the default `ZoneInfo` in `_format_envelope`
for that conversation, replacing the process-wide `_USER_TZ`. This means the
agent answers with the right timezone from the very first turn, before any
ProfileUpdate has been delivered. The existing `ZoneInfo(name)` + `except` ->
UTC fallback already doubles as IANA validation.

### Where per-sender profile metadata lives today (Channel B read surface)

A correction to the optimistic phrasing in
XMTPGroup+CustomMetadata.swift:89: in this runtime, the inbound webhook's
sender-profile object only declares name/image, and `_handle_message` currently
reads only the sender's name:
  - runtime/hermes/src/herald_client/models/sender_profile.py: SenderProfile
    declares only `name` and `image`; any extra keys land in
    `additional_properties` and are not surfaced as a typed metadata map.
  - runtime/hermes/src/convos/herald/runtime.py:460-463 extracts only
    `event.sender_profile.name` for the inbound message; the metadata map on the
    webhook envelope is not read.

The per-sender metadata map does exist on the runtime's resolved profiles, which
is the correct place to read a `timezone` key:
  - The per-member cache row carries a metadata map:
      runtime/hermes/src/convos/herald/cache.py
        class MemberProfile(BaseModel):
            name: str | None = None
            description: str | None = None
            imageUrl: str | None = None
            metadata: dict[str, str] = {}        # <- the per-sender map
  - The runtime resolves member profiles from Herald and can read each member's
    metadata fields. The own-profile path already demonstrates the exact
    name -> value extraction pattern a human-member read would mirror:
      runtime/hermes/src/convos/herald/runtime.py:768-783
        async def get_own_profile_metadata(self) -> dict[str, str]:
            profiles = await self._herald.list_member_profiles()
            for profile in profiles:
                if not getattr(profile, "is_me", False):
                    continue
                fields = getattr(profile, "metadata", None)
                ...
                return {field.name: str(field.value) for field in fields}
  - The same `list_member_profiles()` call already runs during the metadata
    refresh (runtime.py:316). Today it only copies `name` into the cache
    (runtime.py:330-332, `MemberProfile(name=name)`); it drops the metadata map.
    The first change is to also copy each member's metadata fields into
    `MemberProfile.metadata` there, so the per-sender map is available
    downstream.

So the concrete "read metadata['timezone'] for the human member" spot is: in
`_refresh_metadata_if_stale` (runtime.py:329-332) populate
`MemberProfile.metadata` from each resolved profile's metadata fields (mirroring
the `get_own_profile_metadata` extraction at runtime.py:780-783), then, for the
human sender of the current message, look up
`member_profile.metadata.get("timezone")`.

### Where the timezone gets injected into the agent context (both channels)

At message-format time in `_format_envelope` (agent_runner.py:892-919),
resolve the timezone in priority order:

  1. Per-sender ProfileUpdate value (Channel B): look up the human sender's
     `member_profile.metadata.get("timezone")`. If present and a valid IANA id,
     use it. This is the per-turn, per-member source of truth; it reflects travel
     and DST updates.
  2. Join-request default (Channel A): if no per-sender value is present, use
     the `creatorTimezone` value stored at join time for this conversation (the
     `creatorTimezone` field sent in the `v2/agents/join` request body).
  3. Process-wide fallback: if neither is present, use the existing `_USER_TZ`
     (the `USER_TIMEZONE` env var, defaulting to UTC).

Build a per-message `ZoneInfo` from whichever value wins (reusing the existing
`ZoneInfo(name)` + `except` -> UTC fallback at agent_runner.py:52-57). Add an
explicit line to the agent context / system prompt so the model reasons about
relative times correctly, e.g.:
    "[User timezone: Europe/Paris]"
appended in the same header `_format_envelope` builds, or folded into the
platform system prompt assembled per turn (the platform prompt is reloaded
each turn at agent_runner.py around line 1091, so a per-turn value is
naturally honored).

### Absence and validation handling

  - Absent key (both channels): omit the "[User timezone: ...]" line and fall
    back to the next priority level (Channel A default, then UTC). The agent
    must not assume a zone when none is present.
  - Malformed / non-IANA value: caught by the existing `ZoneInfo(...)` ->
    `except` -> UTC fallback; treat as unknown and fall back to the next
    priority level. No enum or wire validation is expected from iOS (Q5).

### Re-read on each turn (travel / DST)

Read the human member's `metadata["timezone"]` per turn rather than caching it
once for the session, so a republished value (the user traveled, or the app
republished on foreground) is picked up mid-conversation. The metadata refresh
already has a TTL (`_refresh_metadata_if_stale`, runtime.py:309-313); resolving
the timezone from the (refreshed) per-member cache at envelope-format time means
each turn uses the latest published value. The IANA identifier means DST is
handled by `ZoneInfo` without any further client publish. The join-request
default (Channel A) is immutable once set -- it does not change when the user
travels; the per-sender ProfileUpdate (Channel B) supersedes it when present.

### Summary of the server-side changes

  Channel A (join-request default):
  1. Accept `creatorTimezone` (optional IANA identifier string) in the
     `v2/agents/join` request body. Store it per-conversation in the agent's
     context store.
  2. In `_format_envelope` (agent_runner.py:892-919), use the stored
     `creatorTimezone` as the fallback zone when no per-sender metadata value is
     present (replacing the process-wide `_USER_TZ` for conversations where a
     creator timezone was supplied).

  Channel B (per-sender metadata):
  1. In `_refresh_metadata_if_stale` (runtime.py:329-332), copy each resolved
     member's metadata fields into `MemberProfile.metadata` (pattern:
     get_own_profile_metadata, runtime.py:780-783).
  2. At message-format time (`_format_envelope`, agent_runner.py:892-919),
     resolve the human sender's `metadata["timezone"]` first; if present, use it
     as the per-message `ZoneInfo` (takes priority over the join-request default).
     Add a "[User timezone: <IANA>]" line to the header / system context.
  3. Handle absence (fall through priority chain) and malformed ids (existing
     `ZoneInfo` fallback).
  4. Resolve per turn so republished travel/DST values are honored.

Both changes are additive and optional end-to-end: until Channel A lands on
the backend, iOS sends the field and the backend ignores it. Until Channel B
lands, an iOS-published `timezone` key in ProfileUpdate is simply ignored.
