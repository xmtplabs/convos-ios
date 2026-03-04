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

- Long-press their avatar in the message list, or
- Tap their avatar to view their profile, then tap "Send DM"

The "Send DM" button only appears if they have DMs enabled for this convo.

Behind the scenes, your client creates a fresh inbox (your new identity for this DM) and sends a DM request as a disappearing message through the 1:1 back channel between your group inbox IDs (the same channel used for join requests), so the tie to the original convo is ephemeral.

## Receiving a DM request

When a DM request arrives, your client automatically:

1. Verifies the request is from someone you share a group with
2. Checks that you have DMs enabled for that group
3. Creates the DM conversation and adds the sender
4. Sets consent state based on your settings:
   - If "From everyone": auto-approves
   - If "From select members": checks if sender is in your list, then approves if so

The sender doesn't know whether they were auto-approved or silently ignored.

## The DM appears

Once the DM is created:

- It shows up in both home lists immediately
- Context is shown: "From [display name] in [convo name]" for the receiver, or "To [display name] in [convo name]" for the sender
- This context expires when the DM request message expires

---

# Who cares

Group chats are where you meet people. But sometimes you want a private sidebar. Traditional messaging apps make this awkward: you're either sending an unwanted message, or building a social graph.

Convos DMs are different. They're initiated with mutual consent, filtered by your own settings, built on fresh identities, and leave no trace connecting back to how you met.

---

# Technical notes

## Profile metadata

The `allowsDMs` flag is a field on the `ProfileUpdate` message type (see PR #552). When a member enables or disables DMs, their client sends a `ProfileUpdate` with the updated `allows_dms` field. This follows the same infrastructure used for name and avatar updates:

- The flag is included in `ProfileSnapshot` messages, so new joiners immediately know who has DMs enabled
- Everyone in the group can read this flag (it's in the profile data)
- Used to conditionally show the "Send DM" button
- Does not reveal whether the user has a select members list

The select members list is private — it is never shared with the group or any other member. See "Select members list" below for storage.

### Proto changes

```protobuf
message ProfileUpdate {
    optional string name = 1;
    optional EncryptedProfileImageRef encrypted_image = 2;
    MemberKind member_kind = 3;
    optional bool allows_dms = 4;  // new
}

message MemberProfile {
    bytes inbox_id = 1;
    optional string name = 2;
    optional EncryptedProfileImageRef encrypted_image = 3;
    MemberKind member_kind = 4;
    optional bool allows_dms = 5;  // new
}
```

Old clients ignore the `allows_dms` field (protobuf forward compatibility). Members on old clients will appear as DMs-disabled (field absent = false).

## The DMRequest message

A new custom XMTP content type (`convos.org/dm_request`) sent via the 1:1 DM back channel between the two members' group inbox IDs — the same mechanism used for invite join requests. This keeps DM requests out of the group message history entirely.

The message contains:

- **Your new inbox ID**: The fresh identity you'll use for the DM
- **A DM tag**: A random identifier to correlate your request with the conversation you're added to
- **The origin conversation ID**: So the receiver's client can look up DM settings for that group
- **Expiration**: This is a disappearing message. When it expires, the context linking the DM to the original convo disappears

This message is delivered because both members' group inbox IDs already have an XMTP DM channel between them (used for join request processing). The DM request is processed silently by the receiver's client — not displayed as a chat message.

## Conversation creation

When the receiver's client processes the request:

1. Creates a new inbox (their fresh DM identity)
2. Creates a new XMTP conversation (they're super admin)
3. Adds the sender's new inbox ID to the conversation
4. Sets the DM tag in conversation metadata
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

The DM flow generalizes to starting a new group with a subset of members from an existing conversation — without the rest knowing.

## How it works

1. In the member list, select multiple members
2. Your client creates a fresh inbox and a new XMTP group
3. Sends a `GroupInviteRequest` through the back channel to each selected member individually
4. Each recipient's client checks DM settings independently, creates a fresh inbox, and joins the group if approved

The sender creates the group immediately — no waiting for acceptance. Recipients join asynchronously as they come online and process the request.

## Reuses the DM infrastructure

- **Same back channel**: 1:1 DM channel between group inbox IDs (used for join requests and DM requests)
- **Same consent logic**: `allowsDMs` setting controls reachability for both DMs and group spinoffs
- **Same fresh identities**: Everyone gets a new inbox for the new group
- **Same select members filtering**: If a recipient only allows DMs from select members, the group invite is filtered the same way

## Differences from DMs

- The sender creates the group upfront (not the receiver)
- The group is not locked — members could add others later
- Each invited member receives their own back channel message and decides independently
- Members who don't accept (or have DMs off) simply never join — no one knows they were invited

## The GroupInviteRequest message

Sent through the back channel to each invitee:

- **Sender's new inbox ID**: Their fresh identity for the new group
- **Conversation ID**: The new group's XMTP conversation ID (to join)
- **Origin conversation ID**: Which group the invite came from (for consent checks)
- **Expiration**: Disappearing message, same as DM requests

---

# FAQ

**Can I DM someone I'm not in a group with?**
No. This is specifically for connecting with people you've already met in a conversation. No requests box, ever.

**What if they have DMs off?**
You won't see the "Send DM" button on their profile. You can't send them a DM from this convo.

**What if I'm not on their select members list?**
You can still send the DM request. The conversation is created, but they may not see it prominently. You won't know either way.

**Can I change my name/photo for the DM?**
Yes. When you send a DM request, a new inbox is created. You can choose to use your quickname, or not, once the DM starts.

**What's the context that appears with the DM?**
"From [display name] in [convo name]". This helps you remember how you met. It disappears when the DM request message expires.

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
