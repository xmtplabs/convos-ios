# Transient conversation engagement: one keep/discard predicate

Goal: stop the implicit dismiss-cleanup from deleting minted conversations the user has actually engaged with (renamed, customized, populated), while preserving the transient behavior for genuinely untouched drafts. iOS only.

## The bug

Repro: Home -> "+" -> "Show an invite code" -> rename the convo -> back/dismiss -> the renamed convo is deleted from home.

The Show-code flow mints a `NewConversationViewModel` with an embedded invite and commits a warm pool row visible immediately. Renaming goes through `ConversationMetadataWriter.updateName` (XMTP `group.updateName`, then the `DBConversation.name` save), but nothing informs the wrapping `NewConversationViewModel` and no flag is set. On dismiss, `cleanUpEmptyEmbeddedInviteIfNeeded` checks exactly four things: invite shared, code scanned, loaded message count, current other-member count. A rename (or photo/description/emoji change) touches none of them, so the fall-through calls `deleteConversation()` -> `SessionManager.discardClaimedConversation`, which denies consent, leaves the group, and deletes every database row. The rename is durable on the network before the local row is destroyed; there is no recovery path.

Root cause in one line: the dismiss-cleanup predicate has no metadata-customization signal, and the terminal discard has no engagement awareness at all.

The wider pattern: each keep-signal accumulated so far (`didShareInvite`, `didHandleScannedCode`, ready/joining state guards, the Agent Builder's `hasCommitted`) was added to fix one bug. Metadata customization is the next bug in the same series, which motivates a shared predicate rather than one more flag.

## Product rule

Keep a minted conversation if any of the following hold; otherwise it is a transient and is discarded on dismiss:

- it ever had two members, even if the second member later left;
- the user put content in it (a sent message);
- the user customized any metadata: name, description, or image (there is no per-conversation color in the schema, and the conversation emoji is auto-assigned -- see below);
- existing keeps: the invite was shared externally, or a scanned code was handled.

Explicit user deletes stay unconditional. Only implicit dismiss-cleanup goes through the engagement gate.

Unsent composer drafts do not count. Draft text lives only in memory (`ConversationViewModel.messageText`); there is no draft persistence. Counting a non-empty draft as engagement would keep the conversation but lose the draft, leaving an empty ghost row -- precisely the class of leftovers the lazy-mint work eliminated. If composer drafts ever gain persistence, a `.typedDraft` latch is a one-line addition.

## What the database gives us

- Fresh mint defaults: a pooled row is written with `name`, `description`, `imageURLString`, and `conversationEmoji` all nil (`UnusedConversationCache.writeUnusedConversationRow`). "New Convo" is a UI-only fallback, never materialized in the database. "Customized" is therefore detectable as non-nil, non-empty on the name, description, and image columns. All customization paths funnel through `ConversationMetadataWriter` and always persist to `DBConversation`.
- One exception, found during validation: `conversationEmoji` is auto-assigned to every minted conversation at creation (`ensureConversationEmoji` in the conversation state machine, seeded from the conversation id), so a non-nil emoji says nothing about user intent and is excluded from the predicate. There is no in-app emoji editor today; if one lands, it must latch engagement at the view-model layer, and the predicate can learn to compare against the auto-assigned value.
- Messages: real messages persist as `DBMessage` rows; membership changes persist as `contentType == .update` rows. The view-model-side message count only counts chat content (the `.messages` grouping in `MessagesListItemType`), so a database-side count must mirror that exclusion.
- Members: the members table mirrors current membership only. Departed members' rows are deleted on network sync (`ConversationWriter`) and on explicit removal (`ConversationMetadataWriter.removeMembers`). There is no "ever had two members" record in queryable columns, so a high-water mark is needed.

## Design: hybrid gate + latch

Two candidate shapes, each with a blind spot the other covers:

- Event flags on the view model (the existing pattern, extended): synchronous, fits the existing call shape, and latches at edit-commit time -- before the async write -- so it cannot lose the race where a rename's network commit precedes its database write. But it is exactly the mechanism that produced the bug series: every new customization surface must remember to wire a flag, and flags die with the view model.
- State derived from the database at cleanup time: one implementation protects every current and future path automatically, robust to view-model lifecycle and app kill. But the UI call sites branch synchronously, and a state check alone can race an in-flight rename write.

Chosen: hybrid. The database-derived predicate is the authoritative gate inside the terminal discard, and a thin synchronous latch on the view model covers the in-flight-write race.

1. `ConversationEngagement.isEngaged(db:conversationId:currentInboxId:)` in ConvosCore -- the single predicate: any of `name`/`description`/`imageURLString` non-nil and non-empty, real-message count greater than zero (excluding `.update` and other non-chat content types, mirroring the `.messages` grouping filter), non-self member count greater than zero, or `hasHadOtherMembers` true.
2. `SessionManager.discardClaimedConversationIfUnengaged(id:)` -- a new protocol method next to `discardClaimedConversation`. It checks the predicate before `updateConsentState(.denied)`: a kept conversation must never get consent-denied, or it vanishes from the list anyway. Engaged -> commit the claimed conversation (ensures visibility; safe if already committed) and return without deleting. Unengaged -> the existing discard body. The unconditional `discardClaimedConversation` stays for explicit user deletes and the Agent Builder's deliberate cancel.
3. On the view model, the flag pile (`didShareInvite`, `didHandleScannedCode`) consolidates into a single `EngagementLatches` OptionSet (`.sharedInvite`, `.scannedCode`, `.customizedMetadata`, `.memberJoined`), with the existing mark methods kept as facades so call sites do not churn. The `cleanUpEmptyEmbeddedInviteIfNeeded` keep-guard becomes: any latch set, or messages present, or other members present.
4. `.customizedMetadata` wiring: `ConversationViewModel` gains an `onMetadataEdited` callback, invoked synchronously (before spawning the write task, and only when a change will actually be written) from the name-edit branches and the pending public-preview name/description writes. `NewConversationViewModel` wires it in its inner view-model forwarding block so it survives inner-VM swaps, following the `onInviteShared` precedent.
5. `.memberJoined` wiring: latched in `ConversationViewModel`'s conversation-update observer when the non-self member set becomes non-empty. This covers joined-then-left within a session; the persisted flag below covers it across sessions.
6. All implicit discard call sites route through the guarded path: the embedded-invite cleanup fall-through, the generic `cleanUpIfNeeded` fall-through, and the superseded-claim discard (scanning a code that resolves into a different conversation must not destroy a renamed original). `deleteConversation()` keeps the unconditional discard as the explicit-delete entry.

With this, the rename bug is fixed twice over: the latch keeps the conversation at the UI predicate with no race, and even if a future surface forgets the latch, the session-level gate refuses to destroy a row whose database state shows engagement.

## "Ever two members" needs new state

Because departed members' rows are deleted on sync, there is no queryable high-water mark. Deriving one from persisted `.update` messages (added-member ids survive the member leaving) would avoid a migration, but requires decoding update JSON per row at discard time and depends on the stream echo having landed; a joiner added and departed during a brief network gap could be missed.

Chosen instead: an explicit set-once flag `hasHadOtherMembers` on `ConversationLocalState`. Local-only state can never be clobbered by network sync (avoiding the merge-preservation dance that synced fields need), and the discard path already deletes the row with the conversation. Direct precedent for a has-had flag: `hasHadVerifiedAgent`.

- Set points: `ConversationWriter`'s member-store path when the stored member set contains a non-self inbox, and `ConversationMetadataWriter.addMembers`.
- Migration: add the column defaulting false, backfilled true where a non-self `DBConversationMember` row exists.

The in-session latch makes the flag's timeliness non-critical; the flag exists for cross-session correctness (app killed after a member joined and left; discard decided on a later launch or by a different surface).

## Edge cases

- Rename to empty, or to empty then back: the name editor writes only when the trimmed value differs, so typing nothing over a nil name latches nothing (correct: not engagement). "Foo" then cleared back to empty ends with `name == ""` in the database, so the predicate must use non-nil and non-empty -- a reverted conversation found on a later launch is discardable again, while the session latch keeps it for this session (conservative keep; the user did act).
- Customize, then open share, then cancel: `onInviteShared` never fires, but `.customizedMetadata` keeps it. The Send-invite cancel paths are unchanged: the user never enters that hidden conversation, so customization is impossible there; cancel still discards, now with the gate as a backstop.
- Member joined then left: the in-session latch plus the persisted flag keep it, even though the current-member count reads zero at dismiss.
- A user literally typing "New Convo" produces a non-empty database name and is kept (they did act; fine).
- App kill mid-flow: no cleanup runs. Show-code rows were committed visible at claim, so the conversation (with any landed rename) persists. Deferred-visibility claims stay unused and are recycled by the pool next launch. Lost latches are harmless because latch-consulting cleanup never runs after a kill.
- Consent-deny ordering: the engagement check must precede `updateConsentState(.denied)`; deny-then-keep would hide the kept conversation from the list, which filters on allowed consent.
- Agent Builder cancel stays on the unconditional discard path: deliberate cancel semantics, and the builder writes no conversation metadata pre-commit anyway.
- The in-conversation join sheet uses `.joinInvite`-mode view models with no embedded invite; the embedded predicate no-ops and the joining-state guard governs, unchanged.

## Risks

- Consent-deny ordering (above) is the sharpest edge; covered by a unit test asserting a kept conversation's consent is not denied.
- `ConversationLocalState` migration breadth: several memberwise init sites plus hydration; mechanical, and the compiler catches misses, but `insert(onConflict: .ignore)` writes must not silently reset an existing true.
- Message-count semantics drift: the database count must match the view model's chat-only notion or the two layers of the predicate disagree; extract the filter, do not duplicate it.
- A rename write landing after an unengaged-verdict delete throws `conversationNotFound` inside `updateName` (logged, harmless, pre-existing shape); the latch makes this reachable only by paths with no UI.

## Validation

Unit coverage: the engagement truth table (fresh pool row not engaged; each metadata field set -> engaged; empty-string name -> not; one real message -> engaged; update-only rows -> not; `hasHadOtherMembers` -> engaged); the guarded discard (engaged -> row survives, stays visible, consent not denied; unengaged -> full deletion parity); the writer set points and the migration backfill.

Simulator checklist, the original repro first:

1. "+" -> Show an invite code -> rename -> dismiss: the renamed row stays in home, and survives relaunch.
2. Same with a photo or description instead of a rename -> kept.
3. "+" -> Show-code -> no interaction -> dismiss: no row remains (transient discard regression guard).
4. "+" -> Send an invite -> cancel the share -> no row; complete the share -> kept.
5. A second device joins via the invite then leaves; dismiss -> kept (ever-two-members).
6. Show-code -> rename -> scan a code that joins another conversation (supersede path) -> the renamed conversation is still in the list.
7. Kill the app after a rename -> relaunch -> conversation present.
8. Explicit delete still deletes an engaged conversation.
