# PRD: Contact List (Contacts MVP)

> **Status**: Draft (post-review revisions)
> **Author**: Cameron Voell
> **Created**: 2026-04-28
> **Updated**: 2026-04-30
> **Companion 1-pager**: [contact-list.md](./contact-list.md) — wireframes and strategic framing
> **Architecture review**: TODO — `swift-architect` agent

## Overview

Convos already has a contact list — it's smeared across every conversation. This feature names it: a local, GRDB-backed address book of every user the local user has shared a conversation with (and taken some explicit action with), keyed by `inboxId` under the single-inbox identity model ([ADR-011](../adr/011-single-inbox-identity-model.md)). Contacts are auto-populated when the local user takes an explicit action in a shared conversation, surfaced as a browseable list, navigable to a contact card, and reusable as a picker when starting new chats or adding members to existing ones.

The contact list also drives **inbound conversation filtering**: a new conversation arriving from an `inboxId` that is in the local user's contact list lands directly in the main feed; one from an `inboxId` that is not in the contact list is ignored (and dropped after a reasonable time window). This is the mechanism Convos uses to gate "who is allowed to message me directly," replacing today's external invite only paradigm.

**Two-step delivery.** This work ships in two discrete milestones:

1. **Step 1 — Populate and view the contact list.** Auto-add contacts on first explicit action in a shared group; add new group members on join; expose the contact list from the Convos top-left menu (linked under "My info"); for conversations outside the existing invite flow - apply inbound conversation filtering so only contacts can land new conversations in the main feed.
2. **Step 2 — Messaging and adding from contacts.** Add a contact picker UI for starting new conversations with one or more contacts; add members to existing groups from the picker; add a contact card with a "Send a message" CTA. The list of conversations shared with a contact, surfaced on the contact card, is a stretch item that may slip to a follow-up.

The implementation leans heavily on existing primitives — `DBConversationMember` already has the right shape and index, the member-profile system from [ADR-005](../adr/005-member-profile-system.md) already produces profile data, and `ConversationsRepository` already publishes reactive feed updates. The new surface area is a contacts table, a sync coordinator, an inbound-filter check, and a small set of UI screens.

## Problem Statement

Today, a user who wants to start a new conversation with someone they already know on Convos has to generate a new invite link and forward it to that user in an existing group chat or external channel. Furthermore, there is no "people I know" surface that collapses cross-group acquaintance into a single searchable list. Equivalently, a user who wants to add a known person to an existing group chat has no way to do so without either re-inviting them externally or finding a shared group and pulling them through that. The data exists locally — every conversation has a member roster — but it isn't named or surfaced, or directly actionable.

Separately, the inbound conversation surface today is **invite-flow-gated, not permissive**. The current gate at `StreamProcessor.shouldProcessConversation` (`ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift`, lines 713-739) lets a new conversation through only if (a) XMTP `consent == .allowed`, (b) the local user is the conversation creator, or (c) `consent == .unknown` and the local user has an outgoing join request for it via `InviteJoinRequestsManager`. Anything else is **silently dropped — never persisted**. In practice this means: the only conversations that land in the local DB today are ones the user created or joined via the Convos invite flow. A 1:1 DM sent directly to the local user's `inboxId` from someone the user has never invite-flow'd with is dropped on the floor (and DMs are not persisted as their own conversation rows in any case — they are used today purely as the transport for invite join-request payloads in `StreamProcessor.processMessage`, lines 184-311).

The contacts feature both **opens this up** and **adds a new gate**. We want known contacts to be able to message the local user directly without needing a fresh invite handshake every time. We do not want to roll back to a fully permissive default. The new filter is: a contact can land, a stranger cannot, regardless of whether an invite handshake happened.

Naming "contacts" as a first-class concept solves both problems at once. It unlocks profile-first navigation (tap a person, message them directly), removes redundant work from common flows (DM-from-group, add-known-person-to-chat), and serves as the gating set for inbound conversations — anyone in the contact list can message the local user directly; everyone else is held or rejected. It also creates a foundation that later features (cross-device backups, mentions, message forwarding) can build against.

## Goals

### Step 1 — Populate and view

Step 1 is purely additive: build the contact list, keep it accurate, and let the user browse it. No behavior changes for existing users — no filtering, no blocking, nothing that affects what lands in the main feed.

- [ ] **Local contact list.** A GRDB-backed table of contacts, keyed by `inboxId`, populated by explicit action in shared conversations, queryable in an alphabetical list.
- [ ] **Auto-add on first explicit action in a group.** When the local user joins a new group via invite, the other members are added to the contact list **as soon as the local user sends their first message in that group** — not on join. This treats sending a message as the explicit "I want to be in this conversation" signal.
- [ ] **Auto-add new members of existing groups.** When the local user is already in a group and a new member joins, that new member is added to the contact list immediately.
- [ ] **Contact list entry from the Convos menu.** The contact list is reachable from the Convos top-left menu (the same menu that surfaces "My info", "Assistants", "Customize", etc.), placed under the "My info" row. There is **no** new toolbar icon on the conversations list.

### Step 2 — Messaging, filtering, and blocking

Step 2 is where the contact list starts gating behavior. It introduces messaging from contacts, the contact-gated inbound filter, and blocking. By landing all behavior changes together in one step, we avoid shipping a silent filter without giving users the messaging-from-contacts affordance that motivates it.

