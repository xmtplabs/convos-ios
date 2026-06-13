# Feature: Agent Templates — Phase 2

> **Status**: Draft
> **Author**: Cameron Voell
> **Created**: 2026-05-20
> **Updated**: 2026-05-20
> **Companion 1-pager**: [agent-templates.md](./agent-templates.md)
> **Phase 1 PRD**: [agent-templates-phase-1-prd.md](./agent-templates-phase-1-prd.md)
> **Related**: [contact-list-prd.md](./contact-list-prd.md), `convos-backend` PR #199 (`feat/agent-templates-crud`)

## Overview

Phase 1 shipped the share-and-instantiate loop: a user in a chat with a template-backed agent can open its contact card, Share its `publishedUrl`, spawn a fresh instance via "Pop up a convo", and route into a new conversation from a `convos://template/<id>` deeplink or QR scan. Discovery in Phase 1 is entirely chat-mediated - there is no contacts surface for agents.

Phase 2 integrates agent templates into the contacts system established by the contacts PRD. A template the user has encountered - by scanning its QR, tapping its deeplink, or simply being in a conversation that contains an instance of it - is saved as a contact. That contact appears in the main contacts list alongside human contacts, opens the same contact card the chat-side entry already uses, and is selectable in the contacts picker so the user can drop a fresh instance into a new or existing conversation without needing the original share link again.

