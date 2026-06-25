# Test: Long-Message Rendering and Detail View

Verify the two-tier long-message UX that fixes the dominant CoreText app-hang. Short messages render unchanged; long messages show a bounded preview with a Read More that expands inline; pathological (very long) messages show a bounded preview whose Read More opens a pushed MessageDetailView with working Back, Copy, and Reply. A no-hang guard confirms that opening a very long message keeps the UI responsive.

## Prerequisites

- The app is running and past onboarding.
- The convos CLI is initialized for the dev environment.
- The app and CLI are both participants in a shared conversation.
- The app is on the conversation detail screen.

## Setup

1. Reuse (or create) the shared conversation and navigate into it.

## Test data generators

The CLI has no "send long text" helper, so send pre-generated strings whose first ~40 characters contain a stable marker. Generate them with:

- Long (~800 chars, marker `LONG43B`; prose names the 500-char threshold so the
  in-sim text matches the current tuning):
  `python3 -c "print('LONG43B This message is over the five-hundred character preview threshold, so it shows a bounded preview with a Read more button that expands it inline. ' + 'It keeps going past five hundred characters but stays under the fifteen-hundred pathological threshold so it expands in place. '*5)"`
- Pathological (~3000 chars, marker `HUGE43C`):
  `python3 -c "print('HUGE43C ' + 'lorem ipsum dolor sit amet '*110)"`

Send each verbatim with `convos conversation send-text $id "$body" --env dev`. Target the bubble with `label_contains: "LONG43B"` / `"HUGE43C"` so matching uses a short substring, not the whole body.

## Steps

### Short message renders normally

2. CLI sends "Short hello 43A". It appears in full; there is no Read More affordance (`message-read-more-button` does not exist).

### Long message - Read More + inline expand

3. CLI sends the ~800-char `LONG43B` body. A truncated preview with a Read More button (`message-read-more-button`) appears.
4. Tap Read More. The message expands inline; the Read More button disappears; no detail view opens (`message-detail-view` does not exist).

### Pathological message - pushes detail

5. CLI sends the ~3000-char `HUGE43C` body. A truncated preview with a Read More button appears (the long bubble from step 4 is already expanded, so this is the only collapsed Read More on screen).
6. Tap Read More. The `MessageDetailView` opens (`message-detail-view`) with a back chevron (`message-detail-back-button`), a centered "Message" title, and Copy (`message-detail-copy-button`) / Reply (`message-detail-reply-button`) buttons floating at the bottom corners.

### Detail view actions

7. Clear the clipboard, tap Copy, and read the pasteboard. It contains the full body (marker `HUGE43C`).
8. Tap Reply. The detail view dismisses and the reply composer bar (`reply-composer-bar`) appears above the composer. Cancel the reply afterward.
9. Re-open the detail view (tap the `HUGE43C` Read More again), then tap Back. You return to the conversation with the composer (`message-text-field`) visible.

### No-hang guard

10. Re-open the detail view for the ~3000-char message; it must present within ~3s. A >= 2s main-thread hang would make the 3s wait time out and fail. There is no `[PERF]` marker for this transition; the timeout is the guard. Dismiss the detail view afterward.

## Teardown

Explode the conversation via CLI (optional; transient CLI errors do not fail the test).

## Pass/Fail Criteria

- [ ] Short message renders fully with no Read More.
- [ ] Long message shows Read More.
- [ ] Long message expands inline (Read More disappears, no detail view).
- [ ] Pathological message opens the detail view with Back, Copy, and Reply.
- [ ] Detail Copy copies the full body (containing `HUGE43C`) to the pasteboard.
- [ ] Detail Reply dismisses the detail view and reveals the reply composer bar.
- [ ] Detail Back dismisses the detail view and returns to the conversation.
- [ ] Opening a ~3000-char message presents the detail view within 3s (no hang).
