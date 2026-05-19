# Feature: Agent Templates — Phase 1

> **Status**: Draft
> **Author**: Cameron Voell
> **Created**: 2026-05-19
> **Updated**: 2026-05-19
> **Companion 1-pager**: [agent-templates.md](./agent-templates.md)
> **Phase 2 PRD**: TODO — `agent-templates-phase-2-prd.md` (contacts-list + picker integration, deferred)
> **Related**: [contact-list-prd.md](./contact-list-prd.md), `convos-assistants/website` (web preview already deployed at `agents-dev.convos.org`), `convos-backend` PR #199 (`feat/agent-templates-crud`)

## Overview

Agent Templates lets a user share an AI agent like a contact card. A template owner taps Share on the agent's contact view, drops the resulting link into any chat or messaging surface, and the recipient lands in a fresh conversation with their own private instance of the agent. Phase 1 ships the minimum viable loop: in-chat avatar-tap → agent contact view → Chat (spawn) / Share (deeplink). No contacts-list integration, no picker integration, no add-to-existing-conversation — those are Phase 2.

Discovery in Phase 1 happens entirely through the deeplink mechanism. A `convos://template/<id>` URL inside a Convos message body renders as a clean card; a `https://agents-dev.convos.org/<id>` Universal Link tapped on a device with Convos installed routes into the app and spawns; the same link tapped on a device without Convos lands on the install-prompt page that's already deployed by `convos-assistants/website`.

Phase 1 is also the integration point with two cross-team dependencies: the backend's in-progress instantiation endpoint (templateId + new-conversation invite slug → instance joins), and the agent-side `templateId` profile-snapshot field that lets the iOS client recognise which template a verified agent in a chat came from.

## Problem Statement

