# Connections v1 — Calendar (Product Requirements)

**Status**: Drafted from the 2026-04-28 working session, refocused on Calendar
**Owners**: Louis Rouffineau, Andrew Courter, Jarod Luebbert
**Companion docs**: [`capability-resolution.md`](https://github.com/xmtplabs/convos-ios/blob/dev/docs/plans/capability-resolution.md), [`capability-resolution-flows.md`](https://github.com/xmtplabs/convos-ios/blob/dev/docs/plans/capability-resolution-flows.md)

## Summary

v1 ships **one connection done deeply: Calendar.** Both providers — Apple Calendar (device, via system permission) and Google Calendar (cloud, via OAuth) — and as much of the user's real calendar workflow as the assistant can credibly drive: reading the schedule, creating and editing events, managing invitations, RSVP'ing to incoming invites, and adding attendees to existing events.

We're not shipping breadth (Health, Drive, Strava, etc.). We're shipping one thing the user already does every day, and proving the assistant can do it for them.

## Why Calendar, why this depth

The bet is that calendar work is the highest-frequency, highest-confidence assistant task we can offer. Most users have one already; most users coordinate over it daily; most assistant prompts that start with "let me check my schedule" or "can you put something on my calendar?" stop being useful the moment the assistant has to bounce the user out of chat.

A shallow calendar integration ("the assistant can read your events") teaches the user nothing. A deep one ("the assistant can read, schedule, invite, RSVP, reschedule, and update attendees") is the moment the subscription becomes obvious.

Calendar also happens to exercise both halves of the connection architecture in one product surface: device permissions on the Apple side, OAuth-via-Composio on the Google side. If we get this one right, every later connection is a catalog row.

## What the assistant can do for the user in v1

Eight operations, organized by what a user would say to the assistant. These are the user-facing capabilities; the underlying machinery routes each to the resolved provider for the conversation.

| # | What the user asks | What the assistant does |
|---|---|---|
| 1 | "What's on my schedule?" / "Am I free Thursday at 3?" | Read events across the resolved calendar's date range. |
| 2 | "Show me invites I haven't responded to yet" | List pending invitations (events the user is invited to with `needsAction` status). |
| 3 | "Accept the standup invite" / "Decline the lunch on Friday" | RSVP to a pending invitation (accept / decline / tentative). |
| 4 | "Put a 9 AM standup on my calendar tomorrow" | Create an event. |
| 5 | "Invite Saul and Andrew to that standup" | Add attendees to an event the user owns (and trigger invitation sends). |
| 6 | "Move the standup to 10 AM" / "Change the title to 'Eng sync'" | Update an event the user owns (time, title, location, description). |
| 7 | "Cancel the standup" / "Remove Andrew from it" | Delete an event, or remove specific attendees. |
| 8 | "What did Saul send me — the offsite invite, when is it?" | Read a specific event by reference (title or invitation context). |

These are not eight separate connections. The user grants Calendar access once per conversation, and the assistant gets all eight.

## Provider capability — the honest matrix

Apple Calendar via EventKit and Google Calendar via Composio do not have symmetrical surfaces. We commit to a v1 position now so the assistant doesn't promise things one provider can't deliver.

| Operation | Apple Calendar (EventKit) | Google Calendar (Composio) |
|---|---|---|
| Read events | ✅ Full | ✅ Full |
| Read pending invitations | ✅ Full | ✅ Full |
| Create event (no invitees) | ✅ Full | ✅ Full |
| Create event with invitees | ⚠️ Limited — event is created locally; iOS does not send invitations programmatically | ✅ Full — invitations sent via Google |
| Update event (time, title, location) | ✅ Full | ✅ Full |
| RSVP to incoming invitation | ⚠️ Limited — only for accounts that support programmatic RSVP (iCloud/Exchange variable; many fall back to opening Apple Calendar) | ✅ Full |
| Add attendees to existing event | ⚠️ Limited — same as create-with-invitees | ✅ Full |
| Remove attendees | ⚠️ Limited — same as above | ✅ Full |
| Delete event | ✅ Full | ✅ Full |

Where Apple Calendar is **Limited**, the assistant's behavior in v1 is:
1. Complete the part it can (e.g., the local event row is written).
2. In its reply, tell the user what it couldn't finish: *"I added the standup to your calendar but iOS won't let me send invitations from here — tap to open Calendar and invite Saul and Andrew."*
3. Provide a deep link into Apple Calendar that opens the event so the user can complete the action in one tap.

This is the v1 product position: graceful degradation with a clear handoff, not silent failure and not pretending parity. Users who care about the invitation surface will pick Google Calendar in conversations where it matters; users who don't care will pick Apple Calendar and use the assistant for the things it can fully do.

## Timezone — what the assistant assumes

Calendar work breaks fast without a shared notion of what time the user means. v1 commits to **two timezone concepts**, with the assistant choosing per event.

**Floating time** (default). *"Remind me at 9 AM"* or *"schedule the standup at 9 AM tomorrow"* — the user means 9 AM in whatever timezone they're currently in. The event tracks the user's device timezone; if the user travels from SF to Paris, the event travels with them. This is the ~80% case.

**Pinned time**. *"Schedule the offsite for 2 PM Pacific on Friday"* or *"set up the 9 AM standup with Saul"* — the user means a specific timezone, either explicit or inferred from cross-user coordination. The event carries an absolute timezone and does not drift if the user moves.

The assistant defaults to floating unless the request mentions a timezone, references another person's local time, or is otherwise a cross-user coordination — in which case it pins. For incoming invitations from others, the timezone is whatever the sender set; the assistant translates into the user's current timezone in its reply.

### Two profile fields

To support this without the assistant having to ask every time, v1 adds:

- **Device timezone** — read live from iOS. Drives floating events. No user setup.
- **Preferred timezone** — optional user-profile field, set in app settings. Defaults to device timezone. Used as a fallback when device timezone is unavailable, and as the source of truth for "what timezone do I usually mean?" in ambiguous cases.

These ride along on the user's profile so the assistant has them without asking.

### Background

Per the [Slack discussion on timezone metadata](https://xmtp-labs.slack.com/archives/C0AENB50MPX/p1777409685008479) (Saul + Quarter, 2026-04-26): defaulting to share timezone matches every other calendar app, and the floating-vs-pinned distinction lets the assistant make the right call per event without asking. The "GPS timezone vs. preferred timezone" split came out of that thread — both fields exist; the assistant uses preferred when available and device when not.

### Out of scope for v1

- Per-conversation timezone overrides ("treat this conversation as Pacific time"). The assistant decides per event; the user can clarify in chat if it gets one wrong.
- Recurring events with timezone changes mid-series.
- DST edge cases beyond what the OS timezone library handles.

## How the user experiences this

The agent triggers everything. There is no "set up your calendar" surface the user is expected to visit pre-emptively.

### First time in a conversation

1. Agent asks in chat: *"To help you with scheduling I'd like to access your calendar."*
2. A card appears with two rows — Apple Calendar and Google Calendar — and a single Approve action.
3. If the user has neither linked, the rows show **Connect** buttons. Tapping Connect on Apple Calendar fires the iOS permission prompt; tapping Connect on Google Calendar opens the OAuth web view in-app. On success, the connection is approved automatically — no second tap required.
4. If only one is linked, the card defaults to that one with a one-tap Approve.
5. If both are linked, the user picks one and approves.
6. Toast confirms ("Calendar connected"); the assistant proceeds with whatever it was trying to do.

### Subsequent operations in the same conversation

- **Different verb on the same calendar**: a single-tap consent card. *"Allow Apple Calendar to create events?"* — the user already picked the provider, the assistant just asks for the next verb.
- **Same verb, no card**: assistant calls the action directly. The user sees only the result in chat.

### Multiple calendars in one conversation

The user can approve **up to two calendar providers** in a single conversation (e.g. work + personal — Apple Calendar and Google Calendar side by side). Behavior:

- **Reads federate.** "What's on my schedule?" returns the union of events across approved providers, with each event tagged by source so the user (and the assistant) know where it lives.
- **Writes target exactly one provider.** When the user makes their first write request, the assistant asks which calendar it should land in. That pick sticks for the rest of the conversation unless the user revokes the pinned provider, at which point the next write re-prompts.
- **The cap is two.** Three+ calendars makes the picker noisy and the assistant's "which one did this event end up in?" reply harder to keep tight. ~80% of users have at most personal + work; the long tail isn't worth the v1 UX cost. The cap can be lifted later without a schema change.

### Switching or revoking

The user can revoke either provider from Conversation Info → Connections. Revoking the write-pinned provider re-prompts on the next write. Revoking everything re-prompts the picker on the next request.

### Across conversations

Each conversation is independent. A user might use Google Calendar with their work assistant and Apple Calendar with their personal one. Approving in conversation A does not approve in conversation B.

## Conversation Info — the back-pocket surface

The Conversation Info screen gains a **Connections** section. For v1 it shows:

- The currently approved calendar provider for this conversation, with a toggle to revoke.
- The verbs the assistant has been granted (read, create, update, delete, RSVP, attendee management) — read-only, for transparency.
- A "Disconnect Calendar" action that clears every verb at once.

This is **not a setup surface**. There is no "Add a calendar" button here. New connections happen through the agent's request. The Connections section exists so a user who's wondering "what does this assistant have access to?" can find out and pull it back if they want.

## Out of scope for v1

- Other Composio services (Drive, Gmail, Outlook, Strava, Spotify, Notion, …).
- Other device permissions (Health, Contacts, Photos, Music, HomeKit, Location, Motion).
- More than two calendar providers per conversation.
- Cross-conversation sharing of approvals.
- Cross-device sync of approvals.
- Pre-emptive "Connections" home-screen tab.
- Subscription gating. v1 calendar works for any active user; the gating decision lives in the subscription PRD.
- Microsoft Outlook / Office 365. Composio supports it; v1 does not. (We add it the day after v1 ships if the architecture holds.)
- Recurring-event rules editing beyond simple updates (RRULE manipulation, exception dates, series-vs-instance edits). Recurring events are read; v1 writes are scoped to single-event mutations.
- Calendar overlays / availability lookup across multiple participants ("when is everyone free?"). That's a v1.1 product surface, not a v1 mechanic.
- Free/busy export to other apps.

## Failure modes the user must see clearly

| Scenario | Assistant behavior |
|---|---|
| User denies the request | Acknowledges in chat, does not retry within the conversation. |
| OAuth web view fails or is dismissed | Card stays open; the user can retry or deny. |
| iOS permission previously denied at system level | Card surfaces "Open Settings"; we don't pretend the prompt will appear. |
| Composio is down during OAuth | Card surfaces a retry; assistant explains in chat the connection couldn't be established. |
| Apple Calendar account doesn't support a specific operation (e.g., RSVP on certain Exchange configurations) | Assistant tries, falls back to "I couldn't do that here — tap to open Calendar" with a deep link. |
| Agent is offline when the user approves | Approval recorded locally; reply lands when the agent reconnects. |
| User revokes the iOS permission via Settings after approving | Next agent action surfaces a recoverable error in chat; user can re-approve from the same flow. |
| User toggles Calendar off in Conversation Info | Approval cleared; next request re-prompts. |
| Event the user references doesn't exist or is ambiguous | Assistant asks for clarification before acting; never deletes or modifies on a guess. |

## Open product questions

These came up in the working session and don't have a confident v1 answer. Each has a working assumption we revise based on real usage.

1. **Is two calendars per conversation the right cap?** **v1 assumption**: yes — covers personal + work for ~80% of users, keeps the picker and the "which calendar?" reply legible. If TestFlight users push back ("I have personal + work + family"), the cap is a config change, not a schema migration. Watch for this signal during the TestFlight window.

2. **How does the assistant handle ambiguous event references?** "Move the standup" when there are three standups this week. **v1 assumption**: assistant asks one disambiguating question in chat before acting. We don't ship a fancy entity-resolution UI; the conversation is the disambiguator.

3. **Where does invitation-management UX live when Apple Calendar can't fully drive it?** **v1 assumption**: assistant explains the limitation in chat and provides an Apple Calendar deep link. We do not build a custom in-app invitation composer. If users churn on this, v1.1 is "promote them to Google Calendar."

4. **Is Composio durable enough as the v1 OAuth broker?** Mike's question. **v1 commits**: we ship on Composio, watch the failure modes during TestFlight, decide whether to invest in our own broker or stay on Composio for the public ramp.

5. **How do we surface what the assistant did?** Saul's content-type-vs-artifact framing. **v1 ships**: the capability-request card and the connection-granted acknowledgement as native chat content types. Whether richer renderings (a calendar week-view, an event card) ship as native content types or HTML artifacts is a v1.1 call once we see what assistants actually want to send back.

## Milestone 1 — Definition of Done

A TestFlight tester can complete every step below without engineering intervention. These are the regression tests; if any one fails, milestone 1 is not done.

### Setup and approval

1. New conversation with the assistant. Assistant asks for calendar access. Card renders both Apple and Google rows.
2. User taps **Connect on Apple Calendar** → grants iOS permission → card flips to Connected → assistant replies confirming.
3. New conversation. User taps **Connect on Google Calendar** → completes OAuth in the in-app web view → card flips to Connected → assistant replies confirming.
4. Both approvals coexist on the device; revoking one does not affect the other.

### Read operations (both providers)

5. *"What's on my schedule today?"* — assistant returns events in chat, sourced from the resolved provider.
6. *"Show me invites I haven't responded to."* — assistant returns the pending-invitation list. Empty case is handled gracefully ("you're all caught up").

### Create / update / delete (both providers)

7. *"Add a 9 AM standup tomorrow."* — assistant creates the event; user verifies it appears in the source calendar app.
8. *"Move it to 10 AM."* — assistant updates the event; user verifies the change.
9. *"Cancel it."* — assistant deletes the event; user verifies removal.

### Invitation surface (Google Calendar)

10. *"Invite Saul and Andrew to the standup."* — assistant adds attendees; Saul and Andrew receive Google Calendar invitations.
11. Pending invitation arrives for the user. *"Accept the standup invite."* — assistant RSVPs; sender sees acceptance.
12. *"Remove Andrew from the standup."* — assistant updates attendees; Andrew receives a cancellation.

### Invitation surface (Apple Calendar — graceful degradation)

13. *"Invite Saul to the standup"* on a conversation resolved to Apple Calendar — assistant creates/updates the event locally, replies in chat with the EventKit limitation explanation and a deep link to Apple Calendar so the user can finish the invite.

### Multi-calendar in one conversation

14. New conversation. Assistant asks for calendar access. User approves **both** Apple Calendar and Google Calendar.
15. *"What's on my schedule today?"* — assistant returns events from both calendars in one reply, each tagged by source.
16. *"Add a coffee with Saul at 3 PM tomorrow."* — assistant asks which calendar to put it in (first write of the conversation), user picks Google, event lands in Google. Subsequent writes in the same conversation default to Google without re-prompting.
17. User revokes Google from Conversation Info. Next write re-prompts (since the pinned provider is gone); the user can pick Apple or re-approve Google.

### Timezone

18. User in San Francisco. *"Remind me to take a break at 3 PM tomorrow."* — event is created as floating time; if the user flies to Paris before the reminder fires, it fires at 3 PM Paris time.
19. User in San Francisco. *"Set up our 9 AM standup with Saul on Tuesday."* — event is pinned to a specific timezone (Pacific by default for the user's location); does not drift if the user travels.
20. Pending invitation arrives from a sender in a different timezone. Assistant's reply translates the time into the user's current timezone for the user, alongside the original sender timezone.

### Conversation Info / revocation

21. User opens Conversation Info → Connections → toggles Calendar off. Next assistant request re-prompts the picker. The user can re-approve and continue.

### Concurrent decisions to lock in

- Composio is the v1 OAuth broker.
- TestFlight only, behind the existing debug-settings feature flag. Public ramp is a v1.1 decision.
- Apple Calendar invitation/RSVP limitations are surfaced honestly in the assistant's replies, not hidden.

## Not a milestone-1 criterion

- Microsoft Outlook support.
- Multi-calendar federation in one conversation.
- A dedicated Connections home tab (currently lives at the root of app settings).
- Custom in-app invitation composer.
- Calendar week-view artifact rendering.
- Subscription gating.
- Cross-device approval sync.
- Recurring-event series-vs-instance editing.
- Free/busy lookup across multiple participants.

## Risks worth flagging

- **EventKit's invitation surface is the single biggest product risk.** If users expect parity with Google and don't get it, the asymmetry feels like a bug. The assistant's reply quality on the "I couldn't send the invite" path is a v1 product surface, not an engineering nicety. We need to pressure-test it with non-engineers in TestFlight before any public ramp.
- **Composio dependency.** A single broker. If Composio has an outage during TestFlight, Google Calendar is dead for everyone. Acceptable behind a feature flag; not acceptable for public ramp without a contingency.
- **Rationale-text quality.** v1 lives or dies on whether the assistant's reasons for asking sound reasonable. The assistant's prompt that produces the rationale is a product surface — not just a parameter — and needs human review.
- **State sync between picker approval and Conversation Info toggle.** Two paths can flip the underlying enablement. The DOD step #14 is the regression test that proves they stay coherent.
- **Recurring events.** "Move the standup to 10 AM" on a recurring series is ambiguous (this instance? all future? all?). v1 assistant asks before acting; if the assistant fails to ask consistently, users will lose data. This is the most likely place for a v1 user-trust incident.

## Success signals (post-launch)

Read-out signals for the TestFlight cohort, not gating metrics.

- **Approval rate** of capability requests: Approve / Deny / ignored.
- **Provider mix**: of users who have both calendars linked, which one do they pick per conversation? (Tells us whether the asymmetry actually pushes users toward Google.)
- **Round-trip success** by operation: which of the eight operations work, which time out, which return errors.
- **Apple-Calendar fallback rate**: how often does the assistant hit the EventKit limitation path, and does the user follow the deep link?
- **Re-engagement after denial**: do users who deny once approve a later request from the same assistant?
- **Recurring-event mishaps**: any user reports of "the assistant deleted my whole standup series."

If approval rate is healthy, round-trip success is high, and recurring-event mishaps are zero, v1.1 expands the catalog (Outlook next, then non-calendar). If the EventKit limitation path is dominant, v1.1 leans harder on Google as the recommended provider. If approval rate is low, the next iteration is on assistant-side prompting and rationale quality, not on more connections.

---

## Appendix: how this maps to the engineering plan

The technical model — subjects, providers, resolutions, capability requests/results — is in [`capability-resolution.md`](https://github.com/xmtplabs/convos-ios/blob/dev/docs/plans/capability-resolution.md). The end-to-end UX walkthroughs are in [`capability-resolution-flows.md`](https://github.com/xmtplabs/convos-ios/blob/dev/docs/plans/capability-resolution-flows.md). This PRD is the product layer over those.

v1 picks a deliberate slice of the capability-resolution model: one subject (`calendar`), two providers (`device.calendar`, `composio.google_calendar`), **`allowsReadFederation: true` for `.calendar` capped at two providers per conversation, writes always single-provider** (per the existing federation rules — writes never federate). The four-verb model (`read`, `writeCreate`, `writeUpdate`, `writeDelete`) covers all eight user-facing operations once you map them: invitation send is `writeUpdate` on the attendees field, RSVP is `writeUpdate` on own status, pending-invitation list is `read` with a status filter. The `availableActions` payload returned on approval is what tells the assistant the specific verbs and parameter shapes for the resolved provider.

Timezone fields (device timezone, preferred timezone) live on the user's profile and ride along on every `ProfileUpdate` — they are not capability-gated, since they're metadata about the user, not access to a third-party system. Floating-vs-pinned event semantics are an assistant-side concern: the assistant emits the right calendar-action payload (timezone-attached or floating) based on its read of the user's intent.

Everything else in the resolution architecture — federation, manifest writer, cloud-provider registry sync — is wiring that's already paid for and ready when we add the next subject in v1.1.