The defining architectural decision of Phase 2: **an agent-template contact is keyed by its `templateId`, not by an `inboxId`.** A human contact is one inbox = one person (ADR-011). A template, once instantiated, produces a distinct agent `inboxId` in every conversation it joins - so the stable identity of the *contact* is the template, not any individual running instance. This requires a contact table separate from `DBContact`, keyed by `templateId`. This supersedes the data-model assumption in the 1-pager (FAQ #7c) and the Phase 1 PRD's Technical Design, both of which predate this decision and assumed agent contacts would live on `DBContact` keyed by `inboxId`.

## Problem Statement

After Phase 1, an agent template is only reachable if the user still has the share link or is still inside a conversation that contains an instance of it. There is no durable, browsable record of "agents I have access to." A user who was in a group with someone else's useful agent last week has no way to start their own conversation with that template today - the 1-pager's "cross-conversation discoverer" persona (Jarod) is entirely unserved by Phase 1.

The contacts PRD already built the browse list, the contact card, the picker, and a passive auto-add hook (`ContactSyncCoordinator`) for human contacts. Phase 2's job is to make agent templates first-class citizens of that same system - so an agent is, as the 1-pager's counterintuitive angle puts it, "a contact, not a tool": it lives in the same list, opens from the same card, and is picked from the same picker as a human.

## Goals

- [ ] **Durable template contacts.** A template the user has encountered is persisted locally as a contact keyed by `templateId`, surviving app restarts and independent of whether the user still holds the share link.
- [ ] **Automatic, mechanism-unified capture.** Scanning an agent QR, tapping a template deeplink, and organically being in a conversation with a template-backed agent all converge on a single capture mechanism - the membership-sync hook - so there is exactly one code path to reason about.
- [ ] **Agent templates in the contacts list.** Agent-template contacts render in the main `ContactsView` browse list, mixed alphabetically with human contacts and tagged with an `AGENT` badge.
- [ ] **One contact card, consistent behavior.** Opening an agent-template contact from the contacts list shows the same `ContactCardView` the chat-side member tap already opens, with the same Share and "Pop up a convo" actions.
- [ ] **Agent templates in the picker.** The contacts picker surfaces agent-template contacts as a selectable row type alongside humans, in both the new-conversation and add-to-conversation modes.
- [ ] **Spawn from the picker.** Selecting an agent-template contact for a new conversation spawns a fresh instance into it on creation; selecting one in add-to-conversation mode spawns a fresh instance into the existing conversation.
- [ ] **Filter by people or agents.** The contacts list and the contacts picker both expose an All / Humans / Agents filter, so either surface can be scoped to just people or just agents.
- [ ] **(Stretch) Shared-conversations section.** Both human and agent-template contact cards gain a section listing the conversations the user shares with that contact, each row rendered like a conversation-list row.
- [ ] **No regressions.** Human contacts, the existing contacts list, picker, and contact card behave exactly as before. Phase 1's chat-side agent surfaces are unchanged.

## Non-Goals

Phase 2 explicitly does NOT:

- **Build the agent builder / editor.** No create, edit, duplicate, fork, avatar upload, prompt editor, or publish surfaces. That is the separate Builder workstream, out of scope across both phases.
- **Implement the existing-1:1 short-circuit (1-pager P2.5).** Tapping "Pop up a convo" / picking an agent always spawns a fresh instance, as in Phase 1. The "if you already have a 1:1 with this agent, navigate there instead" behavior remains a tracked fast-follow and is intentionally not in this PRD's scope - flagged so reviewers comparing against the 1-pager see the deliberate choice.
- **Add a Block action for agent-template contacts.** Agent-template contacts support **Remove only** (see User Stories). Block - which for a human gates inbound conversation invites by `inboxId` - has no clean meaning for a template, every instance of which is a different inbox. Not in scope.
- **Implement shared agent context / instance lineage.** Every spawned instance is independent (instance-per-conversation), as in Phase 1. See the 1-pager's shared-agent-context UAQ.
- **Build a template marketplace, search, or directory.** Discovery is still capture-on-encounter plus the picker; no global browse.
- **Prevent multi-instance-per-conversation.** Picking the same template twice, or adding a template already present in a conversation, is permitted in V2 (see Open Questions).

## User Stories

### As a user who scanned an agent's QR code, I want that agent saved so I can find it again.

Acceptance criteria:

- [ ] After the scanned-template flow creates a conversation and the agent joins, the template is present as a contact in the contacts list.
- [ ] The same is true for the `convos://template/<id>` deeplink-tap flow and for organically being added to a group that already contains a template-backed agent.
- [ ] Encountering the *same* template across multiple conversations results in exactly **one** contact row (keyed by `templateId`), not one per conversation.
- [ ] Capture is best-effort and idempotent: re-encountering a template the user already has does not duplicate or error.

### As a user, I want agent templates to appear in my contacts list and behave like any other contact.

Acceptance criteria:

- [ ] Agent-template contacts render in `ContactsView`, mixed alphabetically with human contacts, each tagged with an `AGENT` badge.
- [ ] Tapping an agent-template row opens `ContactCardView` in standalone mode, showing the same Share and "Pop up a convo" actions the chat-side card already shows for a template-backed agent.
- [ ] "Pop up a convo" from the standalone card spawns a fresh instance into a new conversation, identical to the chat-side behavior.
- [ ] Share offers the iOS share sheet with the template's `publishedUrl`.
- [ ] Legacy verified assistants (verified agents with no `templateId`) do **not** appear in the contacts list - the existing hidden-assistant behavior is preserved.

### As a user, I want to remove an agent-template contact I no longer want.

Acceptance criteria:

- [ ] The agent-template contact card and/or list row exposes a Remove action.
- [ ] Removing deletes the local contact row.
- [ ] If the user is still in a conversation containing an instance of that template, the next membership sync re-adds it - the same eventual-consistency story as human contacts (1-pager FAQ #5). This is acceptable and expected; the PRD does not add guardrails against it.
- [ ] There is no Block action for agent-template contacts.

### As a user creating a new conversation, I want to pick an agent template the same way I pick a friend.

Acceptance criteria:

- [ ] The contacts picker shows agent-template contacts as selectable rows alongside human contacts, with the `AGENT` badge and the same selected-pill treatment.
- [ ] The user can select any mix of human contacts and agent-template contacts in a single picker session.
- [ ] On confirm, the new conversation is created with the selected humans as members and one freshly spawned instance per selected template joined into it.
- [ ] `.ready` remains a strong guarantee that the conversation exists and all selected humans and agents are in it.

### As a user in an existing conversation, I want to add an agent template to it.

Acceptance criteria:

- [ ] The chat plus-menu's "Add from Contacts" entry (contacts picker in `.addToConversation` mode) shows agent-template contacts as selectable.
- [ ] Selecting one and confirming spawns a fresh instance of that template and joins it into the existing conversation.
- [ ] On failure (agent-pool exhaustion, archived template), the user sees the same error UX as the new-conversation spawn path.

### As a user with many contacts, I want to filter my list and the picker to just people or just agents.

Acceptance criteria:

- [ ] The contacts list (`ContactsView`) exposes an All / Humans / Agents filter. Selecting Humans hides agent-template contacts; selecting Agents hides human contacts; All shows both.
- [ ] The contacts picker exposes the same filter, in both the new-conversation and add-to-conversation modes.
- [ ] The filter is presentation-only - it does not mutate selection state. Switching the filter in the picker while contacts are selected preserves the selection.
- [ ] The filter composes with search: searching within a filtered scope narrows further.
- [ ] The list and picker use the same filter control so the two surfaces behave identically (the 1-pager's "shared filter row" intent).

### (Stretch) As a user, I want to see every conversation I share with a contact, on the contact card.

Acceptance criteria:

- [ ] Both human and agent-template contact cards include a "Convos with you" section listing every conversation the user shares with that contact.
- [ ] Each row renders like a conversation-list row - title, last-message timestamp, last-message preview.
- [ ] For a human contact, "shared" means the contact's `inboxId` is a member; for an agent-template contact, it means a member's profile carries that `templateId`.
- [ ] Tapping a row navigates into that conversation.

## Technical Design

### Architecture

Phase 2 is almost entirely `ConvosCore` (a new contact table, repository, writer, an extension to `ContactSyncCoordinator`) plus the main `Convos` app (contacts-list rendering, the standalone contact card, the picker extension). No new `ConvosCoreiOS` bridge is needed.

The central modeling question - **how an agent-template contact relates to the existing `Contact` / `DBContact` type** - is left to a `swift-architect` pass. Two stored-row identity spaces (`inboxId` for humans, `templateId` for templates) cannot share one table cleanly, so the storage layer is two tables. At the presentation layer the options are: (a) a distinct `AgentTemplateContact` type with `ContactCardView`, the list, and the picker generalized to accept either; (b) a sum-typed `Contact` carrying an identity-kind discriminator; (c) synthesizing a `Contact`-shaped value for the template case. The PRD's recommendation is (a) - an explicit second type - but the choice is a Technical Design deliverable, not a PRD mandate.

**Dependencies (existing code Phase 2 extends):**

- `ConvosCore/.../Contacts/ContactSyncCoordinator.swift` - the membership-sync hook that today upserts `DBContact` rows. Extended to also emit agent-template-contact rows for members whose `DBMemberProfile` metadata carries a `templateId`.
- `ConvosCore/.../Storage/SharedDatabaseMigrator.swift` - a new migration for the `agentTemplateContact` table.
- `Convos/Contacts/ContactsViewModel.swift` - `rebuildSections` extended to merge agent-template contacts into the alphabetical list.
- `Convos/Contacts/ContactsPickerViewModel.swift` - the selection model (today `selectedInboxIds: Set<String>`) generalized to a heterogeneous selection of humans and templates.
- `Convos/Contacts/ContactCardView.swift` / `ContactCardMode.swift` - standalone mode rendering for an agent-template contact (the card already renders Share + "Pop up a convo" for template-backed agents from Phase 1).
- `Convos/Conversations List/ConversationsViewModel.swift` - the `.contactsRequestedNewConversation` / `.contactsRequestedAgentTemplateConversation` notification handlers, extended for mixed picker selections.

### Data Model

A new GRDB table, keyed by `templateId`. Profile fields are a most-recent-wins snapshot, mirroring `DBContact`'s pattern - updated as fresh instance profiles are observed.

```swift
struct DBAgentTemplateContact: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
    static let databaseTableName = "agentTemplateContact"

    var id: String { templateId }

    let templateId: String          // Primary key - backend AgentTemplate.id (UUID)
    let addedAt: Date
    let addedViaConversationId: String?   // Conversation the template was first observed in

    var displayName: String?        // Agent name, most-recent-wins from instance profiles
    var emoji: String?              // Template emoji - the stable visual for a non-scoped row
    var descriptionText: String?    // Template description
    var publishedURL: String?       // Backend publishedUrl - drives the Share action
    var avatarURL: String?          // Best-effort; see note below
    var agentVerification: AgentVerification?
    var profileUpdatedAt: Date?     // Most-recent-wins timestamp
}
```

Migration (Phase 2.1):

```swift
migrator.registerMigration("createAgentTemplateContactTable") { db in
    try db.create(table: "agentTemplateContact") { t in
        t.column("templateId", .text).notNull().primaryKey()
        t.column("addedAt", .datetime).notNull()
        t.column("addedViaConversationId", .text)
        t.column("displayName", .text)
        t.column("emoji", .text)
        t.column("descriptionText", .text)
        t.column("publishedURL", .text)
        t.column("avatarURL", .text)
        t.column("agentVerification", .text)
        t.column("profileUpdatedAt", .datetime)
    }
}
```

Notes:

- **No `blockedAt` column.** Agent-template contacts support Remove (row delete) only - see Non-Goals. Remove is a `DELETE`, not a soft-delete flag.
- **Emoji is the primary visual.** A running instance's avatar is encrypted per-conversation and does not decrypt outside the conversation it belongs to, so it is not a reliable visual for a non-scoped contacts-list row. The template `emoji` (already published in profile metadata, read in Phase 1 via `Profile.agentTemplateEmoji`) is the stable identity; `avatarURL` is stored best-effort and renderers fall back emoji -> monogram.
- **Source of the snapshot fields.** `displayName`, `emoji`, `descriptionText`, `publishedURL`, `agentVerification` are all read from the per-conversation `DBMemberProfile` of an encountered instance - the same metadata Phase 1 already surfaces (`agentTemplateId`, `agentTemplatePublishedURL`, `agentTemplateEmoji`, `agentTemplateDescription`). Phase 2 adds no new profile-codec dependency.

The `DBContact` table is unchanged. The contacts list and picker become a **union** of `DBContact` rows (humans, still filtered `!isVerifiedAgent`) and `DBAgentTemplateContact` rows (all shown).

### API Changes

Phase 2 introduces **no new read endpoints** - all template display data comes from profile metadata already flowing in Phase 1.

The one external dependency is **instantiating a template into an existing conversation** (Phase 2.5). The 1-pager flagged this as a brand-new backend endpoint (`templateId` + existing `conversationId` -> instance joins) that "does not exist yet" and called it "the single largest external dependency for Phase 2." However, Phase 1's PR 2 extended `POST /v2/agents/join` to accept `slug + templateId`, and an existing conversation already has an invite slug. So the open question (see Risks and Open Questions) is whether `requestAgentJoin(slug: <existing conversation's invite slug>, templateId:)` already joins the existing conversation, removing the dependency entirely - or whether a distinct endpoint is genuinely required. **This must be confirmed with the backend lead before Phase 2.6 is committed**; per the scoping decision, add-to-existing is core Phase 2 scope and Phase 2 is not "done" without it, so a hard backend dependency here would block that sub-phase.

### UI/UX

Phase 2 introduces no new top-level navigation. Surfaces affected:

| Surface | Today | Phase 2 |
|---|---|---|
| `ContactsView` browse list | Human contacts only (`!isVerifiedAgent` filter) | Humans + agent-template contacts, mixed alphabetically, agent rows tagged `AGENT`, plus an All / Humans / Agents filter |
| Tap an agent-template row | n/a (agents not listed) | Opens `ContactCardView` in standalone mode |
| `ContactsPickerView` (new conversation) | Human candidates only | Humans + agent-template contacts both selectable, plus the All / Humans / Agents filter |
| `ContactsPickerView` (add to conversation) | Human candidates only | Humans + agent-template contacts both selectable, plus the All / Humans / Agents filter |
| Agent-template contact card | Chat-scoped entry only (Phase 1) | Also reachable standalone from the contacts list |
| Contact card (both kinds, stretch) | No shared-conversations section | "Convos with you" section listing shared conversations |

**List treatment.** Agent rows sit inline in the alphabetical sections with an `AGENT` badge - not a separate section. On top of that inline mixing, an All / Humans / Agents filter scopes the list to one kind. The filter is a shared control reused by the picker, so browse-and-pick feel consistent (the 1-pager's "shared filter row" note). The exact control style - chip row, segmented control, menu - and the badge placement are designer calls (see Open Questions).

**Picker selection.** Selected agent-template contacts get the same selected-pill treatment in the "To" header as selected humans; the `AGENT` badge persists on the row when selected so the user can tell which selections will spawn fresh instances on confirm. The All / Humans / Agents filter is presentation-only and never alters what is selected.

**Wireframes:** see [agent-templates.md](./agent-templates.md), surfaces 4 (contacts list with agents) and 5 (picker with agents) - both of which draw the filter row.

## Implementation Plan

Stacked PRs via Graphite, one logical chunk per PR, mirroring the contacts PRD and Phase 1 PRD cadence.

### Phase 2.1: Data layer

- [ ] `DBAgentTemplateContact` GRDB record + `createAgentTemplateContactTable` migration.
- [ ] `AgentTemplateContact` presentation model (resolve the human-vs-template type relationship - see Technical Design - with `swift-architect`).
- [ ] `AgentTemplateContactsRepository` / `…Protocol` with a reactive publisher and fetch-by-templateId, mirroring `ContactsRepository`.
- [ ] `AgentTemplateContactsWriter` with an idempotent most-recent-wins `upsert` and a `remove`, mirroring `ContactsWriter`.
- [ ] Unit tests: upsert idempotency, most-recent-wins field merge, remove.

Ship-readiness: data layer fully tested; no UI yet.

### Phase 2.2: Passive auto-add

- [ ] Extend `ContactSyncCoordinator` so that, alongside the existing per-member `DBContact` upsert, members whose `DBMemberProfile` metadata carries a `templateId` also upsert a `DBAgentTemplateContact` row.
- [ ] Confirm the scanned-QR and `convos://template/<id>` deeplink flows both land their spawned agent in a conversation whose membership sync runs the new emit - so all three capture paths (scan, deeplink, organic group membership) are covered by the one hook.
- [ ] Unit tests: a conversation with a template-backed agent yields an agent-template-contact row; the same template across two conversations yields one row; a conversation with only human / legacy-verified-agent members yields no agent-template-contact rows.

Ship-readiness: template contacts are being captured into the new table; no UI exposure yet.

### Phase 2.3: Contacts list + standalone contact card

- [ ] `ContactsViewModel.rebuildSections` merges agent-template contacts into the alphabetical sections; agent rows carry an `AGENT` badge. The `!isVerifiedAgent` filter on `DBContact` rows stays.
- [ ] Tapping an agent-template row opens `ContactCardView` in standalone mode, hydrated from `DBAgentTemplateContact`.
- [ ] The standalone agent-template card renders Share + "Pop up a convo" (already implemented for template-backed agents in Phase 1) plus a Remove action that deletes the contact row.
- [ ] SwiftUI Previews; manual check against [agent-templates.md](./agent-templates.md) surface 4.

Ship-readiness: agent templates are browsable and openable from the contacts list; Share and spawn work standalone.

### Phase 2.4: Picker accepts agent-template contacts (new conversation)

- [ ] Generalize the picker selection model from `selectedInboxIds: Set<String>` to a heterogeneous selection of human inboxIds and agent templateIds.
- [ ] `ContactsPickerViewModel.rebuildSections` includes agent-template contacts as selectable rows.
- [ ] Extend the new-conversation create path so a confirmed mixed selection adds the human members and spawns one fresh instance per selected template. This touches the `.contactsRequestedNewConversation` payload (today inboxIds-only) and the `ConversationStateMachine` create sequence; reuse the Phase 1 `.newConversationWithTemplate` spawn-at-`.ready` mechanism, generalized to N templates.
- [ ] Unit tests: mixed selection produces the right member set + spawn count; multiple templates each spawn once.

Ship-readiness: a user can start a new conversation with any mix of humans and agents from the picker.

### Phase 2.5: Humans / Agents filter (contacts list + picker)

A shared All / Humans / Agents filter for both browse surfaces. Sequenced before Phase 2.6 deliberately: it depends only on agents being present in the list (2.3) and the picker (2.4), not on the backend-dependent add-to-existing work, so it should not be stacked behind that dependency.

- [ ] A shared filter state / control (All / Humans / Agents) usable by both `ContactsViewModel` and `ContactsPickerViewModel`.
- [ ] `ContactsView` renders the filter; selecting a scope hides the other contact kind. Composes with the existing alphabetical sectioning.
- [ ] `ContactsPickerView` renders the same filter in both `.newConversation` and `.addToConversation` modes. The filter is presentation-only - it does not mutate the heterogeneous selection - and composes with the picker's existing search.
- [ ] Unit tests: each filter scope yields the expected row set on both surfaces; filter + search compose; switching the filter preserves picker selection.

Ship-readiness: both browse surfaces can be scoped to people or agents.

### Phase 2.6: Add an agent instance to an existing conversation

- [ ] Confirm the backend contract (see API Changes / Risks) before committing this sub-phase.
- [ ] The picker in `.addToConversation` mode surfaces agent-template contacts; confirming a selected template spawns a fresh instance and joins it into the existing conversation.
- [ ] Error UX matches the new-conversation spawn path.
- [ ] Integration test against a local backend: add a template to an existing conversation -> the agent member appears with the expected `templateId` on its profile snapshot.

Ship-readiness: the chat plus-menu's "Add from Contacts" entry can add agents; Phase 2's contacts integration is feature-complete.

### Phase 2.7 (stretch): Shared-conversations section

Explicitly optional - cut if the Phase 2.1-2.6 stack runs long.

- [ ] A "Convos with you" section on both the human and agent-template contact cards, listing every conversation shared with that contact.
- [ ] Each row renders like a conversation-list row (title, last-message timestamp, last-message preview) and navigates into the conversation on tap.
- [ ] For an agent-template contact the "shared" query is "conversations containing a member whose profile carries `templateId` T." `templateId` is not a column on `conversation_members` today - it lives in `memberProfile.metadata` - so this sub-phase needs either a denormalized `templateId` column / index or an accepted metadata scan. Flagged as a Technical Design item for `swift-architect`.
- [ ] Unit tests for both the inboxId-based and templateId-based shared-conversation queries.

Ship-readiness: contact cards show shared history; ready to flip the Phase 2 feature flag.

## Testing Strategy

**Unit tests** (`ConvosCoreTests`, no Docker needed):

- `AgentTemplateContactsWriter` - upsert idempotency, most-recent-wins merge, remove.
- `ContactSyncCoordinator` - a template-backed agent member yields an agent-template-contact row; same template across conversations yields one row; human-only / legacy-verified-agent-only conversations yield none.
- Picker selection model - heterogeneous selection round-trips; pruning a removed contact drops it from the selection.
- Humans / Agents filter - each scope yields the expected row set on the list and the picker; filter composes with search; switching the filter preserves picker selection.
- (Stretch) shared-conversation queries for both the inboxId and templateId paths.

**Integration tests** (require Docker via `./dev/up`, plus a fixture template):

- Scan / deeplink / organic-membership all land a row in `agentTemplateContact`.
- New conversation from a mixed picker selection: members + spawned agents all present at `.ready`.
- Add-to-existing: a confirmed template selection joins a fresh instance into the existing conversation.

**Manual / QA test plan** (`qa/tests/<NN>-agent-templates-phase-2.md`):

- Scan an agent QR, confirm it appears in the contacts list afterward.
- Open an agent-template contact from the list; verify Share + "Pop up a convo" + Remove.
- Remove a template contact; confirm it re-appears after the next sync if a shared conversation still contains an instance.
- Create a new conversation with 2 humans + 1 agent from the picker.
- Add an agent to an existing group via "Add from Contacts".
- Confirm legacy verified assistants stay hidden from the list and picker.

**Architecture review:** hand the human-vs-template type relationship and the picker selection-model refactor to `swift-architect` before Phase 2.1 and Phase 2.4 respectively.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| The add-to-existing-conversation backend contract is genuinely a new endpoint, not covered by `agents/join` + an existing slug | High | Confirm with the backend lead before committing Phase 2.6. Phase 2.1-2.5 are independent of it and ship first; per the scoping decision Phase 2 is not "done" without 2.6, so surface the dependency early. |
| The picker selection-model refactor (inboxIds-only -> heterogeneous) ripples into `.contactsRequestedNewConversation`, the state machine, and existing picker tests | Medium | Land it as its own PR (2.4) with the human-only path regression-tested first; `swift-architect` review before implementation. |
| The human-vs-template presentation-type decision is made ad hoc and fragments the contact card / list / picker | Medium | Resolve it explicitly in Phase 2.1 with `swift-architect`; every later sub-phase depends on a settled type. |
| A captured template is later archived / deleted on the backend (returns 410) | Low | The contact row persists; Share opens a dead link and "Pop up a convo" surfaces the existing `APIError.templateArchived` (410) error from Phase 1. Acceptable degradation; no special handling. |
| Auto-add races the profile-snapshot sync, capturing a template before its name / emoji metadata has arrived | Low | Most-recent-wins upsert - a later snapshot fills in the fields; the row is usable (templateId-keyed) even with a sparse first capture. |
| Removed templates re-appear and confuse users | Low | Documented eventual-consistency behavior (1-pager FAQ #5); the re-add only happens while the user is still in a shared conversation. Accepted, not mitigated. |

## Open Questions

- [ ] **Add-to-existing-conversation backend contract.** Does `POST /v2/agents/join` with an existing conversation's invite slug + `templateId` already join that conversation, or is a distinct `templateId` + `conversationId` endpoint required? Blocks Phase 2.6. (See API Changes.)
- [ ] **Filter control style and default state.** Is the All / Humans / Agents filter a chip row, a segmented control, or a menu? And does it default to All, to Humans (preserving today's people-only list), or remember the user's last selection? Designer / product call (1-pager Phase 2 UAQ).
- [ ] **`AGENT` badge placement.** Inline on each row vs. a section divider between humans and agents - designer call (1-pager Phase 2 UAQ).
- [ ] **The "Assistants" Convos-menu entry.** With the contacts list now the agent browse surface, does the existing top-left-menu "Assistants" entry get retired, rebranded to "Agents", or kept pointing at the legacy hardcoded join flow? Needs a product call (1-pager FAQ #4).
- [ ] **Multi-instance-per-conversation.** Should the picker prevent selecting the same template twice for one conversation, or hide a template already present when in `.addToConversation` mode? Nice-to-have guard, not a correctness bug (1-pager Phase 2 UAQ).
- [ ] **Existing-1:1 short-circuit (1-pager P2.5).** Deferred out of this PRD's scope. Decide whether it becomes a Phase 2 fast-follow PR or its own small plan.
- [ ] **(Stretch) shared-conversation query for templates.** Denormalize `templateId` onto `conversation_members`, or accept a `memberProfile.metadata` scan? Technical Design call in Phase 2.7.

## References

- [Agent Templates 1-pager](./agent-templates.md) - surfaces 4 and 5, Phase 2 items P2.1-P2.5, personas, UAQ.
- [Agent Templates Phase 1 PRD](./agent-templates-phase-1-prd.md) - the chat-side agent surfaces, the spawn-and-join flow, the profile-metadata read path Phase 2 reuses.
- [Contacts PRD](./contact-list-prd.md) - the contact-card mode pattern, the contacts list / picker, the `ContactSyncCoordinator` auto-add hook Phase 2 extends.
- `ConvosCore/.../Contacts/ContactSyncCoordinator.swift` - the membership-sync hook extended in Phase 2.2.
- `ConvosCore/.../Storage/Database Models/DBContact.swift` - the human-contact table whose shape `DBAgentTemplateContact` mirrors.
- `Convos/Contacts/ContactsPickerViewModel.swift` - the picker selection model refactored in Phase 2.4.
- `Convos/Contacts/ContactCardView.swift` - the contact card already rendering Share + "Pop up a convo" for template-backed agents (Phase 1).
- `convos-backend` PR #199 (`feat/agent-templates-crud`) - the template CRUD; the add-to-existing endpoint question is downstream of this.