Today, the only way to add an AI agent to a Convos conversation is the hardcoded "Convos Assistant" path via `POST /v2/agents/join` — same prompt, same name, same avatar, no customization. The backend has shipped CRUD for user-built agent templates (PR #199), and a web preview at `agents-dev.convos.org/<idOrHashedSlug>` already exists. The website's QR codes encode `convos-dev://template/<id>` deeplinks; the website's `lib/deep-link.ts` literally says "convos-ios does not yet have a matching `DeepLinkHandler` destination." The end-to-end share flow is one iOS PR and one AASA file away from working.

Phase 1 closes the loop on the share-and-instantiate primitive. Phase 2 will then build the broader contacts surface on top.

## Goals

- [ ] **In-chat agent contact view.** Tapping a verified agent's avatar inside a chat (member-list row, message-author avatar, read-receipts row) opens a contact-card variant that surfaces the agent's template metadata (name, description, category, emoji, skills) and a primary **Chat** CTA + secondary **Share** CTA.
- [ ] **Share-the-agent loop.** Tapping Share offers the iOS share sheet with `https://agents-dev.convos.org/<templateId>`. Recipients with Convos installed → Universal Link routes into the app and spawns a fresh instance into a new conversation. Recipients without Convos → land on the existing install-prompt page.
- [ ] **Deeplink card rendering.** When a `convos://template/<id>` or `https://agents-dev.convos.org/<id>` URL appears in a Convos message body, the iOS client replaces the inline URL with a preview card (avatar, name, description, "Convos · agent template" footer, "Open ›"). Tapping the card routes to the agent contact view.
- [ ] **Chat button — spawn-and-join.** Tapping Chat calls the (in-progress) Phase-1 instantiation endpoint with the template id and a freshly-created conversation invite slug; the backend claims an agent-pool instance, configures it with the template's prompt / name / avatar / tools / connections, and joins it into the new conversation. `.ready` is a strong guarantee that the conversation exists AND the agent has joined.
- [ ] **iOS-side templateId binding.** When a verified agent member publishes a `templateId` field on its per-conversation profile snapshot, the iOS client reads it, fetches the template via the public detail endpoint, and stores it on the existing `DBContact` row so the contact-view variant can resolve.
- [ ] **No regressions.** All existing `agents/join` flows continue to work unchanged. The existing in-chat member-tap path for human members and for legacy verified agents (no templateId) is preserved.

## Non-Goals

Phase 1 explicitly does NOT:

- **Touch the contacts list.** Agents do not appear in the main contacts browse list; the existing `!$0.isVerifiedAgent` filter in `ContactsViewModel.rebuildSections` stays. The Convos top-left menu's "Contacts" entry is unchanged. The agent contact view is reachable ONLY from inside a chat in Phase 1. **All contacts integration is Phase 2.**
- **Touch the contacts picker.** The `ContactsPickerView` (new-conversation and add-to-conversation modes) does not surface templates. The chat plus-menu's "Add from Contacts" entry continues to surface humans only.
- **Add an agent instance to an existing conversation.** That requires a separate backend endpoint that does not exist yet (templateId + existing conversationId → instance joins). Phase 1's Chat button and Universal Link both always create a *new* conversation. The plus-menu's existing path is untouched.
- **Implement the existing-1:1 short-circuit.** Tapping Chat in Phase 1 always spawns a new instance. The "if you already have a 1:1 with this agent, navigate there instead" affordance is a Phase-1 **fast-follow** (sub-phase 1.6 below) — wired after the default spawn-and-join flow is solid.
- **Build the web preview page.** It already exists in `convos-assistants/website` and is deployed at `agents-dev.convos.org/<idOrHashedSlug>`. Phase 1's web-side work is exactly the AASA file plus an iOS-side entitlement (sub-phase 1.4 below).
- **Implement the builder / editor.** No Edit, Duplicate, avatar upload, prompt editor, publish, or fork affordances on the contact view. Those are the Builder workstream's scope.
- **Implement version hot-swap.** Once an instance is spawned, it stays pinned to the template version it was instantiated against. Publishing a new template version does not affect running instances.

## User Stories

### As a Convos user already in a chat with a custom agent, I want to tap the agent's avatar and see what template it came from.

Acceptance criteria:

- [ ] Tapping a verified agent's avatar in the member list, on a message bubble, or on the read-receipts row opens the agent contact view (not the existing `ConversationMemberView`).
- [ ] The contact view shows the agent's `agentName`, `description`, `emoji`/`avatarUrl`, `category`, and a "Skills" row backed by `tools[]`.
- [ ] The contact view shows a primary **Chat** button and a secondary **Share Contact** row.
- [ ] If the verified agent has no `templateId` on its profile snapshot (legacy Convos-issued assistants, agents from a backend that hasn't shipped the codec field yet), the legacy `ConversationMemberView` opens instead — no regression.

### As a user, I want to share an agent with friends as easily as sharing a contact card.

Acceptance criteria:

- [ ] Tapping **Share Contact** opens the iOS share sheet with the URL `https://agents-dev.convos.org/<templateId>` (dev) / `https://agents.convos.org/<templateId>` (prod, host TBD).
- [ ] The share sheet preview shows the OG metadata served by the existing convos-assistants/website route — agent name, description, OG image (generated by `og/[slug]/route.tsx`).
- [ ] Dropping the URL into a Convos message body renders inline as a deeplink card (next story).
- [ ] Tapping the URL in iMessage / Mail / Safari on a device with Convos installed routes into the app (Universal Link).
- [ ] Tapping the URL on a device without Convos lands on the existing install-prompt page at `agents-dev.convos.org/<id>` (or `convos.org/<id>` prod equivalent — host TBD).

### As a user, when someone drops an agent share-link in a chat, I want to see a clean preview card instead of a raw URL.

Acceptance criteria:

- [ ] A message body containing `convos://template/<id>`, `convos-dev://template/<id>`, `convos-local://template/<id>`, or `https://agents-dev.convos.org/<id>` renders inline with a card replacing the URL.
- [ ] The card shows the avatar, agent name, description, a "Convos · agent template" footer, and an "Open ›" affordance.
- [ ] Tapping the card opens the agent contact view (same path as tapping the avatar in-chat).
- [ ] If the template returns 404 (deleted, draft visible only to owner), the card falls back to the raw URL.
- [ ] Any other text content in the same message (text before / after the URL) renders normally.
- [ ] The raw URL is still preserved in the message payload so older clients render the link as a clickable URL.

### As a user, I want to start a chat with a new instance of an agent template I just saw.

Acceptance criteria:

- [ ] Tapping **Chat** on the agent contact view (or on a deeplink card) creates a new conversation containing the local user and one fresh instance of the template.
- [ ] The agent joins the conversation within 5 seconds on a healthy agent pool (matches today's `agents/join` envelope).
- [ ] On agent-pool exhaustion (503) or timeout, the user sees the same error UX as today's hardcoded-assistant flow.
- [ ] The new conversation is created with no other members; the user can manually invite others through the normal chat flows.
- [ ] The agent instance publishes a `templateId` field on its per-conversation profile snapshot equal to the template's UUID; the local client stores it on the agent's `DBContact` row.

### As a user without Convos who got an agent share link, I want to know what the agent does before I install.

Acceptance criteria:

- [ ] Tapping the Universal Link on a device without Convos opens the existing install-prompt page at `agents-dev.convos.org/<id>`.
- [ ] The page shows the agent's name, description, emoji/avatar, capability chips, App Store + Google Play install banners, and a QR encoding `convos://template/<id>`.
- [ ] No iOS work is required for this surface — the page already exists in `convos-assistants/website` and is deployed.

## Technical Design

### Architecture

Phase 1 lives almost entirely in `ConvosCore` (data layer, repository, deeplink parsing) and the main `Convos` app (the agent-template contact-card variant, the deeplink-card message renderer, the in-chat avatar-tap routing). No new `ConvosCoreiOS` bridge is needed — there are no UIKit-only dependencies.

**Dependencies (existing code we extend):**

- `Convos/DeepLinking/DeepLinkHandler.swift` — extend `DeepLinkDestination` with `case agentTemplate(templateId: String)` and add parsing for `convos://template/<id>` (and env-prefixed variants) and `https://agents-dev.convos.org/<id>` / prod equivalent.
- `Convos/Config/*.entitlements` — add `applinks:agents-dev.convos.org` (Dev) and the prod host once confirmed.
- `Convos/Contacts/ContactCardView.swift` and `ContactCardMode.swift` — add a new `agentTemplate(template: AgentTemplate)` payload variant on the existing modes, so the card renders agent-template fields when the contact is template-backed.
- `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/` — extend the message-body renderer to detect agent-template URLs and render the `DeeplinkTemplateCardView` inline.
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift` and `ConvosAPIClient+Models.swift` — add `getAgentTemplate(idOrHashedSlug:)` against `GET /api/v2/agent-templates/:idOrHashedSlug`, and `requestAgentJoinFromTemplate(templateId:, inviteSlug:)` against the (in-progress) Phase-1 instantiation endpoint.
- `ConvosCore/Sources/ConvosCore/Storage/Writers/ContactsWriter.swift` and `ContactsProfileSyncWriter` — recognise the new `templateId` field on incoming profile snapshots and persist it on `DBContact`.
- `ConvosCore/Sources/ConvosCore/Sessions/ConversationStateMachine.swift` — extend with the existing `.newConversationWithMembers` pattern from contacts-PRD Phase 2.10, adding a `.newConversationWithTemplate(templateId: String)` case. The state machine spawns the conversation then calls the instantiation endpoint as part of the `.create` action; `.ready` is the strong guarantee that the conversation exists AND the agent has joined.

**New components:**

- `ConvosCore/Sources/ConvosCore/AgentTemplates/AgentTemplate.swift` — the codable presentation model mirroring the backend serializer's response shape (UUID, slug, agentName, description, prompt, category, emoji, avatarUrl, tools, connections, version, firstPublishedAt, status, featured).
- `ConvosCore/Sources/ConvosCore/AgentTemplates/AgentTemplatesRepository.swift` and `…Protocol.swift` — read-side API with `fetchTemplate(idOrHashedSlug:)` and an in-memory + GRDB-backed cache.
- `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBAgentTemplate.swift` — local cache row.
- `Convos/Contacts/AgentTemplateContactCardSection.swift` — the agent-template-specific sections rendered inside `ContactCardView` (About, Skills, Convos with you).
- `Convos/Conversation Detail/Messages/MessagesListView/Messages List Items/DeeplinkTemplateCardView.swift` — the in-chat deeplink-card renderer.
- `Convos/Contacts/AgentTemplateContactCardMode.swift` — small extension to `ContactCardMode` to express "this card is rendering a template-backed contact" without breaking the existing human-member mode split.

### Data Model

A new GRDB-backed cache table for agent templates. The local user's contact row keeps its existing shape — only a single nullable `templateId` column is added for the binding.

```swift
struct DBAgentTemplate: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "agentTemplate"

    let id: String                          // Primary key — backend UUID
    let slug: String                        // Mutable until first publish
    let agentName: String
    let description: String?
    let category: String?
    let emoji: String?
    let avatarUrl: String?
    let tools: String                       // JSON-encoded [String]
    let connections: String                 // JSON-encoded [String]
    let version: Int
    let firstPublishedAt: Date?
    let status: String                      // draft | published | unlisted | archived
    let featured: Bool
    let ownerAccountId: String              // Backend account UUID
    let createdAt: Date
    let cachedAt: Date                      // Local cache freshness, not from server

    enum Columns: String, ColumnExpression {
        case id, slug, agentName, description, category, emoji, avatarUrl
        case tools, connections, version, firstPublishedAt, status, featured
        case ownerAccountId, createdAt, cachedAt
    }
}
```

Migration (Phase 1.1):

```swift
migrator.registerMigration("createAgentTemplateTable") { db in
    try db.create(table: "agentTemplate") { t in
        t.column("id", .text).notNull().primaryKey()
        t.column("slug", .text).notNull()
        t.column("agentName", .text).notNull()
        t.column("description", .text)
        t.column("category", .text)
        t.column("emoji", .text)
        t.column("avatarUrl", .text)
        t.column("tools", .text).notNull().defaults(to: "[]")
        t.column("connections", .text).notNull().defaults(to: "[]")
        t.column("version", .integer).notNull()
        t.column("firstPublishedAt", .datetime)
        t.column("status", .text).notNull()
        t.column("featured", .boolean).notNull().defaults(to: false)
        t.column("ownerAccountId", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("cachedAt", .datetime).notNull()
    }
}
```

`DBContact` gains a single nullable column for the binding (Phase 1.2):

```swift
migrator.registerMigration("addContactTemplateId") { db in
    try db.alter(table: "contact") { t in
        t.add(column: "templateId", .text)
            .references("agentTemplate", onDelete: .setNull)
    }
}
```

`onDelete: .setNull` because a contact survives its template being deleted — the contact still represents a real agent inbox the user has talked to; it just stops resolving to a template after delete.

### API Changes

**Reads (already shipped on `otr-dev`, no changes needed):**

- `GET /api/v2/agent-templates/:idOrHashedSlug` — returns the serialized template. Accepts either a UUID or `<base>.<hash>`. Public; anonymous callers get the published-only view.

**Writes / instantiation (in progress, blocking Phase 1.5):**

- The Phase-1 instantiation endpoint shape is being locked by the backend lead. Two candidate shapes:
  1. Extend `POST /v2/agents/join` with optional body fields `{ templateId: string, ... }` — the existing iOS `requestAgentJoin(slug:instructions:forceErrorCode:)` extends naturally.
  2. New `POST /v2/agent-templates/:id/instances` taking `{ inviteSlug: string }` — cleaner per-resource shape, requires a sibling iOS client method.
- iOS abstracts both via a single `SessionManagerProtocol.spawnAgentInstance(templateId: String, intoNewConversationWithSlug: String)` method so the call site doesn't care which the backend picks.

**Codec / profile-snapshot extension (in progress, blocking Phase 1.2):**

- The agent's per-conversation profile snapshot (the payload that today carries `agentVerification`) gains an optional `templateId: string` field. When present, the iOS client recognises the agent as template-backed.
- No iOS write path for this field — agents publish it themselves; iOS is read-only.

### UI/UX

Phase 1 introduces no new top-level navigation. All entry points are in-chat or via deeplink.

**Screens affected:**

| Surface | Today | Phase 1 |
|---|---|---|
| Tap a verified agent's avatar in a chat | Opens `ConversationMemberView` | Opens the agent contact view (`ContactCardView` in agent-template mode) |
| Member-list row for a verified agent | Opens `ConversationMemberView` on tap | Opens the agent contact view |
| Read-receipts row avatar for a verified agent | Opens `ConversationMemberView` on tap | Opens the agent contact view |
| Message body containing a template URL | Renders as a raw clickable link | Renders inline as the deeplink card |
| Tap a Universal Link to `agents-dev.convos.org/<id>` | Opens Safari | Opens the app at the agent contact view (or spawns directly — see open questions) |
| Scan the QR on `agents-dev.convos.org/<id>` | Currently no-op on iOS (`DeepLinkHandler` doesn't recognise the scheme) | Opens the app at the agent contact view (or spawns directly) |

**Wireframes:** see [agent-templates.md](./agent-templates.md) §2 surfaces 1, 2, and 3.

**Navigation flow:**

```
[in-chat avatar tap] ────► ContactCardView (agentTemplate mode)
[deeplink card tap] ─────► ContactCardView (agentTemplate mode)
[Universal Link tap] ────► ContactCardView (agentTemplate mode) — open question: skip to Chat?
                              │
                              ├──► Chat button ────► new convo + spawn instance
                              └──► Share button ───► iOS share sheet w/ https URL
```

**Legacy preservation:** for verified agents *without* a `templateId` on their profile snapshot (Convos-issued legacy assistants, or backends that haven't shipped the codec field yet), the existing `ConversationMemberView` path continues to fire — the new agent-template card is gated on `contact.templateId != nil`.

## Implementation Plan

Stacked PRs via Graphite, one logical chunk per PR. Each phase below is shippable on its own behind a feature flag; the feature flag flips on once Phase 1.5 lands (the moment the share-and-spawn loop closes end-to-end).

### Phase 1.1: Data layer + API client

- [ ] `AgentTemplate` Codable model in `ConvosCore`.
- [ ] `DBAgentTemplate` GRDB record + `createAgentTemplateTable` migration.
- [ ] `AgentTemplatesRepository` / `AgentTemplatesRepositoryProtocol` with `fetchTemplate(idOrHashedSlug:)` (cache-aside: hit GRDB, fall through to network, write back).
- [ ] `ConvosAPIClient.getAgentTemplate(idOrHashedSlug:)` against the existing `GET /api/v2/agent-templates/:idOrHashedSlug` endpoint.
- [ ] Unit tests for the repository's cache-hit / cache-miss / 404 / cache-write paths.

Ship-readiness: data layer fully tested; can fetch a template by id from a test fixture; no UI yet.

### Phase 1.2: Profile-snapshot `templateId` binding

- [ ] `addContactTemplateId` migration adds the `templateId` nullable column to `contact`.
- [ ] Profile-snapshot decoder reads the new optional `templateId` field (no-op on snapshots without it — backwards-compatible).
- [ ] `ContactsProfileSyncWriter` writes the field to `DBContact` per most-recent-wins (mirrors the existing `agentVerification` write path).
- [ ] `Contact` presentation model gains a `templateId: String?` field and a hydrated `agentTemplate: AgentTemplate?` accessor that lazy-loads from the repository.
- [ ] Unit tests: a profile snapshot carrying `templateId` lands on the contact row; the hydrated accessor fetches and caches the template; older snapshots with no `templateId` leave the column untouched.

Ship-readiness: data is flowing — the moment the backend codec ships, contact rows start populating; no UI exposure yet.

### Phase 1.3: Agent contact view + in-chat entry

- [ ] Extend `ContactCardMode` (or wrap with a new enum) to distinguish "human contact" from "agent-template contact." Existing `.scopedToConversation` mode applies to both with a payload variant.
- [ ] `AgentTemplateContactCardSection` renders the About row (category, version, creator attribution), the Skills chip row backed by `tools[]`, and the "Convos with you" list (filtered to conversations the user shares with this agent's `inboxId`).
- [ ] **Chat** button placeholder — wired in Phase 1.5; Phase 1.3 stub logs and dismisses.
- [ ] **Share Contact** row builds `https://agents-dev.convos.org/<templateId>` (dev) and hands it to the iOS share sheet.
- [ ] Reroute in-chat avatar-tap sites (member list, message author, read-receipts row) to the new card when `member.agentVerification.isVerified && member.contact?.templateId != nil`; otherwise keep the legacy `ConversationMemberView`.
- [ ] SwiftUI Previews with `.mock` data; manual UAQ against the [§2 surface 1 mock](./agent-template-mocks/01-agent-contact-page.svg).

Ship-readiness: tapping a verified-agent avatar (with a templateId) opens the new card; Share works; Chat is stubbed.

### Phase 1.4: DeepLinkHandler + AASA + entitlements

- [ ] Extend `DeepLinkDestination` with `case agentTemplate(templateId: String)`.
- [ ] `DeepLinkHandler.destination(for:)` parses `convos://template/<id>` (and the env-prefixed `convos-dev://`, `convos-local://` forms) and `https://agents-dev.convos.org/<id>` / prod-host equivalent.
- [ ] Add `applinks:agents-dev.convos.org` to `Convos.Dev.entitlements`; add the prod host (TBD — confirm with the web team) to `Convos.Prod.entitlements`.
- [ ] Coordinate with the `convos-assistants/website` team to publish an `apple-app-site-association` file at the root of `agents-dev.convos.org` matching the iOS team identifier and path prefix (`/*` is fine since the single `[slug]` route is the only canonical surface).
- [ ] Routing on tap: `agentTemplate(templateId:)` fetches the template via the Phase 1.1 repository, then presents the agent contact view as a sheet on top of the current navigation stack. Open question on whether to skip the card and go straight to spawn-and-join — see Open Questions.
- [ ] Unit tests for URL parsing (covers all four scheme forms + the HTTPS form + malformed cases that should return nil).

Ship-readiness: scanning the QR on `agents-dev.convos.org/<id>` or tapping the Universal Link both open the app at the agent contact view. The Chat button is still stubbed.

### Phase 1.5: Chat-button spawn-and-join

- [ ] `SessionManagerProtocol.spawnAgentInstance(templateId:intoNewConversationWithSlug:)` — abstracts whichever shape the backend lands on (`agents/join` extension or `agent-templates/:id/instances`).
- [ ] `ConvosAPIClient` implements the call; mock the response shape against the backend's working draft.
- [ ] Extend `ConversationStateMachine` with a `.newConversationWithTemplate(templateId: String)` mode (parallel to Phase 2.10's `.newConversationWithMembers`). `handleCreate` runs the spawn-and-join call between the XMTP group publish and the `.ready` transition; failure transitions to `.error(spawnAgentInstanceFailed(...))`.
- [ ] `NewConversationViewModel` accepts the new mode and surfaces the placeholder VM during spawn (same UX as Phase 2.10's "+" button flow).
- [ ] Wire the Chat button on the agent contact view to construct a `NewConversationViewModel` in this mode and hand it to `ConversationsViewModel.newConversationViewModel`.
- [ ] Feature-flag the Chat button so Phase 1 can ship to TestFlight before the backend endpoint is fully live.
- [ ] Integration test against a local backend: tap Chat on a fixture template → conversation exists in the local DB → agent member appears with `agentVerification.isVerified == true` and `templateId == fixture.id` on its profile snapshot.

Ship-readiness: the end-to-end loop closes. Tap a deeplink card → land on the contact view → tap Chat → land in a new conversation with the agent.

### Phase 1.6 (fast-follow): Deeplink card in chat + existing-1:1 short-circuit

Two surfaces that don't block the rest of Phase 1 but are needed for full polish before flipping the feature flag for production:

- [ ] **Deeplink card renderer.** The message-body URL detector recognises the four scheme forms and the HTTPS host. The card hydrates from the repository (same path as the contact view), falls back to the raw URL on 404, and routes to the agent contact view on tap. Mock: [§2 surface 2](./agent-template-mocks/05-deeplink-card-in-chat.svg).
- [ ] **Existing-1:1 short-circuit on the Chat button.** Before calling the spawn endpoint, query `DBConversationMember` for "exactly 2 members, the local user and an instance of this template's id." If a match exists, navigate into that conversation instead of spawning. Multi-1:1 disambiguation: most-recently-active wins. No disambiguation sheet in V1 (see Open Questions).
- [ ] Apply the same short-circuit to the deeplink-card tap path and the Universal Link tap path (so the heuristic is consistent across every "tap to chat with this agent" entry point).

Ship-readiness: ready to flip the feature flag to production.

## Testing Strategy

**Unit tests** (`ConvosCoreTests`, no Docker needed):

- `AgentTemplatesRepository.fetchTemplate(idOrHashedSlug:)` — cache hit, cache miss → network, 404, cache-write on success.
- `DeepLinkHandler.destination(for:)` — all four custom scheme forms (`convos://`, `convos-dev://`, `convos-local://`, plus malformed), the HTTPS form, the URL pattern with extra query params, malformed UUID.
- `ContactsProfileSyncWriter` — profile snapshot carrying `templateId` writes the column; snapshot without it leaves the column untouched; snapshot with a different `templateId` updates it; snapshot with an empty `templateId` clears it.
- `ConversationStateMachine` — `.newConversationWithTemplate(templateId:)` calls `spawnAgentInstance` between publish and `.ready`; spawn failure → `.error`, not `.ready`; resume from a warm-cached conversationId publishes only once (concern #3 regression guard from Phase 2.10).
- Deeplink-card URL extraction from message bodies — text-before-URL, text-after-URL, multiple URLs in one message, URL not at boundary, malformed URL.

**Integration tests** (require Docker via `./dev/up`, plus a fixture template in the local backend):

- Tap Chat on the agent contact view → a new conversation exists in the local DB with two members (local + agent) → the agent member's profile snapshot carries `templateId == fixture.id`.
- Profile snapshot recency: simulate two snapshots arriving out of order — newer-but-late wins.
- Existing-1:1 short-circuit: spawn once, then tap Chat again — second tap navigates to the existing conversation, no second spawn.

**Manual / QA test plan** (`qa/tests/<NN>-agent-templates-phase-1.md`):

- Universal Link from outside Convos: paste the URL into Notes, tap, verify routing into the app (installed) vs. browser (uninstalled).
- Scan the QR on `agents-dev.convos.org/<id>` from inside Convos's QR scanner, verify routing into the agent contact view.
- Tap a verified agent's avatar in an existing group conversation containing one Convos-issued legacy assistant (no `templateId`) — verify legacy `ConversationMemberView` opens. Then add a user-built agent to the same conversation, tap its avatar — verify the new agent contact view opens. Both should coexist.
- Share a template via the share sheet to iMessage; tap the message preview; verify routing.
- Hand the iOS build to the `convos-assistants/website` team for a swim through the share-from-web flow (Share Contact pill on `agents-dev.convos.org/<id>` → iMessage → tap → app or web fallback).

**Architecture review:** Hand the data-layer + DeepLinkHandler design to `swift-architect` for a final review before Phase 1.1 lands.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Backend Phase-1 instantiation endpoint slips | High | Phase 1.1 / 1.2 / 1.3 / 1.4 are independent of the endpoint and stack against the eventual contract. Feature-flag the Chat button in Phase 1.5 so we can ship TestFlight without the endpoint live. |
| `convos-assistants/website` doesn't publish AASA in time | Medium | The DeepLinkHandler change (Phase 1.4) covers the `convos://template/<id>` custom-scheme form, which works without AASA (it relies on the iOS `URL_SCHEME` entitlement we already have). Universal Link support is the upgrade — without it, sharing-via-iMessage falls through to the install page even for users who have Convos installed. Annoying but not blocking. |
| Backend `templateId` profile-snapshot codec field slips | Medium | Phase 1.3 gates the new card on `contact?.templateId != nil`; until the field flows, all verified agents continue to route through legacy `ConversationMemberView`. No regression. |
| Deeplink-card renderer collides with other URL-detection in the message renderer (link-preview cards, mention rendering, etc.) | Medium | Run the template-URL detection BEFORE the generic URL detector and short-circuit on match. Add explicit tests for "URL is at start / end / middle of body" and "multiple URLs, only one is a template." |
| Hashed-slug pretty URLs (`slug.hash`) require a `hashedSlug` field or client-side hash | Low | Phase 1 sticks to UUID URLs. The pretty form is a follow-up; the resolver accepts both forms, so no backwards compatibility break when we add the pretty URL later. |
| Two QR scans / two Universal Link taps in quick succession trigger two spawn calls | Medium | The Chat button (and the Universal Link / deeplink-card tap that routes to it) sets `isStarting` while the `NewConversationViewModel` is being constructed — same pattern Phase 2.10 establishes. Add an integration test for double-tap protection. |
| Verified-agent contacts that get auto-added today via the contacts PRD's auto-add hook end up with the new agent card opening when tapped from the contacts list — bleeding Phase 2 behavior into Phase 1 | Medium | Phase 1 ONLY reroutes the in-chat avatar-tap sites; the contacts-list row tap path is untouched. The contacts list filter `!$0.isVerifiedAgent` continues to hide template-backed contacts from the browse list. |

## Open Questions

- [ ] **Deeplink-card / Universal Link routing: contact view first or skip-to-spawn?** Phase 1 default is "open the agent contact view, user taps Chat to spawn." A one-tap "spawn on URL tap" alternative is faster but harder to undo. Designer + product call before Phase 1.4 / 1.6 land.
- [ ] **Production host for the install page.** Today's dev URL is `agents-dev.convos.org`. The prod URL is `convos.org/...`? `agents.convos.org`? Both? Required before the prod entitlement (Phase 1.4) and the prod Share URL (Phase 1.3) land.
- [ ] **Backend instantiation endpoint shape.** Extend `agents/join` with `templateId`, or new `agent-templates/:id/instances`? iOS abstracts both via `SessionManager.spawnAgentInstance(...)`, but the wire call needs to match the eventual contract.
- [ ] **What does `convos://template/<id>` do on a device without the app?** Custom URL schemes have no install-page fallback — the URL simply fails to open. Sharing via iMessage *should* use the HTTPS Universal Link form. Confirm the iOS share sheet always gets the HTTPS form, not the custom scheme.
- [ ] **Deferred-deeplink on first install.** A non-Convos user taps the Universal Link, lands on `agents-dev.convos.org/<id>`, installs Convos. On first launch, should the installer land directly in a new conversation with the agent (deferred deeplink), or just open Convos? Lean: deferred deeplink. Mechanics need a product call — Apple's deferred-deeplink story has changed over the years.
- [ ] **Hashed-slug pretty URLs.** Phase 1 ships with UUID URLs. The pretty `<slug>.<hash>` form is a follow-up — needs either a precomputed `hashedSlug` field on the backend serializer or a client-side mirror of the `slug-hash` algorithm.
- [ ] **Existing-1:1 short-circuit, multi-1:1 tiebreak.** If the user has two existing 1:1s with instances of the same template (possible if they spawned twice), tapping Chat picks "most-recently-active." Confirm before Phase 1.6 ships — alternatives: most-recently-created, or a disambiguation sheet.
- [ ] **Website UX bugs adjacent to this work** (not blocking iOS but worth flagging to the convos-assistants/website team): (a) the "created" stage of `/create` lacks a Share Contact pill; (b) `/create` doesn't `router.replace` to `/<templateId>` after generation completes, so the URL bar stays at `/` and refresh drops the user back to the empty create form.

## References

- [Agent Templates 1-pager](./agent-templates.md) — surfaces, personas, FAQ, UAQ.
- [Agent Templates wireframes](./agent-template-mocks/) — surfaces 1 (contact view), 2 (deeplink card in chat), 3 (web preview).
- [Contacts PRD](./contact-list-prd.md) — the contact-card mode pattern, Phase 2.8 (unified contact card), Phase 2.10 (`NewConversationViewModel` + `ConversationStateMachine` extension pattern).
- [ADR-005: Member Profile System](../adr/005-member-profile-system.md) — the per-conversation profile data model that carries `agentVerification` and (soon) `templateId`.
- [ADR-011: Single Inbox Identity Model](../adr/011-single-inbox-identity-model.md) — the identity model that lets us key contacts on `inboxId`.
- `Convos/DeepLinking/DeepLinkHandler.swift` — the file Phase 1.4 extends.
- `Convos/Config/Info.Dev.plist` and `Convos.Dev.entitlements` — Universal Link entitlements.
- `Convos/Contacts/ContactCardView.swift` and `ContactCardMode.swift` — the existing contact-card surface Phase 1.3 extends.
- `Convos/Conversation Detail/ConversationViewModel.swift` `requestAssistantJoin()` (lines 2221-2272) — the existing legacy hardcoded-assistant-join flow that the Phase 1.5 spawn-and-join path runs alongside.
- `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift` `requestAgentJoin(slug:instructions:forceErrorCode:)` (line 553) — the existing `agents/join` client method that Phase 1.5 either extends (option 1) or sits alongside (option 2).
- `convos-assistants/website/src/app/[slug]/page.tsx` — the web preview page Phase 1.4's AASA wires up.
- `convos-assistants/website/src/lib/deep-link.ts` — the deeplink encoder whose header comment says "convos-ios does not yet have a matching `DeepLinkHandler` destination."
- `convos-backend` PR #199 (`feat/agent-templates-crud`) — the CRUD endpoints Phase 1.1's API client targets.
- Convos backend OpenAPI YAML (in the project context) — `GET /agent-templates/:idOrHashedSlug` shape.
