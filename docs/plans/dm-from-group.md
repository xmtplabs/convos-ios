# DMs

Today we're introducing private DMs from within group conversations, so you can take a conversation one-on-one without anyone knowing you did.

---

## Meet someone, then meet again

You meet people in group convos. Sometimes you want to connect with them privately. On other apps, sliding into someone's DMs means they see your profile, your history, your identity. On Convos, starting a DM means starting fresh — a new identity for both of you, no strings attached to the group where you met.

## Consent goes both ways

You can't just DM someone. You signal that you're open to it, they decide if they want to connect. No one gets added to a conversation they didn't agree to. And because the person who accepts creates the DM, they're in control — they decide when it explodes.

## Ephemeral by design

The connection between your group identity and your DM identity is temporary. Once the signal expires, there's no trace linking the two. You showed up how you chose in the group, you show up how you choose in the DM.

---

# How DMs work

## Signaling intent

When you want to DM someone you've met in a group:

- Long-press their avatar in the message list
- Tap "Open to DM"
- A faint green circle appears around your avatar (from their perspective)

Behind the scenes, your client creates a fresh inbox — your new identity for this DM. A signal is sent to the other person via XMTP containing your new inbox ID and a short-lived tag. This signal is allowed through because you're already in a trusted conversation together.

## Accepting

When someone signals they're open to a DM with you:

- You see a faint green circle around their avatar in the message list and on their profile sheet
- Tap it to see: "<Name> is open to a DM"
- Tap "Accept" or "Not interested"

If you accept, your client creates your fresh identity, creates the DM conversation, adds their inbox ID, and locks the conversation so no one else can join. You're the creator — you control when this DM explodes.

If you tap "Not interested," future DM intents from this person are blocked. You can always change your mind later by sending them a DM intent yourself.

## The DM appears

Once accepted:

- The DM shows up in both your home lists immediately
- The green circle around their avatar becomes solid (no longer faint)
- Tapping the solid green circle takes you to the DM
- When the original signal expires, the green circle disappears — the ephemeral link between identities dissolves

## Fresh identities

Both people get new identities for the DM. There's no connection to your group identity visible to anyone — not the other person, not other group members, not Convos. You decide how to show up in the DM: new name, new photo, or the same as before.

## They're in control

The person who accepts the DM request is the creator. They have super admin powers. When they decide the DM has run its course, they can explode it — destroying all messages and both identities cryptographically.

---

# Who cares

Group chats are where you meet people. But sometimes you want a private sidebar without broadcasting that you're having one. Traditional messaging apps make this awkward, they reveal your full identity and creates a permanent connection.

Convos DMs are different. They're initiated with mutual consent, built on fresh identities, and leave no trace connecting back to how you met.

---

# Technical notes

## The DMIntent message

When you signal intent to DM, your client sends a custom XMTP content type:

- **Your new inbox ID**: The fresh identity you'll use for the DM
- **A DM tag**: A random identifier to correlate your request with the conversation you're added to
- **Expiration**: This is a disappearing message (7 days) — when it expires, the green circle goes away

This message is delivered because your existing inbox ID (from the group) already has approved consent state with the recipient.

## Conversation creation

When the other person accepts:

1. They create a new inbox (their fresh DM identity)
2. They create a new XMTP conversation (they're super admin)
3. They add your inbox ID to the conversation
4. They set the DM tag in conversation metadata
5. They lock the conversation (no additional members allowed)

## Verification

When you're added to the DM conversation:

1. Your client syncs the new conversation
2. Checks if the conversation's DM tag matches the tag from your DMIntent
3. If it matches, the DM is revealed in your home list
4. If it doesn't match, the conversation is rejected (someone tried to add you to an unrelated convo)

## Expiration and the green circle

- The solid green circle persists while the DMIntent message exists
- Once the disappearing message expires, the circle goes away
- The DM itself remains — only the visual indicator of "how you connected" dissolves
- This ensures the link between group identity and DM identity is ephemeral

## Locking the conversation

XMTP group permissions are set so:

- Only the two inbox IDs can be members
- No one can add additional members
- The creator (accepter) retains super admin for explode control

---

# FAQ

**What if I signal intent but they never see it?**
The disappearing message expires and the faint green circle goes away. You can signal again whenever you want.

**Can I DM someone I'm not in a group with?**
Not with this flow. This is specifically for connecting with people you've already met in a conversation. No requests box, ever.

**Do they see my group identity when I signal intent?**
They see your avatar and name from the group — that's how they know who's reaching out. But the DM itself uses your fresh identity.

**Can I change my name/photo for the DM?**
Yes. When you signal intent, a new inbox is created. You can choose to use your quickname, or not, once the DM starts.

**Can the other person see that I signaled intent to others?**
No. The DMIntent is sent via private XMTP DM between your group identities. No one else in the group can see it.

**What if I tapped "Not interested" but changed my mind?**
Send them a DM intent yourself. That unblocks them and signals you're now open to connecting.

**Can I signal intent to multiple people?**
Yes. Each intent creates a separate fresh identity, so you can have multiple pending requests at once.

---

# Decisions

1. **Green circle on profile sheet**: Yes — the DM status indicator appears both in the message list and on the profile sheet.

2. **DMIntent expiration**: 7 days. Long enough to catch people who don't check the app daily, short enough to feel ephemeral.

3. **"Not interested" action**: Yes — tapping "Not interested" blocks future DM intents from that person. You can always change your mind by sending them an intent yourself.

4. **Multiple pending intents**: Yes — you can signal intent to multiple people at the same time.