- [ ] **Contact card.** Tap a contact to see their profile (name, avatar, bio) and a "Send a message" CTA that lets the local user start a new conversation with that contact.
- [ ] **Contact picker for new conversations.** From the contact card "Send a message" CTA, or from a top-level "new conversation" affordance, the local user picks one or more contacts to start a new conversation with. The picker uses the design with a "To: <bubbles>" header that fills with selected names, a Favorites section, an alphabetical-only main list, and a side-letter index (matching the attached UI mock).
- [ ] **Messaging from a contact card.** "Send a message" on a contact card opens the picker pre-populated with that contact selected; the local user can confirm to start a 1:1 or add additional contacts before sending.
- [ ] **"Add from Contacts" in chat plus-menu.** Reuses the picker UI scoped to a destination chat — members already in are inline-disabled with an "in chat" badge — and adds the chosen contacts via the existing `addMembers` flow.
- [ ] **Inbound conversation filtering — opens up the invite-flow gate while adding a contacts gate.** Today, the only inbound conversations that survive `StreamProcessor.shouldProcessConversation` are those that came through the Convos invite flow (or that the local user created). With this feature, a new inbound conversation is also accepted if the sender's `inboxId` is in the local user's contact list at delivery time. If the sender is not a contact and the conversation also did not come through an invite, it is held in a quarantine area and dropped after a configurable window (target: 7 days). If the sender is a blocked contact, the conversation is rejected outright. The invite-flow path (today's behavior) continues to work unchanged.
- [ ] **Main feed unchanged.** No new "added you" badge on the home conversation list — same icons for unread messages, same row layout. The filtering is invisible in the happy path.
- [ ] **Block.** A user can block a contact. Blocking causes any future inbound conversation invitations from that user to be ignored (does not delete existing conversations; per-conversation removal is a separate affordance).
- [ ] **No regressions.** All existing conversation, profile, and invite flows continue to work unchanged. Auto-add never blocks or slows the message-send path; the new filter never breaks the existing invite-flow path.
- [ ] **Shared-conversations list on contact card** *(stretch).* The contact card surfaces every active conversation the local user shares with the contact, sorted by recency. This is the lowest-priority Step 2 item and may slip to a Step 2.5 follow-up.

## Non-Goals

- **No discovery / global directory.** A user can only contact someone they've already shared a conversation with and acted in. No "people you may know."
- **No cross-device sync.** Contacts live in local GRDB only for MVP. A future integration with the backups system is anticipated; the schema should be forward-compatible but the durability layer is explicitly out of scope.
- **No server-side contact graph.** No backend storage of contacts, no server queries, no recommendations.
- **No "added you" badge on the main feed.** Per review feedback, the main conversation list keeps its current visual treatment. Inbound filtering happens before a conversation reaches the main feed; there is nothing to badge once it's there.
- **No new toolbar icon on the conversations list.** The contact list is reached only from the Convos top-left menu.
- **No multi-inbox support.** Contacts assume the single-inbox model from ADR-011. If Convos ever returns to multi-inbox, contacts as designed will not be forward-compatible without rework.
- **No manual contact-add UI.** Contacts are populated only by acting in shared conversations. There is no "add a contact by inboxId / address" flow.
- **No per-contact muting, pinning, or notification settings.** Out of scope for MVP.
- **No recency-sort or recency-filter on the picker.** V1 is alphabetical only. Recency-aware sort is a follow-up.
- **No mid-group blocking.** "Block" affects future inbound conversation invitations from that user; it does not silence their messages within an existing shared group. That tradeoff (block-in-group) is explicitly TBD and tracked as an open question.

## User Stories

### Step 1 stories

#### As a user joining a Convos group via invite link, I want the other participants added as contacts when I start engaging with the group, so that I can later message them directly without re-discovering them — but I don't want to add strangers as contacts merely by being invited into a group with them.

Acceptance criteria:

- [ ] After accepting an invite to a group of N members, my contacts list does **not** change until I send my first message in the group.
- [ ] The instant I send my first message in the group, the other N − 1 members are added to my contact list within 2 seconds.
- [ ] The new contacts have their display name and avatar resolved from the most recently received member-profile data on the device; no contact appears with placeholder data if any profile was available.
- [ ] If I leave the group later, the contacts remain — they're tied to having shared a conversation I acted in, not to current membership.

#### As a user already in a group, I want anyone newly added to the group to become a contact automatically, so that the contact list stays current.

Acceptance criteria:

- [ ] When a new member joins a group I am already a member of and have already acted in, that member is added to my contact list within 2 seconds of the local member-add event being processed.
- [ ] The contact's source-group attribution (`addedViaConversationId`) is set to that group.

#### As a user, I want to see my contact list from the top-left menu, so that I can browse the people I've talked to without leaving the home screen.

Acceptance criteria:

- [ ] Tapping the "Convos" capsule in the top-left of the home screen opens the existing menu; a "Contacts" entry appears under "My info".
- [ ] Tapping "Contacts" opens a list view of all contacts, alphabetical by display name.
- [ ] The list does not need search in V1 (alphabetical-only is acceptable); search is optional polish.
- [ ] Tapping a contact opens the contact card. For Step 1, the contact card is a placeholder with the contact's profile and a back button — no "Send a message" CTA, no block / unblock.

### Step 2 stories

#### As a user, I want to start a new conversation with one or more existing contacts.

Acceptance criteria:

- [ ] From a top-level "new conversation" affordance, the picker opens with no contacts pre-selected.
- [ ] The picker has a "To" header bubble that fills with each selected contact's name as I tap them (matching the attached UI mock).
- [ ] A Favorites section appears at the top above the alphabetical list.
- [ ] The main list is alphabetical-only (no recency sort) with a side-letter index.
- [ ] After selecting at least one contact, the CTA to send the first message becomes enabled.
- [ ] The new conversation is created with the selected participants. Recipients only receive the message if they have not blocked the local user *and* have already acted in some shared group with the local user (i.e., the local user is in their contact list too); the UI does not need to expose this caveat in V1 but the behavior should be documented for support.

#### As a user viewing a contact card, I want a one-tap path to message that contact.

Acceptance criteria:

- [ ] The contact card shows the contact's profile and a "Send a message" CTA.
- [ ] Tapping the CTA opens the picker with that contact pre-selected; I can confirm immediately or add other contacts before sending.

#### As a user adding a known contact to an existing group chat, I want to pick from my contacts without manually inviting them.

Acceptance criteria:

- [ ] In the chat plus-menu, "Add from Contacts" appears as a row alongside Invite link and Convo code.
- [ ] Tapping it opens the picker scoped to the destination chat: people already in the chat are shown inline alphabetically, dimmed, with an "in chat" badge instead of a checkbox.
- [ ] Multi-select with the same "To" header bubble; the bottom CTA reads "Add N to convo" and is disabled when N = 0.
- [ ] Selected contacts are added to the chat via the existing `addMembers` flow; they receive a profile snapshot per the existing profile-system contract.

#### As a user, I want to receive direct messages only from people I have already chosen to interact with, so that strangers cannot land messages in my main feed.

Acceptance criteria:

- [ ] An inbound conversation (welcome) from an `inboxId` that is in my contact list is delivered to the main feed within the same time budget as today, even if no Convos invite handshake occurred.
- [ ] An inbound conversation from an `inboxId` that is not in my contact list and that did not come through the Convos invite flow is held (persisted but not surfaced in the main feed) and dropped after 7 days.
- [ ] If a held conversation's sender becomes a contact within the 7-day window (because we share a group and I act in it), the held conversation is promoted to the main feed.
- [ ] An inbound conversation that did come through the Convos invite flow continues to land as it does today, regardless of contact status. (Regression guarantee.)
- [ ] No UI is shown for the held / quarantined conversations in V1.

#### As a user, I want to block someone, so that they cannot start new conversations with me even if we share a group — and if I unblock them later, I want to recover any conversations they invited me to during the block.

Acceptance criteria:

- [ ] From the contact card, I can mark a contact as blocked.
- [ ] Once blocked, any *new* inbound conversation (welcome) from that user is held in quarantine: persisted to the local DB but not surfaced in the main feed, unread counts, badges, or notifications. From the user's perspective the conversation does not exist while the block stands.
- [ ] When I unblock the contact, the next `QuarantineSweeper` run (within an hour, or sooner via the foreground-entry trigger) promotes any conversations they invited me to during the block period back to the main feed. I see the conversation and the messages that were sent while I had them blocked.
- [ ] If I never unblock within the TTL window (default 7 days), the held-by-block conversations are deleted with no further user-visible effect.
- [ ] Blocking does not retroactively quarantine an existing accepted conversation. The `consent == .allowed` short-circuit in the filter ensures past-accepted convos continue to deliver normally even when the sender is currently blocked.
- [ ] Blocking does not delete existing shared conversations (per-conversation removal is a separate affordance).
- [ ] Blocking does not silence messages within an existing shared group conversation (TBD, tracked in open questions).

#### As a user viewing a contact card, I want to see every conversation I share with that person *(stretch — may slip to follow-up)*.

Acceptance criteria:

- [ ] The contact card lists every active conversation (DM and group) the local user and the contact are both currently members of, sorted by most recent activity.
- [ ] Each conversation entry shows the conversation's name, last-message timestamp, and last-message preview (matching the main-feed treatment).
- [ ] Tapping a conversation entry opens that conversation.

#### As a user tapping a member's avatar inside a group, I want the same contact card I see from the contacts list — augmented with the group-specific actions — so I have one consistent surface for "info + actions for this person."

Today, tapping a member's avatar inside a chat opens `ConversationMemberView`, a separate screen with only Remove and "Block and leave" actions. The contact card from the contacts list (Phase 2.4) has Send-a-message and Block / Unblock. Maintaining two surfaces for "view this person" is a fragmentation we should retire. Phase 2.8 unifies them: the same `ContactCardView` renders both entry points, with a mode flag that adds the group-specific actions when the entry point is a chat.

Acceptance criteria:

- [ ] Tapping a member's avatar inside a conversation opens `ContactCardView` (the same component used in the contacts list) with the conversation context.
- [ ] In conversation context, the card shows: Send a message, Block / Unblock, Remove from convo (admin-only), Block and leave (writes `blockedAt` AND leaves the group).
- [ ] When the tapped member is the current user, the card routes to "My info" rather than the contact card (no behavior change for self).
- [ ] When the contact is a verified agent, agent-specific affordances (Get skills, Learn about assistants) appear above the standard contact actions in **both** modes — the contacts list and the chat member-tap. Today's `ConversationMemberView` behavior is preserved AND extended to the contacts-list entry point.
- [ ] When the tapped member is not yet in the local contact list, the "Send a message" CTA is still shown. Tapping it performs a single-person `ContactsWriter.upsertContact` for that member's `inboxId` (with `addedViaConversationId = <this conversation>`) and then opens the picker pre-selected with them. The rest of the group's members are *not* added — only the tapped member, because the explicit action here is per-person, not per-group. (This narrower auto-add path is distinct from the per-group "send a message" trigger in Step 1.)
- [ ] No regression: today's "Remove" and "Block and leave" continue to work with identical effect; existing accessibility identifiers (`remove-member-button`, `block-member-button`) are preserved.

#### As a user whose contacts have names, I want member-name fallbacks across in-group surfaces — system messages, members list, mentions — to use my contact's display name when the member is one of my contacts and hasn't yet published their per-conversation profile.

The expectation is that people who join a group will update their profile name right away. In practice there's a gap: we invite someone we already have as a contact, they accept the invite via the join flow, but they haven't yet sent their profile snapshot — or they have, and it hasn't propagated to this device yet. During that window, every in-group surface that names them falls through to `Profile.displayName`'s "Somebody" sentinel, even though we have a stored display name for them on the contact row.

Phase 2.9 closes that gap with a stopgap fallback: when an in-group render site would emit "Somebody," it first checks the contacts list. The user already named this person; we should use that name until the canonical per-conversation profile arrives.

Acceptance criteria:

- [ ] System messages rendering a member name (join / leave / added-by / removed-by / role change / name change) that would otherwise emit "Somebody" use the contact's `displayName` instead when the inbox is a known contact (e.g. "Alice joined this convo," "Alice was added by Bob").
- [ ] The members list (`ConversationMembersListView`) shows the contact's display name for any member whose per-conversation profile name is empty.
- [ ] Mention strings, typing-indicator labels, and other in-group contexts that today fall through to `Profile.displayName` get the same fallback.
- [ ] **Per-conversation profile always wins.** The contacts-list lookup is a fallback **only** when the per-conversation profile name is empty/missing. If the per-conversation profile has a name, the renderer uses it verbatim — no contact lookup, no override. Per-conversation profile remains the canonical source for in-conversation rendering (ADR-005).
- [ ] When the per-conversation profile finally arrives (member sends their profile snapshot), it takes precedence on the next render — no stale contact-name persistence.
- [ ] When the inbox is **not** in the contacts list (e.g., a stranger who joined a group the local user has never acted in), the existing "Somebody" sentinel is preserved.
- [ ] The fallback is read-only — looking up a contact for rendering does **not** auto-add or modify any contact rows.
- [ ] Out of scope for V1: surfaces outside the conversation view that don't have direct repo access — push notification copy and any in-NSE rendering. Those keep their current behavior; a later phase can adopt the resolver if the contacts repo is plumbed into those targets.
- [ ] Performance: the contacts lookup is an indexed point read (primary key `inboxId`). The fallback path runs only when the per-conversation name is empty/missing, so it is not on the hot rendering path for the common case.

Wireframes are in `contact-list-mocks/`; the picker design is updated to match the new mock attached to the post-review feedback (see "picker" entry below). The MVP surfaces, mapped to the two delivery steps:

| # | Step | Screen | View / VM | Entry point |
|---|---|---|---|---|
| 1 | Step 1 | Convos menu — "Contacts" entry | Existing menu (one new row under "My info") | Tap "Convos" capsule on home; menu opens |
| 2 | Step 1 | Contacts list (browse, alphabetical) | `ContactsView` / `ContactsViewModel` | "Contacts" entry in Convos menu |
| 3 | Step 1 / Step 2 | Contact card | `ContactCardView` / `ContactCardViewModel` | Tap row in screen 2. Step 1: profile-only placeholder. Step 2: adds "Send a message" CTA and (stretch) shared-conversations list. |
| 4 | Step 2 | Contact picker (new conversation, multi-select) | `ContactsPickerView` / `ContactsPickerViewModel` | Top-level "new conversation" affordance; "Send a message" CTA on contact card; "Add from Contacts" row in chat plus-menu (scoped mode) |
| 5 | Step 2 | "Add from Contacts" in chat plus-menu | Existing chat plus-menu (one new row) | + button in chat header |
| 6 | Step 2 | Contact card scoped to a conversation (replaces `ConversationMemberView`) | `ContactCardView` with new `ContactCardMode.scopedToConversation(...)` | Tap a member's avatar inside a chat |

**Picker design (screen 4)** — matches the attached mock:

- A pill-shaped "To" header at the top that fills with each selected contact's name as a small bubble; a hamburger / disclosure button on the right edge of the pill.
- A "Favorites" section below the header (forward-compatible: V1 may render this section empty if no favorites concept exists yet, or seed it from a simple "most-recently-messaged contacts" heuristic — defer to designer pass).
- An alphabetical main list with section headers ("ABC", letter sections), each row showing avatar, name, and a sub-label (e.g., "DM" for 1:1, group name for group-derived attribution).
- A right-edge alphabetical index strip (★ A B C … Z #) for fast scrolling.
- Selected rows show a filled checkmark on the right; unselected rows show no indicator.
- In **scoped (add-to-chat) mode**, members already in the destination chat are inline-disabled with an "in chat" badge instead of a checkbox.

**Browse list (screen 2)** — simpler than the picker:

- Same alphabetical sectioning + side-letter index.
- No "To" header pill; no Favorites section in V1 (a single alphabetical list is fine — Favorites can come later when we add per-contact metadata).
- Tapping a row opens the contact card (screen 3).

**Contact card modes (screens 3 and 6)** — one component, two entry points:

- `ContactCardMode.standalone` — the card rendered from the contacts list (screen 3). Sections: avatar / name / bio, agent links (Get skills, Learn about assistants) when `contact.agentVerification?.isVerified == true`, "Send a message" CTA (opens picker pre-selected), Block / Unblock.
- `ContactCardMode.scopedToConversation(conversationId, canRemoveMembers, isCurrentUser)` — the card rendered from a member tap inside a chat (screen 6). Same standalone sections, plus a group-actions section: "Remove from convo" (gated on `canRemoveMembers && !isCurrentUser`), "Block and leave" (gated on `!isCurrentUser` — writes `contactsWriter.block(inboxId:)` *before* the group-leave so the inbound filter from Phase 2.6 honors the block on subsequent welcomes).

The split mirrors the picker's `ContactsPickerMode` pattern. Both modes share the avatar / name / bio header, the Send-message + Block-only affordances, and the verified-agent rows, so consistency is automatic.

**Agent-status on contacts.** For the verified-agent rows to appear on the standalone card, the `Contact` presentation model exposes `agentVerification: AgentVerification?`, sourced from a new `DBContact.agentVerification` JSON column. `nil` means "we have no agent signal for this inbox yet" (existing rows after migration); `.unverified` and `.verified(...)` are observed states. The verified-agent gate uses `?.isVerified == true`, so `nil` and `.unverified` both hide the rows correctly. The contact-sync coordinator and profile-sync writer populate the field from the per-conversation member-profile data they already see; no new XMTP read path. See Phase 2.8 for the migration + writer-update steps.

**Send-message on a non-contact (chat member-tap).** Tapping "Send a message" on a member who is not yet in the contacts list performs a *narrow, person-specific* `ContactsWriter.upsertContact` for just that inbox before opening the picker. This is intentionally narrower than the Step 1 group auto-add: the user's intent is to message this specific person, not to enroll the whole room. The same single-person upsert keeps the rest of the picker / starter flow unchanged.

**Member-name resolution with contact-list fallback (Phase 2.9).** Today every render site for a member's display name funnels through `Profile.displayName`, which falls back to the literal "Somebody" when the per-conversation `name` field is empty. The contact-list fallback inserts itself between those two: per-conversation `name` (if present) → contacts-list `displayName` (if the inbox is a known contact) → "Somebody" (last resort). The lookup is read-only and sub-millisecond — `contactsRepository.fetchContact(inboxId:)` is a primary-key point read.

This is explicitly a **stopgap** for the window between "we invite a contact" and "their profile snapshot arrives on this device." The expected-and-still-canonical flow is: a member joins, sends their profile snapshot, every device renders by the per-conversation profile thereafter. The fallback exists only to bridge the gap. Once a per-conversation profile is observed for an inbox, the stopgap stops firing for that inbox in that conversation — no stale contact-name persistence, no override.

Surfaces that adopt the fallback in V1: in-group system messages (join / leave / added-by / role change / name change), the members list, mention strings, and typing-indicator labels — anywhere a remote member's name would otherwise be "Somebody" inside the conversation view. Surfaces that *don't* adopt it for V1: push-notification copy and any rendering inside the NSE / app extensions, where the contacts repository isn't plumbed in. Those keep their existing "Somebody" behavior pending a follow-up that wires the repo into those targets.

**Component reuse:** screens 2 and 4 share `ContactRow`, alphabetical sectioning, and the side-letter index. Implement as one `ContactRow` view + one `ContactsList` container that takes a mode (`.browse`, `.pickerForNewConversation`, `.pickerScopedToConversation(conversationId)`); the mode parameterizes the header (none / "To" pill), Favorites visibility, tap behavior, "in chat" disable rules, and bottom CTA.

**Inbound filtering is invisible (Step 2).** When the contact-gated filter ships in Step 2, the main conversations feed continues to render exactly as today — no badge, no banner, no requests tray. Held / quarantined inbound conversations are persisted but hidden from the feed query. Step 1 does not change main-feed behavior at all.

**Open visual questions** (deferred to designer pass):

- What populates the Favorites section in V1 (empty / heuristic / explicit favoriting affordance).
- Empty state for a contact with zero remaining shared conversations on the contact card.
- Whether to surface a "blocked" indicator on the contact list row, or only inside the contact card.
- Whether the picker should section off "already in this chat" members at large group sizes (the inline-disabled treatment is fine for groups up to ~10; beyond that we may want to revisit).
- Final placement of "Block" affordance on the contact card.

## Technical Design

### Architecture

The feature lives almost entirely in `ConvosCore`, with thin SwiftUI views in the main app. No new MCP-style protocols needed; no new platform dependencies. ConvosCore must continue to compile on macOS — no `UIKit` imports.

**New components — Step 1:**

- `DBContact` (GRDB record) — the contacts table. Stores a denormalized "global default profile" (most-recent-wins). Step 1 ships *without* the `blockedAt` column; Step 2 adds it via a separate migration.
- `DBConversationContactsSync` (GRDB record) — per-conversation marker tracking whether the contact-sync coordinator has run for that conversation.
- `ContactsRepository` / `ContactsRepositoryProtocol` — reactive read API; publisher for the alphabetical list and `isContact(inboxId:)` lookup. (`isBlocked(inboxId:)` is added in Step 2.)
- `ContactsWriter` / `ContactsWriterProtocol` — write API; idempotent upsert and profile-snapshot writes. (Block / unblock writers added in Step 2.)
- `ContactSyncCoordinator` — single entry point for "ensure all non-self members of this conversation are contacts." Wraps `ContactsWriter`; idempotent.
- `ContactsProfileSyncWriter` — listens for member-profile / profile-snapshot events and updates `DBContact` profile fields per most-recent-wins.
- `ContactsView` (browse) and a placeholder `ContactCardView` (profile + back, no actions).
- `ContactsViewModel`, `ContactCardViewModel` — `@Observable` view models per current convention.

**New components — Step 2:**

- `addContactBlockedAt` migration — adds the `blockedAt` column to `contact`.
- `addConversationQuarantineFields` migration — adds `quarantinedAt`, `quarantineReleasedAt` to `conversation`.
- `InboundConversationFilter` — extends the existing `StreamProcessor.shouldProcessConversation` gate with contact-list and block-list checks; returns `.deliver | .quarantine | .reject`.
- `QuarantineSweeper` — periodic / launch-time job that drops quarantined conversations whose hold window has expired, and promotes any whose senders have since become contacts.
- `ContactsPickerView` and the full `ContactCardView` (with "Send a message" CTA and block / unblock affordance).
- `ContactsPickerViewModel`.

**Hook surfaces:**

- **First-message-sent in a conversation** (Step 1, primary auto-add trigger) — at the point where the local user's outbound message is persisted, if it's the first outbound message the local user has sent in that conversation, run the contact-sync coordinator on that conversation. Implementation hook: in the message-send path inside `MessagesWriter` (or equivalent), check whether the conversation already has a `conversation_contacts_sync` row before / after the message persists; if not, enqueue the sync. Replaces the old hook sites in `StreamProcessor.processConversation` and `InviteJoinRequestsManager.processJoinRequest`.
- **`ConversationMetadataWriter.addMembers()`** (Step 1, secondary trigger) — after `DBConversationMember` rows are persisted for an existing group the local user has already acted in, run the coordinator with `force: true` to pick up new members.
- **Inbound conversation arrival** (Step 2, filter site) — `StreamProcessor.shouldProcessConversation` is the existing chokepoint at `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` lines 713-739, called from `processConversation` (lines 140-145) before any DB persistence. The new `InboundConversationFilter` plugs in *here* in Step 2, extending the existing consent + invite-flow logic with a contact-list and block-list check. See the dedicated section below. Step 1 does **not** touch this site.

The coordinator does not block its caller — it is `async` but fire-and-forget from the hook sites (errors logged to `Logger.error`, no UI surface for failure).

### Data Model

#### `DBContact`

The contacts table. Keyed by the contact's `inboxId`. Stores a denormalized "global default profile" (display name, avatar, bio) updated on a most-recent-wins basis whenever we observe a member-profile event for that inbox. Per the post-review feedback: *"Contact = inbox, profile = whatever we heard about most recently for that inbox ID."*

The full struct (post-Step 2):

```swift
struct DBContact: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "contact"

    let inboxId: String                 // Primary key — see ADR-011
    let addedAt: Date                   // When the contact was first auto-added
    let addedViaConversationId: String? // The conversation that triggered the original auto-add (informational)

    // Most-recent-wins profile snapshot
    var displayName: String?
    var avatarURL: String?
    var bio: String?
    var profileUpdatedAt: Date?         // Timestamp of the source event we last accepted

    // Blocking — added in Step 2
    var blockedAt: Date?                // Non-nil ⇒ blocked

    enum Columns: String, ColumnExpression {
        case inboxId, addedAt, addedViaConversationId
        case displayName, avatarURL, bio, profileUpdatedAt
        case blockedAt
    }
}
```

Migrations are split between Step 1 (base table + profile snapshot) and Step 2 (`blockedAt`):

```swift
// Step 1 — Phase 1.1
migrator.registerMigration("createContactTable") { db in
    try db.create(table: "contact") { t in
        t.column("inboxId", .text).notNull().primaryKey()
        t.column("addedAt", .datetime).notNull()
        t.column("addedViaConversationId", .text)
            .references("conversation", onDelete: .setNull)
        t.column("displayName", .text)
        t.column("avatarURL", .text)
        t.column("bio", .text)
        t.column("profileUpdatedAt", .datetime)
    }
    try db.create(index: "idx_contact_displayName", on: "contact", columns: ["displayName"])
}

// Step 2 — Phase 2.1
migrator.registerMigration("addContactBlockedAt") { db in
    try db.alter(table: "contact") { t in
        t.add(column: "blockedAt", .datetime)
    }
}
```

In Step 1, the `DBContact` struct should omit the `blockedAt` field; it is added together with the alter-table migration in Step 2. Tests against the Step 1 build should not reference blocking.

The contacts table does not foreign-key the `member` row directly — a contact survives the local user leaving every shared conversation. `addedViaConversationId` uses `onDelete: .setNull` so deleting the source group does not cascade-delete the contact.

#### `DBConversationContactsSync`

Tracks whether the contact-sync coordinator has run for a given conversation. Same shape as before:

```swift
struct DBConversationContactsSync: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "conversation_contacts_sync"

    let conversationId: String
    let contactsSyncedAt: Date

    enum Columns: String, ColumnExpression {
        case conversationId, contactsSyncedAt
    }
}
```

Migration is unchanged from the original draft.

#### Inbound conversation quarantine *(Step 2)*

Inbound conversations whose sender is not a contact at delivery time are persisted but hidden from the main feed. This is a Step 2 concern — Step 1 does not change inbound-conversation persistence behavior. Two implementation options:

- **Option A (preferred):** Add nullable `quarantinedAt: Date` and `quarantineReleasedAt: Date` columns to the existing `conversation` table. The main-feed query filters out rows where `quarantinedAt IS NOT NULL AND quarantineReleasedAt IS NULL`. Simple, no new table.
- **Option B:** A separate `quarantined_conversation` table keyed on `conversationId`. Cleaner separation, but requires another join.

We start with Option A. The quarantine TTL is configured as a `Constant` (default 7 days). The `QuarantineSweeper` runs at launch and on a 1-hour timer while the app is foregrounded:

1. For each row with `quarantinedAt IS NOT NULL AND quarantineReleasedAt IS NULL`:
   - If the sender is now in `contact` and not blocked → write `quarantineReleasedAt = now` (promotes to feed).
   - Else if `now - quarantinedAt > QuarantineConstant.ttl` → delete the conversation row (and its messages) and record a debug-only log.
2. No UI surfacing for quarantined conversations in V1.

Migration:

```swift
migrator.registerMigration("addConversationQuarantineFields") { db in
    try db.alter(table: "conversation") { t in
        t.add(column: "quarantinedAt", .datetime)
        t.add(column: "quarantineReleasedAt", .datetime)
    }
}
```

#### Indexes

Existing `conversation_members` already has `(inboxId, conversationId)` index — used by the contact card (Step 2) for shared-conversations lookup. The new `idx_contact_displayName` index supports the alphabetical list-paint path.

### Profile Resolution (most-recent-wins)

The post-review feedback resolved the per-conversation-profile ambiguity: *"Contact = inbox, profile = whatever we heard about most recently for that inbox ID."*

We replace the original at-query-time heuristic with a denormalized profile snapshot on `DBContact`, updated on a most-recent-wins basis:

- A `ContactsProfileSyncWriter` listens for events that yield new profile data for a known `inboxId`:
  - `DBMemberProfile` writes (existing per-conversation profile delivery).
  - Profile snapshots received via the existing profile-snapshot codec on conversation join.
  - Profile updates received in-band (e.g., `ProfileUpdate` codec messages).
- The writer treats each timestamped snapshot as one authoritative unit. If the snapshot's timestamp is greater-than-or-equal to `DBContact.profileUpdatedAt`, the writer wholesale-replaces every profile field on the row (`displayName`, `avatarURL`, `agentVerification`, `profileUpdatedAt`) with the snapshot's values, including `nil`s. There is no per-field merging: a newer snapshot with `avatarURL: nil` clears the stored avatar. This matches the `ProfileUpdate` wire-format contract, where a message without a name or encrypted image clears the sender's profile.
- Older snapshots are dropped from the contact-update path (the `member_profile` table still stores them for in-conversation rendering).
- "Newer" is decided by the source event's authoring timestamp. If the source has no timestamp, the snapshot is "fill-defaults" data from a local hydration site; it only seeds new contact rows and leaves existing rows untouched.

This keeps `DBContact` thin, eliminates the at-query-time heuristic, and makes the contact list render on a single primary-key-indexed read with no joins. The contact card (Step 2) and picker render the contact's `DBContact` snapshot; in-conversation rendering continues to use `DBMemberProfile` per ADR-005.

**Tradeoff acknowledged.** The contact list may show a stale name briefly if a member updates their profile and we have not yet processed the corresponding event. Acceptable for V1; the eventual consistency window is the same as today's profile update propagation.

### Auto-Add Coordinator

`ContactSyncCoordinator` is the single entry point for all auto-add work. It encapsulates the "for this conversation, ensure all non-self members are contacts" operation idempotently.

```swift
public protocol ContactSyncCoordinatorProtocol: Sendable {
    /// First-message hook. Idempotent; skips if the conversation already
    /// has a `conversation_contacts_sync` marker.
    func syncContactsOnFirstMessage(for conversationId: String) async throws

    /// Membership-change hook. Forces a re-sync even on an already-synced
    /// conversation so newly arrived members are pulled into contacts.
    /// Still honors the action-gated rule: short-circuits on a never-
    /// synced conversation unless the local user is the creator.
    func syncContactsAfterMembershipChange(for conversationId: String) async throws
}

final class ContactSyncCoordinator: ContactSyncCoordinatorProtocol, @unchecked Sendable {
    private let databaseWriter: DatabaseWriter
    private let contactsWriter: ContactsWriterProtocol
    private let selfInboxIdProvider: () -> String?

    // Both public methods route to a shared private impl:
    // - On a never-synced conversation, both hooks run the upsert loop
    //   (subject to the action-gated rule for the membership-change hook).
    // - On an already-synced conversation, the first-message hook no-ops
    //   while the membership-change hook re-runs to pull in new members.
}
```

**Idempotency.** Upserts into `contact` use `INSERT OR IGNORE` for the identity columns (`inboxId`, `addedAt`, `addedViaConversationId`) so that re-runs do not clobber the original `addedAt` / `addedViaConversationId`. Profile fields are updated separately by the `ContactsProfileSyncWriter` per most-recent-wins.

**Concurrency.** GRDB's `DatabaseWriter` serializes writes, so concurrent calls for the same conversation linearize and the second short-circuits on the sync-marker check.

**Self-skip.** The local user's own inboxId comes from `DBInbox` (singleton per ADR-011) or the in-memory XMTP client; injected into the coordinator as a closure.

### Hook Integration (Step 1)

Two hook sites in Step 1, both fire-and-forget:

```swift
// 1. First outbound message persisted in a conversation
//    (in MessagesWriter.persistOutgoing, or equivalent - confirm during implementation)
Task.detached { try? await contactSyncCoordinator.syncContactsOnFirstMessage(for: conversationId) }

// 2. New members added to an existing group
//    (in ConversationMetadataWriter.addMembers, after DBConversationMember writes)
Task.detached { try? await contactSyncCoordinator.syncContactsAfterMembershipChange(for: conversationId) }
```

The first hook replaces the old `StreamProcessor.processConversation` and `InviteJoinRequestsManager.processJoinRequest` hooks. We no longer auto-add on conversation-arrival; the local user must take an explicit action (send a message). This matches the review-feedback requirement: *"all other members of the group are added to your Contact List as soon as you send a message in the group."*

The second hook is unchanged in spirit but now should only run for conversations the local user has already acted in, i.e. conversations that already have a `conversation_contacts_sync` row. The coordinator short-circuits the membership-change hook on never-synced conversations (the local user has not acted in them yet, so we do not pull their members into our contacts).

Errors are caught locally and logged; auto-add is a best-effort enrichment.

### Inbound Conversation Filter (Step 2)

#### Today's gate (what we're extending)

`StreamProcessor.shouldProcessConversation` (`ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift`, lines 713-739) is the single chokepoint for accepting an inbound group conversation. Quoting the existing logic:

```swift
var consentState = try conversation.consentState()
guard consentState != .allowed else { return true }
guard try await conversation.creatorInboxId() != params.client.inboxId else { return true }

if consentState == .unknown {
    let hasOutgoingJoinRequest = try await joinRequestsManager.hasOutgoingJoinRequest(
        for: conversation, client: params.client
    )
    if hasOutgoingJoinRequest {
        try await conversation.updateConsentState(state: .allowed)
        consentState = try conversation.consentState()
    }
}
return consentState == .allowed
```

In English: a conversation passes if XMTP says `consent == .allowed`, or the local user is the creator, or `consent == .unknown` and the local user already sent an invite-side outgoing join request for it (in which case consent is bumped to `.allowed`). Anything else returns `false`, and `processConversation` drops it without persisting (lines 140-145). DM messages take a separate path in `processMessage` (lines 184-311) — DMs are *not* persisted as conversation rows; they exist purely as transport for invite join-request payloads handed to `InviteJoinRequestsManager.processJoinRequestOutcome`.

The practical effect today is that the only inbound group conversations the user ever sees are ones gated by the Convos invite system. A direct 1:1 DM from someone the user has never invite-flow'd with does not appear in the local DB at all.

#### New gate (Step 2 — Phase 2.6 of this work)

We extend `shouldProcessConversation` to add a contact-list path that elevates `.unknown` → `.allowed`, plus a block path that **quarantines** new welcomes (so unblocking later restores access via the sweeper), plus a stranger-quarantine path for everything else. The invite-flow branch is unchanged.

```swift
// Pseudocode for the extended decision; the actual structure should preserve the existing guards.
var consentState = try conversation.consentState()

// Already-accepted conversations bypass every other check. Blocking does
// NOT retroactively quarantine an existing accepted convo — see the
// "Blocking" section's effects list.
if consentState == .allowed { return .deliver }
if try await conversation.creatorInboxId() == params.client.inboxId { return .deliver }

let creatorInboxId = try await conversation.creatorInboxId()

// Block path: quarantine instead of dropping. The conversation is held
// (persisted but hidden from the main feed) so unblocking later via the
// QuarantineSweeper can promote it back to the feed. If the user never
// unblocks within the TTL window, the sweeper deletes it.
if contactsRepository.isBlocked(inboxId: creatorInboxId) {
    return .quarantine
}

if consentState == .unknown {
    // Existing path: invite-flow handshake.
    if try await joinRequestsManager.hasOutgoingJoinRequest(for: conversation, client: params.client) {
        try await conversation.updateConsentState(state: .allowed)
        return .deliver
    }
    // New path: known contact.
    if contactsRepository.isContact(inboxId: creatorInboxId) {
        try await conversation.updateConsentState(state: .allowed)
        return .deliver
    }
    // New path: stranger — persist hidden, sweep later.
    return .quarantine
}

// consentState == .denied — drop on floor, as today.
return .reject
```

Notes:

- The "sender" of an inbound conversation is its creator — `creatorInboxId()` on the XMTP conversation, the same value `shouldProcessConversation` already reads on line 722. There is exactly one creator per conversation.
- The contact-list and block-list checks are indexed point reads on `DBContact` (lookup by primary-key `inboxId`); negligible overhead relative to the existing async XMTP calls.
- `InboundConversationFilter` is the Swift type that owns the new logic; `shouldProcessConversation` becomes a thin wrapper over `InboundConversationFilter.decide(for: conversation, client:)` to keep the file small and the decision testable in isolation.
- **Delivery and rejection are terminal; quarantine is recoverable.** Once a conversation is delivered or rejected, that decision is final — we do not re-evaluate. Quarantined conversations are the recoverable middle state: the `QuarantineSweeper` re-evaluates them periodically and either promotes them to the main feed (sender became a contact, OR sender is no longer blocked) or deletes them past the TTL.
- **Block does not retroactively quarantine an already-accepted conversation.** The `consent == .allowed` short-circuit at the top of the filter ensures that any conversation the user previously accepted continues to be delivered, even if the sender is now blocked. Blocking only affects *new* inbound from that sender; the user's existing shared conversations with the blocked party are untouched. (Mid-group muting / silencing remains an open question.)
- Quarantined conversations *are* persisted (so we can promote them later if the sender becomes a contact OR is later unblocked), but excluded from the main-feed `ConversationsRepository` query and from any unread-count, badge, or notification surface.

#### DMs (the deferred part)

Today DMs are not persistable conversations — `StreamProcessor.processMessage` consumes them as invite-payload transport and discards the rest. For Step 1, we treat DMs the same as today (no behavioral change there); only group conversations flow through the new filter. This is fine for Step 1's goal of contact-driven inbound filtering on group conversations.

For Step 2 ("Send a message" from a contact card creating a new conversation with a single recipient), we have two options and need to pick one before Phase 2.2:

1. **Use a group conversation under the hood** — the contact picker creates a group with the local user + the chosen contact(s) regardless of count. This works with today's persistence model and the new contact-gated filter; the only loss is that "1:1 DM" doesn't exist as a distinct concept on the wire. Most likely the simpler path.
2. **Persist DMs as first-class conversations** — extend `processMessage` (or add a sibling) to write a `conversation` row for inbound DMs, gated by the same `InboundConversationFilter`. Cleaner conceptually, larger blast radius. Likely a follow-up after Step 2 ships.

This is tracked as an open question; the recommendation is option 1 for V1.

### Blocking *(Step 2)*

A user can block a contact. Blocking is a per-contact flag stored on `DBContact.blockedAt` (added by the Step 2 migration):

```swift
public protocol ContactsWriterProtocol: Sendable {
    func block(inboxId: String) async throws        // sets blockedAt = now
    func unblock(inboxId: String) async throws      // sets blockedAt = nil
    // ... other write methods
}
```

Effects:

- **Future inbound conversations from this `inboxId` are quarantined** by `InboundConversationFilter` — persisted to the local DB but hidden from the main feed, unread counts, badges, and notifications. The user sees nothing while the block stands.
- **Unblocking restores access to held conversations.** The `QuarantineSweeper`'s next run sees `isContact && !isBlocked` for the sender and promotes any held-by-block conversations back to the main feed. The user gets all the messages that were sent in those conversations during the block period.
- **If the user never unblocks**, the sweeper deletes held-by-block conversations once they pass the TTL (default 7 days), same as stranger-quarantined conversations. No long-term storage cost.
- Blocked contacts are still listed in the contacts list (so the user can find them to unblock); the contact card surfaces the blocked state with an unblock affordance.
- **Existing shared conversations are not touched** — the `consent == .allowed` short-circuit in the filter ensures past-accepted convos continue to deliver. The blocked party can still post in groups the local user is in. Mid-group muting is out of scope for V1 (open question).
- Blocking does not delete the contact. The user can independently remove a contact (open question — not shipped V1) once we add that affordance.

Blocking is local-only. The blocked party is not notified.

### Backfill Service (Step 1) — *removed*

This feature is shipping prior to public launch, so there are no existing installs to migrate. The four steady-state triggers (first-message hook, addMembers hook, ConversationWriter network-side commit, profile-sync hooks) populate `contact` from a clean slate; no one-time backfill is needed. `ContactsBackfillService` and `Phase 1.3` were removed before merge.

### Picker Logic (Step 2)

`ContactsPickerView` takes a mode parameter:

```swift
enum ContactsPickerMode {
    case newConversation
    case addToConversation(conversationId: String)
}
```

In `.newConversation` mode, the query is a simple list of all non-blocked contacts ordered by `displayName`. In `.addToConversation` mode, the query LEFT-JOINs `conversation_members` to mark members already in the destination chat:

```sql
SELECT contact.*,
       (conversation_members.inboxId IS NOT NULL) AS isAlreadyInChat
FROM contact
LEFT JOIN conversation_members
       ON conversation_members.inboxId = contact.inboxId
      AND conversation_members.conversationId = ?destinationChatId
WHERE contact.blockedAt IS NULL
ORDER BY contact.displayName COLLATE NOCASE ASC
```

Rows where `isAlreadyInChat = 1` render disabled with the "in chat" badge. Selectable rows are tap-to-toggle; their names appear in the "To" header pill at the top.

CTAs:

- `.newConversation` → on confirm, create a new conversation with the selected `inboxId`s via the existing conversation-create flow, then send the first message.
- `.addToConversation` → on confirm, call `ConversationMetadataWriter.addMembers(...)` with the selected ids.

### View Model State Management

Per CLAUDE.md, new view models use `@Observable`:

```swift
@Observable
final class ContactsViewModel {
    var contacts: [ContactRow] = []
    var isLoading: Bool = false

    private let contactsRepository: ContactsRepositoryProtocol
    private var subscription: AnyCancellable?

    init(contactsRepository: ContactsRepositoryProtocol) {
        self.contactsRepository = contactsRepository
        subscription = contactsRepository.contactsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.contacts = $0 }
    }
}
```

`ContactRow` is a presentation struct that bundles the resolved profile snapshot from `DBContact` plus the blocked flag.

## Implementation Plan

Stacked PRs via Graphite, one logical chunk per PR. Two discrete delivery steps.

### Phase 0: Plan PR (already in flight)

- [x] Wireframes in `contact-list-mocks/`.
- [x] 1-pager.
- [ ] This PRD.

---

### Step 1 — Populate and view

The goal of Step 1 is to build the contact list, keep it accurate, and let the user browse it. No filtering, no blocking, no messaging-from-contacts. Step 1 is purely additive: existing users see no change in behavior beyond a new "Contacts" entry in the Convos menu.

#### Phase 1.1: Data layer

- [ ] `DBContact` record + migration `createContactTable` (with profile-snapshot columns; **no** `blockedAt` yet — that's added in Step 2's data-layer phase).
- [ ] `DBConversationContactsSync` record + migration.
- [ ] `ContactsRepository` with alphabetical-list publisher, `isContact(inboxId:)`. *(`isBlocked(inboxId:)` is added in Step 2.)*
- [ ] `ContactsWriter` with idempotent upsert and profile-snapshot most-recent-wins update.
- [ ] Unit tests for repository queries (alphabetical sort, `isContact`) and writer idempotency, profile-snapshot recency.

Ship-readiness: ConvosCore tests pass; data layer fully tested with mocked profile data; no UI yet.

#### Phase 1.2: Auto-add coordinator + hooks

- [ ] `ContactSyncCoordinator` with the read-members → upsert-contacts → write-sync-marker transaction.
- [ ] Self-skip wiring via `DBInbox`.
- [ ] Wire **first-outbound-message** hook in the message-send path.
- [ ] Wire **member-added-to-existing-group** hook in `ConversationMetadataWriter.addMembers` — guarded so it only runs for conversations already synced (i.e., the local user has already acted there).
- [ ] `ContactsProfileSyncWriter` listening for `member_profile` writes / profile-snapshot / `ProfileUpdate` events; updates `DBContact` profile fields per most-recent-wins.
- [ ] Integration tests: simulate sending first message in a fresh group → assert contacts populate; simulate a member-add to an already-acted-in group → new contact appears; simulate joining a group and not posting → assert no contacts added.

Ship-readiness: Auto-add works end-to-end on Local environment; existing tests still pass.

#### Phase 1.3: Browse UI

- [ ] "Contacts" entry under "My info" in the existing Convos top-left menu.
- [ ] `ContactsView` with alphabetical sectioning + side-letter index. No search in V1.
- [ ] Placeholder `ContactCardView` (profile + back; no "Send a message" CTA, no block / unblock — both are added in Step 2).
- [ ] SwiftUI Previews with `.mock` data.
- [ ] Manual testing against the wireframes.

Ship-readiness: User can open the menu, tap "Contacts", browse the list, tap a contact, see their profile.

**End of Step 1.** Ship a stacked PR or merge train including phases 1.1 – 1.3. Existing inbound conversation behavior is unchanged at this point.

---

### Step 2 — Messaging, filtering, and blocking

Step 2 is where the contact list starts gating behavior. It introduces messaging from contacts (picker UI, "Send a message", "Add from Contacts"), the contact-gated inbound filter (extending `StreamProcessor.shouldProcessConversation`), the quarantine sweeper, and blocking. The phases are sequenced so the data and filter layers land before the UX that depends on them, and the messaging UX before the filter is wired (so we can validate the messaging end-to-end with today's invite-flow path before the filter changes happen).

#### Phase 2.1: Step 2 data layer additions

- [ ] `addContactBlockedAt` migration — adds `blockedAt: DATETIME NULL` column on `contact`.
- [ ] `addConversationQuarantineFields` migration — adds `quarantinedAt`, `quarantineReleasedAt` columns on `conversation`.
- [ ] Extend `ContactsRepository` with `isBlocked(inboxId:)`.
- [ ] Extend `ContactsWriter` with `block(inboxId:)` / `unblock(inboxId:)`.
- [ ] Unit tests for blocking transitions and the new query helper.

Ship-readiness: data layer ready for the filter and the contact-card block affordance; no behavior changes yet.

#### Phase 2.2: Picker UI shell

- [ ] `ContactsPickerView` matching the attached mock — "To" pill header, Favorites section (V1 may render empty), alphabetical main list, side-letter index, multi-select check indicators.
- [ ] `ContactsPickerViewModel` parameterized by `ContactsPickerMode` (`.newConversation` vs `.addToConversation`).
- [ ] SwiftUI Previews with `.mock` data for both modes.

Ship-readiness: picker renders and supports multi-select; no integration with conversation creation or member-add yet.

#### Phase 2.3: New conversation flow

- [ ] Top-level "new conversation" entry point (compose button or equivalent — confirm during implementation).
- [ ] On picker confirm in `.newConversation` mode, create a new conversation with the selected `inboxId`s and route the user into it.
- [ ] Manual testing: pick 1 contact, confirm DM creation; pick 3 contacts, confirm group creation.

Ship-readiness: new conversation creation from contacts works end-to-end against today's invite-flow filter (before the filter is extended).

#### Phase 2.4: Send message from contact card + block UX

- [ ] `ContactCardView` upgraded with "Send a message" CTA.
- [ ] CTA opens `ContactsPickerView` in `.newConversation` mode with that contact pre-selected.
- [ ] Block / unblock affordance on the contact card; confirms before applying.
- [ ] Manual testing: tap a contact → tap "Send a message" → picker opens with that contact selected and CTA enabled. Block a contact → confirm `blockedAt` is set; unblock → confirm cleared.

Ship-readiness: contact-card-to-message flow works end-to-end; block / unblock is wired even though the inbound-filter consequence isn't observable until Phase 2.6.

#### Phase 2.5: Add-to-chat from chat plus-menu

- [ ] New "Add from Contacts" row in the chat plus-menu (alongside Invite link and Convo code).
- [ ] Tapping opens `ContactsPickerView` in `.addToConversation(conversationId:)` mode.
- [ ] CTA invokes `ConversationMetadataWriter.addMembers(...)` with the selected ids.
- [ ] Manual testing: open a group, tap +, tap "Add from Contacts", select 2 contacts, confirm; verify members appear in the group.

Ship-readiness: add-to-chat flow works end-to-end.

#### Phase 2.6: Inbound filter + quarantine sweeper

- [ ] Refactor `StreamProcessor.shouldProcessConversation` (lines 713-739) to delegate to a new `InboundConversationFilter.decide(for:client:)` returning `.deliver | .quarantine | .reject`. Preserve the existing consent / creator-self / outgoing-join-request branches verbatim.
- [ ] Order the filter checks: `consent == .allowed` short-circuit FIRST (existing accepted convos always deliver, even from a now-blocked sender), then creator-self, then the block check.
- [ ] Add the contact-list path: `consent == .unknown` and `contactsRepository.isContact(creatorInboxId)` and not blocked → bump consent to `.allowed` and deliver.
- [ ] Add the block path: `contactsRepository.isBlocked(creatorInboxId)` → quarantine (persist hidden; recoverable on unblock via the sweeper).
- [ ] Add the stranger-quarantine path: `consent == .unknown`, no outgoing join request, sender not a contact, not blocked → persist with `quarantinedAt = now`, hidden from main feed.
- [ ] Update `processConversation` (lines 140-145) to honor the three-way return — `.quarantine` persists with the new flag set, `.reject` matches today's drop, `.deliver` matches today's pass.
- [ ] `QuarantineSweeper` that runs on launch and every hour while foregrounded; promotes any quarantined conversation whose sender is currently `isContact && !isBlocked` (covers both the stranger-became-contact and the blocked-now-unblocked cases); deletes those past TTL (default 7 days, configurable via `QuarantineConstant`).
- [ ] Update `ConversationsRepository` main-feed query to exclude `quarantinedAt IS NOT NULL AND quarantineReleasedAt IS NULL`.
- [ ] Integration tests: existing invite-flow path still delivers (regression); inbound from a contact (no invite handshake) → delivered with consent bumped to `.allowed`; inbound from a stranger → quarantined; stranger becomes a contact → promoted; quarantined past TTL → deleted; inbound from a blocked contact → quarantined; blocked-then-unblocked → sweeper promotes the held conversation; conversation creator-is-self → delivered as today; consent==.allowed + sender currently blocked → still delivers (no retroactive quarantine of accepted convos).

Ship-readiness: filter and sweeper both work; today's invite-flow happy path is unchanged; contacts can now land conversations directly; blocking has observable effect.

#### Phase 2.7 *(stretch)*: Shared-conversations list on contact card

- [ ] Query for "every conversation both inboxes are members of, sorted by recent activity."
- [ ] Render below the "Send a message" CTA on the contact card.
- [ ] Tapping a row opens that conversation.

Ship-readiness: shared-conversations list renders correctly.

#### Phase 2.8: Unified contact card (replaces `ConversationMemberView`)

Retires the standalone `ConversationMemberView` in favor of `ContactCardView` rendered in `.scopedToConversation` mode. One canonical "look at this person" surface across the contacts list and the chat member-tap entry point.

**2.8.a — Agent-status on contacts (data layer)**

- [ ] `addContactAgentVerification` migration: adds nullable `agentVerification` column (jsonText) to `contact`. Existing rows get `NULL` (= "unknown / not yet observed").
- [ ] Add `agentVerification: AgentVerification?` to `DBContact` (with `nil` default in the explicit init) + `Columns` entry. Persisted as JSON via Codable.
- [ ] Add `agentVerification: AgentVerification?` to `Contact` (presentation model), hydrated from `DBContact`.
- [ ] Extend `ContactProfileSnapshot` with `agentVerification: AgentVerification? = nil`. The writer treats each timestamped snapshot as one authoritative unit: when applied, every profile field on the stored row, including `agentVerification`, is wholesale-replaced by the snapshot's value. A newer snapshot with `agentVerification: nil` clears the stored verification (consistent with the `ProfileUpdate` wire-format contract, where a profile without a signal carries none). Untimestamped snapshots from local hydration sites (e.g. `ContactSyncCoordinator`) leave existing rows untouched and only seed new contacts.
- [ ] Update `ContactSyncCoordinator` to populate `agentVerification` during its per-member upsert by reading `DBMemberProfile.memberKind` (and any verification metadata) for the source conversation.
- [ ] Update `ContactsProfileSyncWriter` to update `agentVerification` on member-profile-snapshot events.
- [ ] Unit tests: migration applies; `Contact.agentVerification` defaults to `nil` on pre-migration rows; setting it via the writer persists; profile sync from a verified-agent member promotes the contact's verification; a newer profile event without an agent signal wholesale-clears the stored verification.

**2.8.b — Unified card view**

- [ ] Define `ContactCardMode` enum: `.standalone`, `.scopedToConversation(conversationId: String, canRemoveMembers: Bool, isCurrentUser: Bool)`. Note: agent state is *not* a mode parameter — it's read from `contact.agentVerification`.
- [ ] Extend `ContactCardView` with the new mode parameter. Default to `.standalone` so the existing contacts-list entry point compiles unchanged.
- [ ] Render order in both modes: avatar / name / bio → agent rows (when `contact.agentVerification?.isVerified == true`) → Send-a-message → Block / Unblock.
- [ ] In `.scopedToConversation` mode, append a "Group actions" section after the standard sections: **Remove from convo** (gated on `canRemoveMembers && !isCurrentUser`), **Block and leave** (gated on `!isCurrentUser`).
- [ ] Move agent URL constants (`getSkillsURL`, `learnAboutAssistantsURL`) out of `ConversationMemberView.Constant` and into a new shared `AgentLinks` enum colocated with the agent-rows view.
- [ ] **Send-a-message CTA on a non-contact (scoped mode only):** before presenting the picker, perform a single-person `ContactsWriter.upsertContact(inboxId: member.inboxId, addedViaConversationId: <conversationId>, profile: <best-effort snapshot from the member profile>)`. Then present `ContactsPickerView(mode: .newConversation, preselectedInboxIds: [member.inboxId])`. This narrow upsert is documented as person-specific intent — distinct from the Step 1 group-wide auto-add.
- [ ] Reroute `viewModel.presentingProfileForMember` to present `ContactCardView(mode: .scopedToConversation(...))` instead of `ConversationMemberView`.
- [ ] Update `ConversationViewModel.blockAndLeaveConvo()` to call `contactsWriter.block(inboxId:)` *before* the group-leave. Document the ordering in the method's doc comment so a future refactor doesn't accidentally swap the order and leave a window where the inbound filter is unaware of the block.
- [ ] Delete `ConversationMemberView` after manual verification. Preserve existing accessibility identifiers (`remove-member-button`, `block-member-button`) on the new card so existing UI test selectors keep working.
- [ ] Tests:
  - Unit tests for the new mode-driven section visibility (admin-only Remove, self-suppression, agent-rows-when-verified-agent).
  - Regression test that `blockAndLeaveConvo()` writes `DBContact.blockedAt` non-nil AND removes the local user's `DBConversationMember` row.
  - Test the narrow-upsert path: tap Send-message on a non-contact member → contact row exists post-tap with `addedViaConversationId == conversationId`.

**2.8.c — Discoverability**

- [ ] Module-level header doc on `ContactCardView.swift` listing all entry points and the mode mapping.
- [ ] Mirror header doc on `ContactsPickerView.swift` for the picker.
- [ ] Cross-reference doc comments on `ContactCardMode` and `ContactsPickerMode` pointing at each other ("mirrors X's pattern").
- [ ] Add a "View Modes for Multi-Entry-Point Surfaces" subsection to `CLAUDE.md` documenting the convention so future engineers default to it when they encounter a similar two-surface situation.

Ship-readiness: tapping a member from inside a chat opens the unified card; existing actions (Remove, Block-and-leave) work end-to-end with identical behavior; new actions (Send message — including for non-contact members via the narrow upsert path, Block-only) work; agent rows appear on both standalone and scoped cards when the contact is a verified agent; `ConversationMemberView` is deleted with no remaining call sites.

#### Phase 2.9: Contact-list display-name fallback

Stopgap for the window between "we invite a contact" and "their profile snapshot arrives." When an in-group render site would emit "Somebody" because the per-conversation profile is empty, fall back to the contacts-list display name first. Read-only; never modifies the contacts table; per-conversation profile always takes precedence once observed.

- [ ] Add a `contactName(for inboxId: String) -> String?` method to `ContactsRepositoryProtocol` (the `Profile` API in ConvosCore stays unchanged so its semantics don't drift across modules). Returns the contact's `displayName` if non-empty, otherwise `nil`. Non-throwing; swallows storage errors as `nil` since render-site callers cannot usefully handle a thrown error mid-paint. Composed with the per-conversation profile name and the "Somebody" sentinel by the existing `Conversation.computedDisplayName(memberNameOverride:)` / `ConversationMember.displayName(memberNameOverride:)` overloads in ConvosCore.
- [ ] Inject the lookup into render sites that surface a remote member's name via `Profile.displayName`. Each surface constructs `messagingService.contactsRepository().contactName(for:)` once and threads the resulting `@Sendable (String) -> String?` closure through the SwiftUI `.memberNameOverride(_:)` environment modifier (defined in `Convos/Contacts/MemberNameOverride.swift`). Audit during implementation by grepping `Profile.displayName` callers inside `Convos/Conversation Detail/`. Initial known list:
  - System / update messages: join, leave, added-by, removed-by, role change, name change. These typically share a renderer; updating it once covers all the variants.
  - The conversation members list (`ConversationMembersListView` → `MemberRow.displayName`).
  - Mention strings rendered in message bodies (if any).
  - Typing-indicator labels that include a member name (verify these route through `Profile.displayName` first).
- [ ] Skip the lookup for any render site that's known to be "self-only" (the local user always has their own profile populated). Don't add overhead to rendering of self.
- [ ] Don't change `Profile.displayName` itself. The existing "Somebody" behavior remains for callers that haven't opted in. This keeps the fallback opt-in per render site rather than a global semantics shift, and prevents log lines / analytics / unit tests that read `displayName` from suddenly seeing contact names.
- [ ] Out of scope for V1: NSE / push-notification copy and any rendering outside the conversation view that doesn't have access to a `ContactsRepositoryProtocol`. Those targets continue rendering "Somebody"; a follow-up can plumb the repo through.
- [ ] Tests:
  - `ContactsRepository.contactName(for:)` unit tests: returns the stored display name when the inbox is a known contact, returns `nil` for non-contacts and for contacts with an empty `displayName`, swallows storage errors as `nil`; no contact write occurs during a lookup. Composition with the per-conversation profile name and the "Somebody" sentinel is already covered by the `MemberNameOverrideTests` suite in ConvosCore.
  - Snapshot- or string-equality test on the system-message renderer for "Somebody joined" → "Alice joined" transformation when Alice is a contact.

Ship-readiness: a member who joins a group I share with them shows by their contact name in system messages and the members list, even before their per-conversation profile snapshot lands; non-contacts continue to render as "Somebody"; no behavior change for the local user's own avatar / name.

---

### Phase 2.10: Instant chat screen from the contacts picker

**Goal.** Tapping "Start Conversation" in the contacts picker shows a chat-like screen *immediately* — same instant feel as the "+" button flow. By the time the network settles, the new conversation has the picked contacts already in it. No half-built groups, no flashes of underlying views, no duplicate XMTP groups, no bespoke contacts-flow plumbing that diverges from the "+" button code path.

**Approach.** Route the contacts picker through the existing `NewConversationViewModel` + `ConversationStateMachine` infrastructure that the "+" button flow already uses. Two surgical extensions are enough:

1. Teach `ConversationStateMachine` to add a known set of initial members atomically as part of the `.create` action, before transitioning to `.ready`.
2. Add a `.newConversationWithMembers([String])` case to `NewConversationMode` so callers can pre-populate the picked inboxes.

After that, the picker just constructs a `NewConversationViewModel` with the new mode and hands it to `ConversationsViewModel.newConversationViewModel` — exactly the same slot the "+" button uses. `NewConversationView`'s existing presentation handles the placeholder, the swap to a real chat once `.ready` lands, and the error UX on failure. No new placeholder view. No new notifications. No `ContactConversationStarter`.

**Why this shape.** The reviewer's read of the original Phase 2.10 prototype surfaced four concerns, all rooted in the same issue: a bespoke contacts-flow code path that reimplements logic `NewConversationViewModel` already owns. Convergence addresses all four cleanly.

- **Concern #1 — No placeholder UI.** `NewConversationView` already shows a placeholder `ConversationViewModel` instantly on mount and swaps in the real one when the state machine reaches `.ready`. Reuse this verbatim — no separate placeholder view to maintain.
- **Concern #2 — `addMembers` runs after `.ready`.** If `addMembers` is a step *after* the state machine settles, then `.ready` does NOT mean "your picked contacts are in the conversation." A fast user, a dropped call, or a network blip leaves a real conversation in the list with just the local user. Fix: fold `addMembers` *into* the state machine's `.create` action so `.ready` becomes the strong guarantee "conversation exists AND its initial members are in it." Failure surfaces as `.error`, not a half-built `.ready`.
- **Concern #3 — Cached conversation duplication risk.** `prepareNewConversation()` returns a warm-cached `existingConversationId` for an XMTP group already published on the network. If the create path doesn't recognize that the publish already happened, it'll fire a second publish and leave a stuck duplicate. Fix: audit `ConversationStateMachine.handleCreate` and confirm (or add) the resume-rather-than-republish path. Lock it in with a `newGroup`-invocation-count test.
- **Concern #4 — Architectural duplication.** A second sequencing path for "new conversation" creation is maintenance burden, divergent error UX, and risk that future changes touch one path but not the other. Fix: don't introduce that second path in the first place.

**Tasks.**

#### a. `ConversationStateMachine` accepts initial members atomically

`ConversationStateMachine.create` (or the action that drives it) gains:
- An `initialMemberInboxIds: [String] = []` parameter on the `.create` action. Default empty preserves existing call sites.
- An `addMembers` hook stored at init time:

```swift
typealias AddMembersHook = @Sendable ([String], String) async throws -> Void

init(..., addMembers: @escaping AddMembersHook = { _, _ in })
```

`ConversationStateManager` wires the hook to `ConversationMetadataWriter.addMembers(_:to:)` when constructing the state machine. The metadata writer's full pipeline (XMTP group operation, local member rows, contact sync, ProfileSnapshot) keeps running unchanged — the state machine just composes it into the create sequence.

`handleCreate` runs the addMembers hook *between* the XMTP publish and the `.ready` transition. On failure: transition to a new `ConversationStateMachineError.addMembersFailed(underlying:)` (or fold into an existing error case) and emit `.error`, **not** `.ready`. Downstream `.ready` consumers can now treat the state as the strong guarantee.

#### b. `NewConversationMode.newConversationWithMembers([String])`

Add the case alongside `.newConversation`. Same behavior — auto-create on init, placeholder VM, swap on `.ready` — except the picked inboxes ride along on the `.create` action that the state manager fires. `NewConversationViewModel`'s create-on-init logic threads `initialMemberInboxIds` into `createConversation(initialMemberInboxIds:)`.

If the existing mode is a flat enum, this is one new case + one switch update inside `NewConversationViewModel.handleCreate` (or wherever the mode-to-action mapping lives).

#### c. Contacts picker constructs a `NewConversationViewModel`

In `ContactsView`, `ContactCardView`, and any other call site that today opens the contacts picker for `.newConversation` mode:

```swift
private func handlePickerConfirm(_ inboxIds: Set<String>) async {
    let newConvoVM = NewConversationViewModel(
        mode: .newConversationWithMembers(Array(inboxIds)),
        session: session,
        // … same args as the "+" button flow
    )
    conversationsViewModel.newConversationViewModel = newConvoVM
    // ConversationsView presents NewConversationView via its existing
    // sheet binding on `newConversationViewModel`; AppSettings sheet
    // dismisses through that same presentation machinery (or via the
    // existing dismiss-on-newConversationView-mount logic the + button
    // flow already uses — audit during implementation).
}
```

`.addToConversation` mode in `AddFromContactsPickerModifier` (the "Add from Contacts" row inside an active chat) is unchanged — that path doesn't go through this code; it calls `ConversationViewModel.addMembersFromContacts(_:)` directly.

#### d. Warm-cache id preservation audit (concern #3)

Audit `ConversationStateMachine.handleCreate` and `ConversationStateManager`'s create path to confirm:

- When the state manager is bound to a warm-cached `existingConversationId` from `prepareNewConversation()`, the create action resumes that conversation rather than publishing a second XMTP group.
- If the state is mid-publish (pre-warm not yet `.ready`), `createConversation()` awaits the in-flight publish rather than firing a parallel one.

If the state machine already does this correctly: document it inline next to `handleCreate`. If it doesn't: the fix is part of (a) — the create handler checks "is there already a published XMTP group for this state manager's conversationId? if yes, skip publish; run member add against the existing id." Either way, the test in (e) makes it permanent.

#### e. Tests

- **State-machine unit test:** `.create` with non-empty `initialMemberInboxIds` calls the addMembers hook with the right `(inboxIds, conversationId)` args before emitting `.ready`. Hook failure → `.error(addMembersFailed(...))`, not `.ready`.
- **State-machine unit test:** `.create` with empty `initialMemberInboxIds` does NOT call the addMembers hook. Default-no-op closure path; covers backward compat for the "+" button flow.
- **State-machine unit test (concern #3 regression guard):** when invoked on a state manager bound to a warm-cached id whose XMTP group has already been published, exactly one `newGroup` call happens (count via mock XMTP client).
- **`NewConversationViewModel` integration test:** instantiate with `.newConversationWithMembers(["alice", "bob"])` against a real-ish state stack; after `.ready`, the swapped-in `ConversationViewModel.conversation.members` contains both inboxes. The placeholder VM is observable in `.creating` state and is replaced.
- **Manual UAQ:** tap picker Confirm → standard `NewConversationView` placeholder appears instantly (visually matches the "+" button flow) → real chat appears with members already present in the header / system messages. No "just you" group ever visible in the conversations list. Forced `addMembers` failure → `NewConversationView`'s standard error UX offers retry/cancel.

**Edge cases.**

- **Cold cache.** `prepareNewConversation` returns `nil` for the conversationId. `NewConversationViewModel` drives the state machine through full create (publish + addMembers). Placeholder VM stays on screen for the round-trip — same UX as a cold-cache "+" button create.
- **Two rapid Confirm taps.** Picker's existing button-disabled-while-confirming pattern (or whatever guard `NewConversationViewModel` uses for double-tap protection) covers it. If `NewConversationViewModel` doesn't guard, add an `isStarting` flag in the picker that disables Confirm while the viewmodel is being constructed.
- **Synthetic-contact path.** `ContactCardView.handleSendMessage` calls `contactsWriter.upsertContact(...)` *before* opening the picker (outside the latency-sensitive path). Unchanged.

**Risk.**

- `ConversationStateMachine` is shared across every conversation-create flow. The default-no-op `addMembers` closure protects existing call sites that don't pass initial members. The empty-`initialMemberInboxIds` test in (e) makes regression visible.
- `NewConversationViewModel`'s placeholder pattern is well-exercised for `.newConversation` but new for `.newConversationWithMembers`. The integration test covers semantic correctness; a designer pass on the placeholder copy (does the existing "Starting…" / "Creating…" text read naturally when initial members are known?) may want a small variant. Defer until shipped — designer call.

**Concern coverage (summary).**

| Concern | Addressed by |
|---|---|
| #1 No placeholder UI | (b) + (c) — picker reuses `NewConversationViewModel`'s existing placeholder mechanism. |
| #2 `addMembers` after `.ready` | (a) — `.ready` now means "conversation exists AND members are in it". Failure goes to `.error`. |
| #3 Cached conversation duplication | (d) + (e) — audit + lock-in test. |
| #4 Architectural duplication | Whole-phase shape — no `ContactConversationStarter`, no parallel notifications, no second sequencing path. |

**Ship-readiness.** The contacts picker flow is indistinguishable from the "+" button flow at the code-path level — the only difference is the picker pre-populates the initial members list. `.ready` is a strong guarantee everywhere. No half-built conversations under any failure mode. Tapping Confirm shows a chat-like screen in under ~150ms on the warm-cache path (same numbers as the "+" button flow today).

**End of Step 2.** Stacked PR or merge train including phases 2.1 – 2.10 (subset as needed).

---

### Phase 3: Polish + UAQ resolution

- [ ] Resolve open questions (block-in-group behavior, contact removal, quarantine TTL tuning, Favorites section seeding) — small follow-up commits.
- [ ] Designer pass on the wireframes → real Figma + visual updates.
- [ ] QA test plan in `qa/tests/` for every new flow.

## Testing Strategy

**Unit tests** (`ConvosCoreTests`, no Docker needed):

- `ContactsRepository` query correctness — alphabetical sort, `isContact`, `isBlocked`.
- `ContactsWriter` idempotency — repeated upserts do not clobber `addedAt` / `addedViaConversationId`.
- `ContactsProfileSyncWriter` most-recent-wins — older event dropped, newer event applied; missing timestamp falls back to receive time.
- `ContactSyncCoordinator` self-skip, sync-marker short-circuit, force-rerun.
- `InboundConversationFilter` decision-table tests for contact / stranger / blocked sender.
- `QuarantineSweeper` — promotes when sender becomes contact; deletes when past TTL.
- `ConversationStateMachine` initial-members hook (Phase 2.10): `.create` with non-empty `initialMemberInboxIds` calls the addMembers hook with the right args before emitting `.ready`; hook failure → `.error`, not `.ready`; empty inboxes → no hook call (default-no-op closure path). Warm-cache regression guard: state manager bound to a warm-cached id publishes exactly one XMTP `newGroup` (mock count).
- `NewConversationViewModel.newConversationWithMembers` (Phase 2.10): instantiate with `[alice, bob]`; after `.ready` the swapped-in `ConversationViewModel.conversation.members` contains both inboxes.

**Integration tests** (require Docker via `./dev/up`):

- Send first message in a fresh group → other members appear as contacts.
- New member added to an already-acted-in group → that member appears as contact.
- Join a group and never post → no contacts added.
- Inbound from a contact → main feed.
- Inbound from a stranger → quarantined; not in main feed query.
- Stranger becomes contact during quarantine window → conversation promoted to main feed.
- Stranger never becomes contact → quarantined conversation deleted past TTL.
- Block then receive new inbound from blocked party → rejected outright.
- Profile recency: receive an old profile event after a newer one → contact's profile snapshot does not regress.

**UI tests** (separate target):

- Contacts list renders for a fixture session with mock GRDB data.
- Picker (new conversation mode) renders alphabetically with "To" pill filling on selection.
- Picker (add-to-conversation mode) disables already-in-chat members.
- Convos top-left menu shows "Contacts" entry under "My info".

**Manual / QA test plan** (`qa/tests/<NN>-contacts-list.md`):

- Onboarding flow: new install, accept invite, send a message, observe contact list populates.
- Quarantine edge: new install, receive an inbound from a stranger, observe nothing in main feed; share a group with that stranger and act in it, observe the held conversation appear.
- Blocking edge: block a contact, have them try to start a new DM, observe the DM never lands.
- Edge: leave every group with a contact; observe the contact remains in the list with their last-known profile snapshot.
- Edge: very large group (100+ members), local user posts → all members appear as contacts; picker scroll performance.

**Architecture review:** Hand the data-model + filter design to `swift-architect` for a final review before Step 1 Phase 1.1 lands.

## Performance / Scale

**Steady-state queries.** The contacts list is a single primary-key-ordered scan of `contact` filtered by `blockedAt IS NULL` and ordered by `displayName`. The `idx_contact_displayName` index keeps this O(log N) for the first paint regardless of contact volume. Budget: ≤100ms for first paint with 1,000 contacts on iPhone 13.

**Inbound filter overhead.** Each inbound conversation arrival adds two indexed point reads (`isContact`, `isBlocked`) before delivery. Negligible.

**Quarantine sweeper.** Runs once at launch and once per hour. Each run scans rows where `quarantinedAt IS NOT NULL AND quarantineReleasedAt IS NULL` — typically a small set. No concerns.

**Picker list rendering.** SwiftUI `LazyVStack` virtualizes the list. The `conversation_members` join for the "in chat" filter is keyed on the destination conversation, which has the existing index. No concerns at expected scales.

## Privacy & Security

**Local-only.** Contacts never leave the device. No server storage, no analytics events with contact data.

**Action-gated auto-add.** The new policy ("contact only after you act in a shared conversation") is meaningfully more conservative than the original draft. A user who is invited into a group but never engages does not pull strangers into their contact list, and so does not implicitly authorize those strangers to message them directly via the inbound filter.

**Inbound filtering is a different shape, not a strict tightening.** Today the gate is invite-flow-only: strangers cannot land *unless* they came through an invite handshake. The new gate keeps the invite-flow path verbatim and adds a contact-list path. Net effect: known contacts can now message the local user directly without a fresh invite handshake (this is *opening up*); strangers without an invite handshake or contact relationship still cannot land in the main feed (this is *unchanged*); strangers' conversations are now persisted-but-hidden for 7 days instead of dropped on the floor, which is a small storage-tradeoff we accept to enable the "just met in a group, then DM'd me" promotion path.

**Blocking is local-only.** Blocked parties are not notified. They can still see the local user as a member of any shared group (existing groups continue to work, modulo the open question on mid-group blocking).

**The other party doesn't know they've been added.** Same as before — auto-add is purely local. There is no "X added you as a contact" event sent over the network.

**iCloud keychain account compromise** (the documented risk in ADR-011) is unchanged — the contacts and the block list are derivable from local data; a compromise does not expose anything that wasn't already accessible.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Profile snapshot on `DBContact` goes stale relative to `DBMemberProfile` | Low | `ContactsProfileSyncWriter` listens for member-profile writes and updates the snapshot most-recent-wins. Worst case is brief eventual-consistency; documented in user stories. |
| `addedViaConversationId` references a deleted conversation | Low | FK uses `onDelete: .setNull`. The "added via" subtitle falls back gracefully when the source convo is gone. |
| Auto-add fires from a large stranger group merely because the user posted "hi" | Medium | The action-gated trigger is intentional — sending a message is the explicit signal. If users complain about getting hundreds of contacts from one large room, follow-up: add a "skip auto-add for groups with > N members" setting. |
| Hook ordering bugs — auto-add fires before `DBConversationMember` writes are committed, sees no members | High | Both hook sites are wired *after* their respective `DBConversationMember` writes commit. The coordinator's read happens in a separate transaction, after the writer's transaction is committed. Integration tests cover this. |
| Quarantine sweeper drops a held conversation that the user would have wanted | Medium | TTL is configurable and starts at 7 days, which is long enough for most "we just met in a group, then they DM'd me" flows. The sweeper promotes conversations whose senders become contacts during the window. If user feedback shows lost conversations, raise the TTL or add a UI surface for the held set. |
| Block does not silence in-group messages from the blocked party | Medium | This is an explicit V1 limitation. Tracked in open questions. If user demand is high, a follow-up adds either per-message hide or per-conversation mute-of-sender. |
| User sends a DM to a contact who has never acted in any shared group with them, so the recipient quietly never receives it | Medium | The local sender's UX shows the message as "sent" because it is — at the protocol level. The recipient's `InboundConversationFilter` decides not to surface it because the sender is not in their contacts. This asymmetry is by design but can confuse users. Mitigation: documentation in support; consider a future "delivery" indicator. |
| Multi-inbox reversion (theoretical) | Low | Documented as a non-goal. Schema is keyed on inboxId; if Convos ever has multiple inboxes per user, the contacts feature needs explicit rework. Acceptable long-tail concern. |

## Open Questions

- [ ] **Block-in-group behavior.** Does blocking a contact silence their messages within an existing shared group, or only reject future inbound conversation invitations from them? V1 ships with the latter (block affects only inbound welcomes). Block-in-group is a follow-up.
- [ ] **"Block" vs "Block and leave" on the unified card (Phase 2.8).** Should the card present both as separate buttons, or merge them into one button with an inline "also leave this convo" toggle? *(Recommendation: keep both as separate buttons — the intents are different ("hard reject this person from initiating new conversations" vs "block + immediately exit this group"). Merging adds cognitive load without saving real estate.)*
- [x] **Send-message CTA on the unified card when the member isn't yet a contact (Phase 2.8).** *(Resolved: the CTA is always shown. Tapping it performs a narrow per-person `ContactsWriter.upsertContact` for that member's inbox before opening the picker — distinct from the Step 1 group auto-add, which still requires sending a message in the group to enroll the rest of the members.)*
- [x] **Fate of `ConversationMemberView` (Phase 2.8).** *(Resolved: delete after the unified card is wired and manually verified. Self-tap continues to route through the existing "My info" path, which doesn't pass through `ConversationMemberView` today.)*
- [x] **Agent-status freshness on contacts (Phase 2.8).** When does a contact's `agentVerification` flag get cleared? *(Resolved: the writer's `replacingProfile(of:with:)` treats each timestamped snapshot as one authoritative unit, so a newer profile snapshot with `agentVerification: nil` wholesale-clears the stored verification. This matches the `ProfileUpdate` wire-format contract where a profile without an agent signal carries none, and supersedes the earlier "absence of signal preserves last known" recommendation. Live verification status inside conversation context remains accurate.)*
- [x] **Scope of the contact-list display-name fallback (Phase 2.9).** *(Resolved: V1 wires the resolver into every in-group surface that currently falls through to `Profile.displayName`'s "Somebody" sentinel — system messages (join / leave / added-by / role change / name change), the members list, mention strings, and typing-indicator labels. Surfaces outside the conversation view that don't have a `ContactsRepositoryProtocol` injected — push-notification copy, NSE rendering — keep their current behavior; plumbing the repo into those is a follow-up.)*
- [ ] **Manual contact removal.** Can a user delete a contact (separate from blocking)? If yes, what happens when they next appear in a shared group action? *(Recommendation: ship without manual removal; revisit after user feedback. Blocking covers the most common "I don't want this person to message me" intent already.)*
- [ ] **Self-contact.** Does the local user appear as their own contact (for "note to self")? *(Recommendation: no for V1. The coordinator filters self via `DBInbox`.)*
- [ ] **Quarantine TTL.** Default 7 days. Validate with product / privacy review before Phase 2.6 ships.
- [ ] **Quarantine UX.** No surface for held conversations in V1. Should there be a "message requests" tray for power users who want to see what was filtered out? Tracked as a follow-up — not in V1.
- [ ] **Empty state on contact card.** What is shown when a contact has zero shared conversations remaining (Step 2.5)? *(Recommendation: empty state with avatar / name and a "Start a conversation" CTA.)*
- [ ] **Favorites section in the picker.** What seeds Favorites in V1? Empty / heuristic / explicit favoriting affordance. Defer to designer pass.
- [ ] **Sort policy.** V1 is alphabetical only (per review feedback). Recency-aware sort is a follow-up.
- [ ] **Naming.** "Contacts" — confirmed via review feedback. Wording for the menu entry under "My info" still TBD ("Contacts" vs. "My contacts" vs. "People"). Designer call.
- [ ] **Privacy framing review.** Action-gated auto-add and contact-gated inbound filter together change the messaging-permission model meaningfully. Walk through with privacy / legal before launch.
- [ ] **Recipient-side disclosure for new DMs.** When the local user starts a new DM with a contact whose contact list does *not* include the local user, the message is silently quarantined on the recipient side. Should the sender's UI hint at this possibility? Tracked as a follow-up — not in V1.
- [x] **`addMembers` failure UX in the optimistic-navigation flow (Phase 2.10).** *(Resolved: fold `addMembers` into `ConversationStateMachine.create` so `.ready` means "conversation exists AND its initial members are in it." A failed add transitions to `.error`, not a half-built `.ready`. `NewConversationView`'s standard error UX (the same one the "+" button flow already uses) presents the retry / cancel surface — no bespoke retry banner needed. See Phase 2.10 subtask (a).)*
- [ ] **DM persistence model for "Send a message" (Step 2).** Today, 1:1 DMs are not persisted as `conversation` rows — `StreamProcessor.processMessage` (lines 184-311) consumes them as transport for invite-payload routing. Step 2's "Send a message" CTA needs a destination conversation type. Two options: (1) create a group-of-two under the hood so the new contact-gated filter applies as-is on the inbound side, or (2) extend the persistence model to accept DMs as first-class conversations gated by `InboundConversationFilter`. *(Recommendation: option 1 for V1 to avoid expanding scope; option 2 in a follow-up.)*

## References

- [1-pager (companion document, with wireframes)](./contact-list.md)
- [Wireframes](./contact-list-mocks/)
- [ADR-005: Member Profile System](../adr/005-member-profile-system.md) — per-conversation profile data we synthesize from.
- [ADR-011: Single Inbox Identity Model](../adr/011-single-inbox-identity-model.md) — the identity model that lets us key on inboxId.
- [docs/identity-system-overview.md](../identity-system-overview.md) — broader identity context.
- [docs/plans/show-pending-invites-home-view.md](./show-pending-invites-home-view.md) — related but distinct surface for pending invites.
- [docs/plans/invite-system-single-inbox.md](./invite-system-single-inbox.md) — invite-accept flow.
- `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift` — migration registration site.
- `ConvosCore/Sources/ConvosCore/Storage/Repositories/ConversationsRepository.swift` — main-feed read path; updated to exclude quarantined rows.
- `ConvosCore/Sources/ConvosCore/Syncing/StreamProcessor.swift` — inbound-conversation arrival site. `shouldProcessConversation` lines 713-739 is the existing consent + outgoing-join-request gate that the new `InboundConversationFilter` extends; `processConversation` lines 140-145 calls it; `processMessage` lines 184-311 handles DM-as-invite-transport.
- `ConvosCore/Sources/ConvosCore/Syncing/InviteJoinRequestsManager.swift` — `hasOutgoingJoinRequest(for:client:)` lines 149-154 (the existing invite-flow elevator); `processJoinRequestOutcome(message:client:)` lines 106-115 (DM-borne invite payload validator).
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift` — `addMembers` hook site for member-added trigger.
- `ConvosCore/Sources/ConvosCore/Storage/Writers/MessagesWriter.swift` (or equivalent) — first-outbound-message hook site for the primary auto-add trigger; confirm exact file during implementation.
- `Convos/Conversation Detail/NewConversationView.swift` and `NewConversationViewModel.swift` — the existing "+" button flow that Phase 2.10 piggybacks on. Phase 2.10 adds a `.newConversationWithMembers([String])` case to `NewConversationMode` and threads the inboxes through to `ConversationStateMachine.create(initialMemberInboxIds:)`.
- `ConvosCore/Sources/ConvosCore/Sessions/ConversationStateMachine.swift` and `ConversationStateManager.swift` — Phase 2.10's surgical changes live here: `.create` action gains `initialMemberInboxIds`, init gains an `addMembers: @Sendable ([String], String) async throws -> Void = { _, _ in }` hook, `handleCreate` runs the hook between XMTP publish and `.ready`. `ConversationStateManager` wires the hook to `ConversationMetadataWriter.addMembers(_:to:)`. Concern #3 audit also lives here — confirm warm-cached id is resumed, not re-published.
- `ConvosCore/Sources/ConvosCore/Sessions/SessionManager.swift` `prepareNewConversation()` + the `unusedConversationCache` it consumes from — Phase 2.10 does NOT modify this; the existing consume-then-mark-used flow is sufficient when `addMembers` is folded into `.create`.
