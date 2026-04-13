# DMs

Today we're introducing private DMs from within group conversations, so you can take a conversation one-on-one without sending an unwanted message.

---

## Meet someone, then meet again

DMs can be unwanted. On other apps, anyone can slide in. On Convos, only people from your convos can reach you. Your conversations act as pre-approval. Joining a group with more unknowns? Turn DMs off for that convo entirely.

## You control who can reach you

Each conversation has an "Allow DMs" toggle. When enabled, it defaults to "From everyone" in that convo, but you can customize it to only allow DMs from select members. The sender never knows if they're on your list or not.

## Fresh identities

Both people get new identities for the DM. There's no connection to your group identity visible to anyone: not the other person, not other group members, not Convos. You decide how to show up in the DM: new name, new photo, or the same as before.

---

# How DMs work

## Enabling DMs

In any conversation, you can toggle "Allow DMs" in settings:

- **Off**: No one from this convo can DM you
- **From everyone**: Anyone in this convo can DM you (default when enabled)
- **From select members**: Only specific people you choose can DM you

When you toggle this setting, your client sends a `ProfileUpdate` message to the group with the updated `allows_dms` field. Everyone can see who has DMs enabled, but they can't see if someone only allows select members.

## Sending a DM

When you want to DM someone:

- Tap their avatar to view their profile, then tap "Send DM"

The "Send DM" button only appears if they have DMs enabled for this convo. If the user has already sent a DM to this member from this group, tapping "Send DM" navigates directly to the existing DM conversation.

### First DM (new)

1. User taps "Send DM"
2. Client checks the local DM links table — no existing DM found
3. Client sends a `convo_request` via the back channel with a convo tag
4. Client creates a local placeholder conversation in the "pending DM" state
5. User is navigated to the placeholder conversation, which shows a pending state similar to the invite approval flow (DM icon, "Pending DM", subtitle "Convo will start when other member's device approves")
6. Client stores a DM link: `(origin_conversation_id, member_inbox_id) → (dm_conversation_id, convo_tag)`
7. When the receiver's device processes the request and creates the real conversation, it arrives on the sender's stream. The sender's client matches it by convo tag and transitions the placeholder to the active conversation

### Repeat DM (existing)

1. User taps "Send DM"
2. Client checks the local DM links table — finds existing DM conversation ID
3. User is navigated directly to the existing DM conversation

### Local DM links table

Each device stores DM relationships locally in a `dm_links` table:

| Column | Type | Description |
|--------|------|-------------|
| origin_conversation_id | String | The group where the DM was initiated |
| member_inbox_id | String | The other member's inbox ID in the origin group |
| dm_conversation_id | String | The resulting DM conversation ID |
| convo_tag | String | The tag used to correlate the request with the conversation |

This table is local-only — it never syncs to other devices or members. It is used to:
- Check if a DM already exists before sending a new request
- Correlate incoming conversations with pending DM requests

## Receiving a DM request

When a DM request arrives, your client automatically:

1. Verifies the request is from someone you share a group with
2. Checks that you have DMs enabled for that group
3. Creates the DM conversation and adds the sender
4. Stores a DM link on the receiver's side too
5. Sets consent state based on your settings:
   - If "From everyone": auto-approves
   - If "From select members": checks if sender is in your list, then approves if so

The sender doesn't know whether they were auto-approved or silently ignored.

## The DM appears

Once the DM is created:

- It shows up in both home lists immediately
- In the conversations list, the sender label area (where the member name normally appears) shows origin context: "[display name] from [convo name]". The origin conversation's image may also be shown alongside the convo name for visual recognition
- This context expires when the DM request message expires

---

# Who cares

Group chats are where you meet people. But sometimes you want a private sidebar. Traditional messaging apps make this awkward: you're either sending an unwanted message, or building a social graph.

Convos DMs are different. They're initiated with mutual consent, filtered by your own settings, built on fresh identities, and leave no trace connecting back to how you met.

---

# Technical notes

## Profile metadata

Profile data is transmitted via two custom XMTP content types defined in the `ConvosProfiles` package:

- **`convos.org/profile_update`** — sent by a member when they change their own profile (name, avatar, or metadata). The sender's inbox ID is implicit from the XMTP message envelope.
- **`convos.org/profile_snapshot`** — sent by the member who adds new members to a group. Contains all current member profiles so new joiners have everyone's data immediately (solves the MLS forward secrecy gap where new members can't decrypt older messages).

