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


## 2. Recommended invisible channel + exact client insertion point

### The channel: the per-sender ProfileUpdate.metadata map

The cleanest invisible channel is not the agents/join provision body and not a
new ConversationCustomMetadata field. It is the existing per-sender
`ProfileUpdate.metadata` map -- a `map<string, MetadataValue>` that the client
already publishes per conversation and that the server-side agent/runtime can
read per sender.

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

### Exact client insertion point

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

Publish the timezone only in conversations that contain an agent member. Do not
publish it in human-only conversations: a time zone has no purpose for human
peers and should not leak to them. The agent-join sites are the natural place to
detect "this conversation has an agent":
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

Republish the timezone in two situations, so travel and DST changes stay
current:
  - when an agent joins a conversation (the initial publish above), and
  - opportunistically, e.g. on app foreground / first interaction of a session,
    for conversations that already contain an agent.

Critical constraint -- single writer to avoid clobbering the map: the
`ProfileUpdate.metadata` map is per-sender, but a publish rewrites the whole
merged map for that sender (read existing -> merge key -> publish). If two
execution contexts publish concurrently -- e.g. the main app and the
Notification Service Extension, or a background task -- they can read-modify-write
the same map and one can clobber the other's keys (including `connections`). To
keep exactly one writer:

  - Publish the timezone only from the foregrounded main app.
  - Never publish it from the Notification Service Extension.
  - Never publish it from a background task / background refresh.

Foreground-main-app-only is the race-avoidance strategy: a single writer means
there is no concurrent read-modify-write on the per-sender metadata map, so a
timezone publish can never race with (and clobber) a `connections` publish or
vice versa. The cost is only that a timezone change made while the app is
backgrounded is picked up on the next foreground interaction rather than
instantly -- acceptable, since the IANA identifier already lets the agent handle
DST without any client update, and travel is reflected the next time the user
opens the app.


### Alternatives considered, and why they lose

ALT A -- new field on the agents/join provision body.
    POST v2/agents/join body is ConvosAPI.AgentJoinRequest:
      ConvosCore/Sources/ConvosCore/API/ConvosAPIClient+Models.swift:170-180
        slug: String, templateId: String?, options: AgentJoinOptions?
    Construction choke point (single place to add a field):
      ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift:760-781
    Why it loses:
      - The body is validated strictly server-side; unknown keys are rejected
        (Models.swift:165-168). A prior `instructions` field was deliberately
        removed (ConversationViewModel.swift:3575 doc comment). So this cannot
        ship from iOS alone -- it needs a coordinated backend change and it is a
        one-shot value at join time (no DST refresh, no update when the user
        travels). The ProfileUpdate channel updates naturally on every publish.
      - It is an HTTP control call, not part of the conversation the agent reads;
        the backend would have to plumb the value from the join endpoint into the
        agent's runtime context separately.

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

(a) What iOS can do alone (ships independently, no backend change):
    - Read TimeZone.current.identifier.
    - Publish it as metadata["timezone"] on the per-sender ProfileUpdate via
      MyProfileWriter.updateAndPublish, scoped to agent conversations and
      written only from the foreground main app (sections above). This rides the
      existing ProfileUpdate channel, so the data physically reaches the runtime
      with no new endpoint or schema. It is also stored locally on
      DBMemberProfile so it is durable and refreshable.
    - This means the bytes arrive even before the backend does anything; the
      agent simply ignores an unknown key until taught.

(b) What requires an agents / backend contract change (the required server-side
    half -- iOS alone cannot make the agent reason in the user's time zone):
    - The agent runtime must read metadata["timezone"] for the human member and
      fold it into its context / system prompt (e.g. "The user's time zone is
      Europe/Paris; interpret relative times accordingly"). Concrete proposal in
      section 7.
    - This is the only required cross-boundary change. It is additive (a new
      optional key in the per-member metadata map), so it does not break
      existing readers.

Minimal contract (write it down once, both sides agree):
    Channel:  per-sender ProfileUpdate.metadata map (XMTP), key "timezone".
    Key:      "timezone"   (string)
    Value:    IANA tz database identifier, e.g. "Europe/Paris". Required when
              present; no companion keys.
    Semantics: latest ProfileUpdate wins; absence = unknown, agent must not assume.
    Writer:   the foreground main app only; never the NSE or a background task.
    Agent behavior: parse the IANA id with its own tz library; do not trust any
              offset for future dates (recompute from the identifier so DST is
              correct). On a malformed/unknown id, degrade gracefully (treat as
              unknown / default to UTC).


## 4. Minimal client-side implementation sketch

Add a small writer that mirrors the connections pattern. Pseudocode (not
committed):

    // ConvosCore, alongside CloudConnectionGrantWriter / MyProfileWriter usage.
    func publishTimezone(conversationId: String) async throws {
        let existing = try await databaseReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: conversationId,
                                         inboxId: myInboxId)?.metadata
        }
        var merged: ProfileMetadata = existing ?? [:]
        merged["timezone"] = .string(TimeZone.current.identifier)
        try await myProfileWriter.updateAndPublish(
            metadata: merged.isEmpty ? nil : merged,
            conversationId: conversationId
        )
    }

