# Test: Scheduled Explode (In-App Expiration)

Verify that a conversation with a scheduled explosion is automatically cleaned up when the timer expires while the app is in the foreground. This tests the scenario where another device schedules the explosion and the app must detect the expiration in real time.

> **Single-inbox model (C9, ADR 004 amendment).** Under the single-inbox refactor, expiry no longer destroys the user's keychain or XMTP database — those are shared across all conversations. The cleanup is local: `expiresAt` is set in DB, the conversation is filtered out of the UI, and the user remains a member of the (now-empty-of-content) MLS group on the network. **Known asymmetry from the immediate-explode test (`09-explode-conversation.md`):** scheduled explosions do not currently fire `group.leaveGroup()` when the timer expires; only the immediate `explodeConversation` path does. Bringing scheduled explosions to full parity is tracked as future work in the ADR 004 C9 amendment.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.

## Setup

1. Create a conversation from the CLI (so the CLI user is the super admin with explode permission).

```bash
CONV=$(convos conversations create --name "Boom Test" --profile-name "Bomber" --json)
CONV_ID=$(echo "$CONV" | python3 -c "import json,sys; print(json.load(sys.stdin)['conversationId'])")
```

2. Generate an invite and have the app join via deep link.
3. Process the join request from the CLI (per invite ordering rules in RULES.md).
4. Send a few messages from both sides so the conversation has content and is clearly active.

## Steps

### Verify conversation is active

1. The app should be viewing the conversation (or navigate to it from the conversations list).
2. Verify the conversation name "Boom Test" is visible.
3. Verify messages are visible in the conversation.

### Schedule explosion from CLI

4. From the CLI, schedule an explosion ~15 seconds in the future. Compute the ISO8601 timestamp dynamically:

```bash
EXPIRES_AT=$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) + timedelta(seconds=15)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
convos conversation explode "$CONV_ID" --scheduled "$EXPIRES_AT" --force
```

### Verify scheduled state in app

5. The app should receive the ExplodeSettings message via the XMTP stream within a few seconds.
6. The explode button in the conversation toolbar should change to show a countdown (e.g., "Explodes in 0:12"). Look for the `explode-button` accessibility identifier with "Scheduled to explode" label.

### Wait for expiration

7. Keep the app in the foreground. Do not navigate away or background the app.
8. Wait for the scheduled time to pass (~15 seconds from when the explosion was scheduled).

### Verify automatic cleanup

9. The conversation should be automatically cleaned up when the timer expires. The app should navigate back to the conversations list (or show an exploded state).
10. Verify the conversation no longer appears in the conversations list. Search for the conversation name "Boom Test" — it should not be found.

## Teardown

No cleanup needed — the conversation is destroyed by the explosion.

## Pass/Fail Criteria

- [ ] Conversation is active and showing messages before explosion is scheduled
- [ ] App receives the scheduled explosion and shows countdown in the explode button
- [ ] Conversation is automatically cleaned up when the timer expires while the app is foregrounded
- [ ] Conversation no longer appears in the conversations list after expiration
- [ ] User's other conversations and profile remain unaffected after expiration (proves no keychain destruction)

## Accessibility Improvements Needed

(To be filled in during test execution if any elements are hard to find.)
