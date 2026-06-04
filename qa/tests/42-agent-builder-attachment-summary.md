# Test: Agent Builder Attachment Summary

Verify that creating an agent with a prompt and a photo attachment produces a post-Make summary card that renders both the prompt text and the photo thumbnail chip, and that the thumbnail survives re-entering the conversation.

## Prerequisites

- The app is running and past onboarding.
- The app is on the conversations list (Chats tab).
- The simulator photo library has at least one photo (the setup step seeds one).
- The backend agent-builder service is reachable for the environment under test (the agent must actually join after Make).

## Setup

1. Download a test photo (`https://picsum.photos/seed/builder42/600/400`) and add it to the simulator photo library with `simctl addmedia` if the library is empty.

## Steps

### Open the builder and stage inputs

1. Tap the agent builder bar at the bottom of the Chats tab (collapsed or expanded — either opens the builder). The builder composer should appear with the prompt text field and Make button.
2. Type a prompt into the composer text field: "Help me plan protein-packed recipes from this powder".
3. Tap the photo library button in the builder's media strip and pick the first photo. Allow photo library access if prompted. The staged photo should appear as a square chip with a remove button above the media strip — wait for the chip; the picker loads the image asynchronously.

### Make the agent

4. Tap Make. The composer morphs into the summary card pinned at the top of the new agent conversation; the footer reads "You created an agent". The agent's contact card slides in below once it joins.

### Verify the summary card

5. The summary card should show the prompt text.
6. The summary card's attachment chip (80pt rounded square under the prompt) should render the attached photo. A flat gray square means the thumbnail is missing — this is the known gray-chip bug (summary chip renders `Color.colorFillSubtle` when the persisted `AgentBuilderSummaryAttachment.photo` carries nil `thumbnailData`, even though the photo uploads and reaches the agent).
7. Check the app log (per log monitoring rules in RULES.md) for "AgentBuilder bundle: failed" or "AgentBuilder: pending media upload await failed" — either fails the bundle criterion. The agent joining and processing is the positive signal the bundle was delivered.

### Verify persistence across re-entry

8. Navigate back to the conversations list, then re-enter the agent conversation (the row may be titled by the agent's chosen name rather than the prompt).
9. The summary card should still show the photo thumbnail. The card is now rehydrated from the database rather than the in-memory commit plan — a gray chip here but not at step 6 isolates the bug to the persistence/rehydration path.

## Teardown

Navigate back to the conversations list. The agent conversation is left in place (no CLI handle to explode it); delete manually via swipe actions if a pristine list is needed.

## Pass/Fail Criteria

- [ ] Tapping the home builder bar opens the agent builder with composer and Make button
- [ ] Prompt text appears in the builder composer text field
- [ ] Picked photo appears as a staged attachment chip before Make
- [ ] Make creates the agent conversation and "You created an agent" appears under the summary card
- [ ] Summary card attachment chip renders the photo image, not a gray placeholder
- [ ] No "AgentBuilder bundle: failed" / "pending media upload await failed" errors in the app log
- [ ] Summary card photo thumbnail still renders after leaving and re-entering the conversation

## Accessibility Improvements Needed

- The summary card (`AgentBuilderSummaryView`) has no accessibility identifiers — the thumbnail check is a visual screenshot judgment. A per-chip identifier that distinguishes a rendered thumbnail from the gray fallback (e.g. `summary-photo-chip` vs `summary-photo-chip-placeholder`) would make the core criterion machine-checkable.
- The conversation row for a fresh agent convo has no stable identifier tied to the builder flow; re-entry relies on matching the agent's display name.