Call it right after a successful agent join, at the join sites in section 2,
and on opportunistic foreground refresh for conversations that already contain
an agent. Gate every call on:
  - the conversation contains an agent member (scope, Q1), and
  - the caller is the foreground main app (single-writer, Q2) -- do not wire this
    into the Notification Service Extension or any background path.
Keep it best-effort (log on failure; do not block the join).
TimeZone.current must be read on the main actor or captured into a value before
hopping to a background context (it is a cheap synchronous read).

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
     foreground / first interaction of a session) and when an agent joins. To
     avoid concurrent edits clobbering the per-sender metadata map, do the
     publish only from the foregrounded main app -- never from the Notification
     Service Extension and never from a background task. The map is per-sender
     but a publish rewrites the whole merged map, so a single foreground writer
     is how we guarantee no read-modify-write race against `connections` or any
     other key. (Folded into section 2 "Refresh".)
  3. Backend ownership / agent contract -- RESOLVED with a concrete proposal.
     This lives in the convos-assistants repo. iOS can only transmit the key; the
     runtime owns reading metadata["timezone"] for the human member and folding
     it into the agent context. See section 7 for the proposed read site,
     validation, injection point, absence handling, and per-turn re-read. Confirm
     the key name and semantics with the agents team before the iOS side ships.
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

This section is the required server-side half (Q3). It is a suggestion -- paths
plus approach, not a prescriptive diff. iOS can only put the bytes on the wire;
without this, adding metadata["timezone"] on iOS has no observable effect.

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

### Where per-sender profile metadata lives today (the read surface)

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

### Where the timezone gets injected into the agent context

The runtime already reasons about time and already has a single chokepoint for
the user's zone:
  - runtime/hermes/src/server/agent_runner.py:52-57 defines a process-wide
    default zone:
        _tz_name = os.environ.get("USER_TIMEZONE", "America/New_York")
        try:
            _USER_TZ = ZoneInfo(_tz_name)
        except KeyError:
            logger.warning("Unknown timezone %r - falling back to UTC", _tz_name)
            _USER_TZ = timezone.utc
  - `_USER_TZ` is consumed in `_format_envelope` (agent_runner.py:909-910) to
    render the current time and the message timestamp into the header the model
    sees ("[Current time: Thu, Mar 20, 2026, 10:30 AM EDT]").

This is the ideal injection point. Proposed approach:
  - Plumb the human sender's `metadata["timezone"]` into `_format_envelope` (or
    resolve it just before the call) and use it to build a per-message
    `ZoneInfo` instead of the process-wide `_USER_TZ`. The existing
    `ZoneInfo(name)` construction plus the `except` -> UTC fallback already
    doubles as IANA validation: a plausible IANA id parses; a malformed one
    raises and is caught, satisfying Q5's "degrade gracefully" requirement with
    no new validation code.
  - Additionally, add an explicit line to the agent context / system prompt so
    the model reasons about relative times correctly, e.g.
        "[User timezone: Europe/Paris]"
    appended in the same header `_format_envelope` builds, or folded into the
    platform system prompt assembled per turn (the platform prompt is reloaded
    each turn at agent_runner.py around line 1091, so a per-turn value is
    naturally honored).

### Absence and validation handling

  - Absent key: omit the "[User timezone: ...]" line and fall back to the
    existing default (the `USER_TIMEZONE` env default, ultimately UTC). The agent
    must not assume a zone when none is present.
  - Malformed / non-IANA value: caught by the existing `ZoneInfo(...)` ->
    `except` -> UTC fallback; treat as unknown. No enum or wire validation is
    expected from iOS (Q5).

### Re-read on each turn (travel / DST)

Read the human member's `metadata["timezone"]` per turn rather than caching it
once for the session, so a republished value (the user traveled, or the app
republished on foreground) is picked up mid-conversation. The metadata refresh
already has a TTL (`_refresh_metadata_if_stale`, runtime.py:309-313); resolving
the timezone from the (refreshed) per-member cache at envelope-format time means
each turn uses the latest published value. The IANA identifier means DST is
handled by `ZoneInfo` without any further client publish.

### Summary of the server-side change

  1. In `_refresh_metadata_if_stale` (runtime.py:329-332), copy each resolved
     member's metadata fields into `MemberProfile.metadata` (pattern:
     get_own_profile_metadata, runtime.py:780-783).
  2. At message-format time (agent_runner.py `_format_envelope`, :892-919),
     resolve the human sender's `metadata["timezone"]`, build a per-message
     `ZoneInfo` from it (reusing the existing parse + UTC fallback at :52-57),
     and add a "[User timezone: <IANA>]" line to the header / system context.
  3. Handle absence (omit / default to UTC) and malformed ids (existing fallback).
  4. Resolve per turn so republished travel/DST values are honored.

This is additive and optional end-to-end: until steps 1-2 land, an iOS-published
`timezone` key is simply ignored.
