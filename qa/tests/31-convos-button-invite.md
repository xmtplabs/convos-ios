# Test: Convos Button Invite

Verify that the Convos button in the media buttons bar creates a conversation and generates a shareable invite link that can be pasted into the message input.

> **Single-inbox model (C10).** Conversation creation now uses the singleton inbox rather than provisioning a fresh per-conversation one — there should be **no** "creating new inbox" UI. The shareable link format is unchanged (still the cryptographically-signed slug from ADR 001).

## Prerequisites

- The app is running and past onboarding.
- At least one existing conversation is open in the conversation view.

## Setup

Create a conversation from the app (tap compose, wait for the conversation to be ready).

## Steps

### Convos button appears and creates invite

1. In the conversation view, tap the chevron or media expand button to reveal the media buttons bar.
2. Verify the Convos button (orange Convos icon) appears alongside the photo library and camera buttons.
3. Tap the Convos button.
4. Wait for the invite link to appear in the message composer as a link preview card.
5. Verify the link preview shows a convos.org URL.

### Send the invite link

6. Type a message alongside the invite (e.g., "Join here!") or just tap send.
7. Tap the send button.
8. Verify the invite URL is sent as a message in the conversation.

### Invite link is functional

9. Copy the sent invite URL from the message.
10. On a second simulator or via CLI, join using the invite URL.
11. Process the join request.
12. Verify the joiner is added to a new conversation (not the current one — the Convos button creates a separate conversation).

### Clear pending invite

13. Tap the Convos button again to generate a new invite.
14. Before sending, tap the dismiss/clear button on the invite preview card.
15. Verify the invite preview is removed from the composer.

### Rapid tap protection

16. Tap the Convos button rapidly multiple times.
17. Only one invite should be generated — no duplicate pending invites or orphaned inboxes.

## Teardown

Explode any test conversations created during the test.

## Pass/Fail Criteria

- [ ] Convos button appears in the media buttons bar
- [ ] Tapping the Convos button generates an invite link in the composer
- [ ] The invite link can be sent as a message
- [ ] The invite link is functional — a second user can join via the link
- [ ] Clearing the pending invite removes it from the composer
- [ ] Rapid tapping does not create duplicate invites

## Accessibility Improvements Needed

- The Convos button uses `accessibilityIdentifier("convos-action-button")` — verify this is present and tappable.