Both message types include a `metadata` map (`map<string, MetadataValue>`) that supports typed key-value pairs (string, number, or bool). This map is already used for agent attestation fields and is the extension point for new profile features.

### How `allows_dms` works

The `allows_dms` flag uses the existing `metadata` map on `ProfileUpdate` and `MemberProfile` — no proto schema changes needed:

```
metadata["allows_dms"] = MetadataValue(bool_value: true)
```

When a member toggles their DM setting, their client sends a `ProfileUpdate` with the updated metadata. The flag flows through the existing pipeline:

- Persisted in `DBMemberProfile.metadata` (GRDB)
- Included in `ProfileSnapshot` messages, so new joiners immediately know who has DMs enabled
- Everyone in the group can read this flag (it's in the profile data)
- Used to conditionally show the "Send DM" button
- Does not reveal whether the user has a select members list

Old clients ignore unknown metadata keys (the map is additive). Members on old clients will appear as DMs-disabled (key absent = false).

The select members list is private — it is never shared with the group or any other member. See "Select members list" below for storage.

### Profile architecture reference

Profiles are stored per-conversation per-member in the `memberProfile` table. The `ConversationWriter` also writes profiles to XMTP appData as a best-effort fallback for older clients. The authoritative source is always the `ProfileUpdate`/`ProfileSnapshot` messages — appData is only used to fill gaps for members that haven't sent a profile message yet.

## The convo_request message

A new custom XMTP content type (`convos.org/convo_request`) sent via the 1:1 back channel between the two members' group inbox IDs — the same mechanism used for invite join requests. This keeps convo requests out of the group message history entirely.

The message contains:

- **Your new inbox ID**: The fresh identity you'll use for the new conversation
- **A convo tag**: A random identifier to correlate your request with the conversation you're added to
- **The origin conversation ID**: So the receiver's client can look up DM settings for that group
- **Invite slug** (optional): If present, the receiver joins an existing group via this invite (group spinoff). If absent, the receiver creates a new 1:1 conversation (DM).
- **Expiration**: This is a disappearing message. When it expires, the context linking the new conversation to the original group disappears

This message is delivered because both members' group inbox IDs already have an XMTP DM channel between them (used for join request processing). The convo request is processed silently by the receiver's client — not displayed as a chat message.

## Conversation creation

DM conversations are standard XMTP group conversations — there is no special "DM" conversation type. The only difference is the entry point: instead of being created from an invite link, they're created from within an existing group. Once created, they look and behave like any other conversation.

When the receiver's client processes the request:

1. Creates a new inbox (their fresh identity for this conversation)
2. Creates a new XMTP group conversation (they're super admin)
3. Adds the sender's new inbox ID to the conversation
4. Sets the DM tag in conversation metadata (for origin context display)
5. Locks the conversation (no additional members allowed)
6. Sets consent state based on their DM settings

## Select members list

The select members list is stored as a self-addressed XMTP message — you send it to your own inbox ID's DM channel. XMTP encryption means only your installations can read it.

Each message contains a conversation ID and the list of allowed inbox IDs. When you update the list, send a new message. On new device or reinstall, read the latest per conversation.

## Consent logic

The consent check happens on the receiver's device:

- If "From everyone": consent is set to approved immediately
- If "From select members": checks the local select members list (stored in GRDB, never shared). Approved only if sender is in the list
- If not approved, the conversation exists but won't surface notifications or appear prominently

The sender has no way to know which path was taken.

## Locking the conversation

XMTP group permissions are set so:

- Only the two inbox IDs can be members
- No one can add additional members
- The creator (receiver) retains super admin for explode control

---

# Group spinoffs

> **Status: deferred.** Group spinoffs will be implemented after DMs ship. The design below is fully specified.

The DM flow generalizes to starting a new group with a subset of members from an existing conversation — without the rest knowing.

## UI flow

1. In conversation settings, below the "X members" row, a button reads **"Spinoff new Convo"** with footer text "Invite members to a new Convo"
2. Tapping opens a member picker showing all members except the current user
3. The user selects one or more members (minimum 1) and taps **"Pop up new convo"**
4. The sender is taken to a `ConversationView` for the new group. A toast above the messages input bar (same style as quickname UI) shows "✓ invites sent" and auto-dismisses

## How it works

1. The sender's client creates a fresh inbox and a new XMTP group (sender is super admin)
2. Generates an invite for the new group
3. Sends a `convo_request` through the back channel to each selected member individually, including the invite slug
4. Each recipient's client checks `allows_dms` settings independently, creates a fresh inbox, and joins via the invite if approved
5. The sender (as super admin) processes join requests as recipients join

The sender creates the group immediately — no waiting for acceptance. Recipients join asynchronously as they come online and process the request. The sender sees the conversation view as they would when creating any new conversation (no pending member indicators).

## Permissions

- **Sender**: super admin of the spinoff group
- **Invited members**: join as admins (can add more people later)
- The group is not locked — members can add others after joining

## Conversation naming

The UI displays "[origin convo name] spinoff" if no name has been set. This is a client-side display convention, not stored as the XMTP group name. There is no visible link back to the origin conversation.

## Reuses the DM infrastructure

Both DMs and group spinoffs use a single content type: `convos.org/convo_request`. The message includes an optional invite slug:

- **DM (1:1)**: No invite slug. The receiver creates the conversation.
- **Group spinoff**: Includes an invite slug. The receiver joins the sender's existing group via the invite.

Other shared infrastructure:
- **Same back channel**: 1:1 DM channel between group inbox IDs (used for join requests and convo requests)
- **Same consent logic**: `allows_dms` setting controls reachability for both DMs and group spinoffs. Only recipients need the flag enabled; the sender does not.
- **Same fresh identities**: Everyone gets a new inbox for the new group
- **Same select members filtering**: If a recipient only allows DMs from select members, the group invite is filtered the same way

## Differences from DMs

- The sender creates the group upfront (not the receiver)
- The group is not locked — members can add others later
- Each invited member receives their own back channel message and decides independently
- Members who don't accept (or have DMs off) simply never join — no one knows they were invited

## Abuse prevention

The `allows_dms` filtering on the receiving end gates all convo requests. If a member has DMs off, spinoff invites from that conversation are silently ignored. No additional rate limiting is needed.

---

# FAQ

**Can I DM someone I'm not in a group with?**
No. This is specifically for connecting with people you've already met in a conversation. No requests box, ever.

**What if they have DMs off?**
You won't see the "Send DM" button on their profile. You can't send them a DM from this convo.

**What if I'm not on their select members list?**
You can still send the DM request. The conversation is created, but they may not see it prominently. You won't know either way.

---

# Architecture notes from phase 1 investigation

The phase 1 implementation worked, but the work exposed a few weak points in the current architecture.

## Main weak point: we don't have a first-class local relationship layer

Right now we're using a mix of:
- conversations
- per-conversation member profiles
- `dmLink`
- origin conversation metadata

...as stand-ins for a more important product concept: a local-only relationship between two people.

That works for phase 1, but it is fragile.

Examples of product questions that don't yet have a clean architectural home:
- have I DMed this person before?
- what group did I meet them in?
- what is my preferred DM with this person?
- what should I call them locally?
- where else have I seen them?
- do I consider them a contact now?

## `dmLink` is useful, but too narrow

Today `dmLink` mostly means:
- `(originConversationId, memberInboxId) -> dmConversationId`

That is enough to avoid creating duplicate DMs from the same origin convo, but it is not yet a real local social graph primitive.

Missing concepts include:
- one person known through multiple groups
- multiple shared origins for the same person
- a preferred DM independent of a single origin
- local nickname / notes / trust state
- whether someone has become a real contact

## Conversation-scoped profile and person identity are mixed together

The current profile system is correctly conversation-scoped. That part should stay.

But we are missing a stable local layer above it for "this is a person I know locally on this device". Without that layer, we keep answering relationship questions indirectly through conversations and member profiles.

A person has:
- a stable inbox identity
- many conversation-scoped presentations
- potentially a local-only contact relationship on this device

Those should be modeled separately.

## Origin context is currently bolted on

The work needed to show UI like `Tommy from Camera Club` is a sign that origin context matters as product data, not just as a display trick.

That context should eventually live in a proper local relationship model rather than being reconstructed ad hoc from `dmLink` + conversation lookups.

## Profile seeding showed we need a better relationship bootstrap path

To seed DM profiles correctly, we had to:
- send a `ProfileSnapshot` in the `convo_request`
- apply the sender's seeded profile on the receiver side
- seed the receiver's own profile into the new DM
- seed the sender's own profile when the DM arrives locally

That works, but it shows that we do not yet have a first-class "bootstrap a new private relationship" pipeline.

## Recommendation: add a local-only social graph / contacts layer

A good next architectural step would be introducing a dedicated local-only relationship layer.

Not a large network model — just a local store for people and relationship context.

A likely shape:

### `localPerson`
A stable local record keyed by inbox ID.

Possible fields:
- `inboxId`
- `firstSeenAt`
- `lastSeenAt`
- `isContact`
- `localNickname`
- `isBlocked`
- `notes`

### `localRelationshipContext`
Tracks where you know someone from.

Possible fields:
- `personInboxId`
- `originConversationId`
- `firstSeenAt`
- `lastSeenAt`
- maybe a cached local display snapshot of the origin convo

This would support UI like:
- `Tommy from Camera Club`
- also seen in `Friday Dinner`

### `localDirectRelationship`
Represents the local DM/contact edge.

Possible fields:
- `personInboxId`
- `preferredDMConversationId`
- `createdFromConversationId`
- `status` (`pending`, `active`, `hidden`)
- `firstCreatedAt`
- `lastUsedAt`

This would be a better home than `dmLink` for "have I already started a private relationship with this person?"

## Important constraint: XMTP `dm` type should remain back-channel only

One architectural smell from phase 1 is that some code currently relies on `kind == .dm`, and phase 1 also temporarily writes created DM group conversations into local storage as `.dm` for UI behavior.

That is not the intended long-term model.

The intended model is:
- XMTP `dm` conversations are only used as a back channel between group inbox identities
- app-visible DMs are standard XMTP group conversations
- the app should not need to reinterpret those group conversations as true XMTP `dm` conversations in order to render or route them correctly

The current places where this shows up are good candidates for cleanup:
- `ConvosCore/Sources/ConvosCore/Syncing/ConvoRequestManager.swift`
- `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift`
- UI logic that branches on `Conversation.kind == .dm` instead of using a stronger local relationship model

A better long-term direction is:
- use XMTP `dm` only for back-channel request transport
- model app-visible DM relationships locally as first-class relationship/contact records
- keep the actual app-visible DM conversation as a normal XMTP group conversation

## Summary

The current phase 1 approach is good enough to ship and learn from, but the investigation made one thing clear:

we are currently modeling a relationship feature mostly through conversation artifacts.

That mismatch will keep creating friction as we add:
- contacts
- multiple shared origins
- DM suggestions
- local nicknames
- trusted / blocked people
- group spinoffs
- "people you've met" surfaces

A local-only social graph / contact layer would give those ideas a proper home without weakening the conversation-scoped privacy model.

**Can I change my name/photo for the DM?**
Yes. When you send a DM request, a new inbox is created. You can choose to use your quickname, or not, once the DM starts.

**What's the context that appears with the DM?**
"From [display name] in [convo name]". This helps you remember how you met. It disappears when the DM request message expires.

---

# Shared UI components

## Member picker

A reusable member selection component used in multiple places:

- **DM permissions**: selecting which members can DM you ("From select members" list)
- **Group spinoffs** (phase 2): selecting which members to invite to a new spinoff group

The component takes a list of members (with profiles) and lets the user tap to select/deselect. It shows member avatars, display names, and a checkmark for selected members. The parent view controls the minimum selection count (1 for spinoffs, 0 for DM permissions) and the action button label ("Pop up new convo" for spinoffs, "Save" for DM permissions).

This component should be built in phase 1 as part of the DM permissions UI and reused in phase 2 for spinoffs.

---

# Decisions

1. **Allow DMs toggle**: Per-conversation setting with three states: off, everyone, select members.

2. **Profile messages for `allowsDMs`**: The flag is a field on `ProfileUpdate` / `MemberProfile` (PR #552's profile message infrastructure). It flows through the existing codec, snapshot, and GRDB persistence pipeline. No new content type needed for the flag itself.

3. **Select members list is private**: Synced across your devices via self-addressed XMTP messages. Never shared with the group. The sender cannot determine whether they're on someone's list.

4. **Silent filtering**: Senders don't know if they're on the approved list. No rejection notification.

5. **Context expiration**: The link between DM and origin convo is ephemeral, tied to the DM request message lifetime.

---

# Open Questions

## Select members UX

How do users manage their "select members" list per conversation?

**Decision**: Inline in settings. Expanding the "Allow DMs" option shows a member picker where users can selectively add members to their allow list.

## DM request expiration

How long should the DM request message live before the origin context disappears?

- 7 days: Long enough to catch people who don't check daily
- 24 hours: More ephemeral, less context lingering

**Leaning toward**: 7 days, same as before.
