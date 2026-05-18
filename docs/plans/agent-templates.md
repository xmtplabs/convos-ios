# 1-Pager: Agent Templates

> **Status**: Draft
> **Author**: Cameron Voell
> **Created**: 2026-05-18
> **Updated**: 2026-05-18
> **Companion PRD**: TODO — `docs/plans/agent-templates-prd.md` (to be drafted)
> **Backend**: PR #199 (`feat/agent-templates-crud`) landed the template CRUD on `otr-dev`; the instantiation endpoint is in progress
> **Related**: [contact-list.md](./contact-list.md), [contact-list-prd.md](./contact-list-prd.md), [agent-join-endpoint.md](./agent-join-endpoint.md)

## 1. Tweet Headline

👉 "Convos treats AI agents like contacts. Build a custom one, share a link, and your friends can chat with their own copy in one tap."

## 2. Show, Don't Tell

Wireframes for the four MVP surfaces. Built as standalone SVGs so they live in-repo and render in any markdown viewer.

| | |
|:---:|:---:|
| <img src="agent-template-mocks/01-agent-contact-page.svg" width="260" alt="Agent template contact page"/><br/>**1. Agent template contact page** — hero surface. Avatar, name, description, creator attribution, agent badge, **Chat** (primary CTA — opens your existing 1:1 with this agent if one exists, otherwise spawns a fresh instance in a new convo), **Share Contact** (copies `convos://template/<id>`), About section (category, creator, version), Skills chips, **Convos with you** list, destructive **Delete from contacts** footer. No Edit, no Duplicate. | <img src="agent-template-mocks/02-contacts-list-with-agents.svg" width="260" alt="Contacts list with humans and agents inline"/><br/>**2. Contacts list with humans + agents** — extends the contacts-PRD browse screen. Adds the **All / Humans / Agents** filter chip row, mixes agent rows inline with human rows alphabetically, and tags each agent row with an **AGENT** badge so the row reads as "person, person, agent, person." Today's `!$0.isVerifiedAgent` filter goes away. |
| <img src="agent-template-mocks/03-contacts-picker-with-agents.svg" width="260" alt="Contacts picker with humans and agents both selectable"/><br/>**3. Contacts picker with agents** — multi-select picker for new-conversation creation. Humans and agents both selectable; the "To" pill renders selections inline (e.g., "Gerald" + "Tifoso"). Each checked agent spawns a fresh instance into the conversation right after it's created. The same filter chip row reappears for scoping. CTA: **Start conversation (2)**. | <img src="agent-template-mocks/04-web-preview.svg" width="260" alt="convos.org/template/&lt;id&gt; web preview"/><br/>**4. Web preview at `convos.org/template/<id>`** — install-prompt page modeled on today's `agents-dev.convos.org` "Mise" surface. Browser frame, Convos header, "Chat to customize / Install Convos, then scan the QR" banner with App Store + Google Play badges, big QR encoding the `convos://template/<id>` Universal Link, agent name + description + skill chips. On a device with the app installed, tapping the Universal Link deep-links straight into surface 1. |

These are wireframes, not final visuals — they fix the surfaces and copy but leave room for a real designer pass before ship. Two design notes worth calling out from the sketching pass:

- **The contact page and the contacts-list row treatment are the same component, two modes.** Same shape as the contacts-PRD's `ContactCardMode.standalone` / `.scopedToConversation` split — the difference between the standalone agent page (surface 1) and the agent-row contact card opened from a member tap inside a conversation is a mode parameter, not a different view. The agent badge, About section, Skills chips, and Convos-with-you list render in both modes; the scoped mode appends group-actions ("Remove from this convo," "Block and leave") below the standard sections.
- **The contacts list, the picker, and today's contacts-PRD picker are one component in three modes.** Adding agents to the picker is a row-type extension, not a new screen. The filter chip row is shared between surface 2 and surface 3 so the user's mental model is consistent across browse-and-pick.

Open visual questions still on the table: default state of the filter chip (All / Humans / last-used), placement of the AGENT badge (inline as drawn vs. section divider between humans and agents), whether the picker should hide already-in-convo agents the same way `ContactsPickerMode.addToConversation` hides already-in-chat humans, and whether the web preview's "Open in Convos" deep link should route to the contact page (as drawn) or jump straight into "Chat" (skip the contact page).

- 🍿 Loom demo link — N/A
- 🎨 Figma file link — N/A (designer to produce alongside the contacts-list filter chip work)

## 3. How It Works

> ⚠️ **Backend API dependency — loud callout.** Two of the six behaviors below depend on backend endpoints that are **not yet shipped**, and both are in-scope for V1 — this 1-pager is being written ahead of the API contracts so iOS work can stack against the agreed shape rather than wait.
>
> - **Instantiate-into-a-new-conversation** (item 4 below — the **Chat** button) needs the in-progress endpoint that takes a `templateId` plus a fresh conversation invite slug and joins a configured instance into it. Likely shape: extend `POST /v2/agents/join` to accept an optional `templateId`, or add a sibling `POST /v2/agent-templates/:id/instances`. Backend lead is locking the contract.
> - **Instantiate-into-an-existing-conversation** (item 5 below — the picker integration, **and** the chat plus-menu "Add from Contacts" entry built in the contacts PRD) needs a second endpoint that takes a `templateId` plus an existing `conversationId` and joins a fresh instance into the existing conversation. This is the new one — `agents/join` today is conversation-scoped only via an invite slug, not by id. **This endpoint does not exist yet and is the single largest external dependency for V1.**
>
> The iOS work in both cases stubs against the agreed contract behind a feature flag until the backend lands; nothing about this 1-pager's surfaces is conditional on the endpoints existing first.

The six MVP behaviors:

1. **Agent template contact page.** A new contact-card variant rendered when the contact is backed by an `AgentTemplate` (rather than a human inbox). Surfaces the fields in §2, plus the "Convos with you" shared-conversations list. Reuses the `ContactCardMode.standalone` / `.scopedToConversation` split from the contacts PRD so a member-tap inside a conversation routes to the same page with the conversation-specific actions appended.
2. **Templates appear in the main contacts list.** The existing `ContactsView` browse screen stops filtering verified agents out of the human contacts list (the current `!$0.isVerifiedAgent` rule in `ContactsViewModel.rebuildSections`) and instead renders agents inline with humans, alphabetical, with a small **agent badge** on the row. A new top-of-screen filter chip lets the user scope the list to **All** / **Humans** / **Agents**.
3. **Share generates a deep link + web preview.** Tapping **Share Contact** copies `convos://template/<id>` (prod) or `convos-dev://template/<id>` (dev) to the clipboard. The matching `https://convos.org/template/<id>` (or `https://agents-dev.convos.org/template/<id>`) renders the install-prompt web preview described in §2. Tapping either on a device with Convos installed routes to the agent's contact page; tapping the chat CTA there spawns a new instance of this template into a fresh conversation.
4. **Chat button — existing-1:1 short-circuit, then instantiate-and-join.** Tapping **Chat** on the contact page first checks whether the local user already has a **1:1 conversation** (just the user and one instance of this template, no other members) with this template. If yes, the button navigates straight into that existing conversation — no new instance is spawned, no backend call. If no, the button calls the (in-progress) instantiation endpoint with the template id and a freshly-created conversation invite slug; the backend claims an agent-pool instance, configures it with the template's prompt / name / avatar / tools / connections, and routes it to the conversation. We treat `.ready` as a strong guarantee that the conversation exists AND the agent has joined, mirroring Phase 2.10 of the contacts PRD. The existing-1:1 lookup is a local query against the contact's **Convos with you** list filtered to "size == 2, the other member is an instance of this template" — same indexed point read as the shared-conversations query the contacts PRD's stretch surface uses.
5. **Contact picker — pick a template to add an instance.** The contacts picker accepts template rows alongside human rows in both `ContactsPickerMode.newConversation` (compose flow) and `ContactsPickerMode.addToConversation(conversationId:)` (the chat plus-menu "Add from Contacts" entry built in the contacts PRD). For `.newConversation`, the conversation is created first, then one fresh instance per checked template is spawned and joins. For `.addToConversation`, each checked template spawns a fresh instance that joins the existing conversation directly via the new backend endpoint flagged in the callout above. Templates carry the same agent badge in the picker as in the browse list.
6. **Passive auto-add of someone else's agent.** When the local user is added to a conversation that already contains an instance of a template owned by someone else, the app reads the `templateId` from the agent's per-conversation profile snapshot (a new field the agent publishes alongside its existing `agentVerification`), fetches the template via `GET /api/v2/agent-templates/<id>`, and **adds the template to the local contacts list** as a read-only entry. From then on, the user can instantiate fresh copies of that template into their own conversations exactly as if they had built it themselves.

Adjacent: the **Builder** feature (separate workstream) is where users will create and edit templates — including avatar upload, prompt editor, tools / connections selection, and publish controls. This 1-pager intentionally leaves Build / Edit / Publish out of scope; we ship the contact / share / discovery / instantiation half first so the builder has a destination to drop templates into.

## 4. Who Cares

- **The recipe-sharer**: Cameron builds a "Pro Cycling Coach" agent and wants to share it with three friends on a group ride. He hits Share Contact, drops the `convos://template/<id>` link in their group chat, and each friend taps it once to get their own private 1:1 with a fresh instance of the agent.
- **The preset-picker**: Maya is new to Convos. She doesn't want to build an agent; she just wants to talk to one that's useful. She opens her contacts, taps the **Agents** filter, browses the featured templates that ship with the app, picks "Mise" (a what-to-cook coach), hits Chat, and is in a new conversation 1 second later.
- **The cross-conversation discoverer**: Jarod is in a group with a friend who's already chatting with a custom agent ("Tifoso"). The agent is helpful, and the next day Jarod realizes he wants his own instance for a different conversation. The template was passively added to his contacts the moment he joined the group, so it's already there — he picks it from the contacts picker when creating his new chat.
- **The owner with reach**: Alice's "Trip Planner" template ends up in 40 conversations across her friend network because it's good. Every user who joined one of those conversations got the template auto-added to their contacts (passively), so its reach compounds without Alice having to do anything beyond publishing it once.
- **The privacy-conscious user**: Bob wants to use an agent in a 1:1 without leaking the conversation to anyone else. He picks the agent from his contacts, hits Chat — the new conversation is created with just him and the agent instance, no other members, no broadcast.

## 5. What It Isn't

- **This is not the builder / editor**. There is no Edit button, no Duplicate button, no avatar upload, no prompt editor, and no publish flow on the contact page in V1. Those all live in the Builder workstream (adjacent, mentioned in §3). The owner of a template still edits it via the existing CRUD endpoints (`PATCH /api/v2/agent-templates/:id` and `POST /api/v2/agent-templates/:id/publish`), but the iOS surfaces for that are a separate scope.
- **This is not version-tracking on running instances**. Once an instance has been spawned and joined a conversation, it stays pinned to the template version it was instantiated against — forever. Publishing a new version of the template does not hot-swap any running instance. This is a deliberate simplification; "update available" affordances are a possible follow-up.
- **This is not a marketplace or global directory**. Discovery surfaces are: (a) templates you own (your account), (b) the featured / public list the backend returns, (c) anything passively added because you joined a conversation containing it. There is no search, no ranking, no recommendations, no reviews.
- **This is not multi-instance-per-conversation prevention**. In V1, a user could in principle spawn two instances of the same template into the same conversation. We'd prefer this not be possible — but it's a nice-to-have UX guard, not a correctness bug. Tracked as a UAQ.
- **This is not version-fork-with-attribution**. The backend schema has `forkedFromId` and the CRUD supports it, but no iOS surface for forking exists in this scope.
- **This is not a quota / payments surface**. Whoever spawns an instance pays for it (whatever "pays" means once the agent-pool side defines it). Owner-vs-instantiator cost allocation is an open product question, deliberately deferred.

## 6. FAQ + UAQ

### FAQ (known questions)

1. **Q**: What `convos://` namespace does the share link use? Doesn't `convos://assistant/<id>` already exist?
   **A**: It doesn't. I grepped the iOS deep-link handler (`Convos/DeepLinking/DeepLinkHandler.swift`) and the iOS `Info.*.plist`s; the only `convos://` destinations in use today are `convos://join/{code}`, `convos://invite/{code}` (legacy), and `convos://connections/grant?service=...&conversationId=...`. The `assistant`, `agent`, and `template` host slots are unused. We're claiming **`convos://template/<id>`** (and `convos-{env}://template/<id>` for non-prod, matching the existing env-prefixed scheme convention). The matching web URL is `https://convos.org/template/<id>` (`https://agents-dev.convos.org/template/<id>` in dev, mirroring the existing `agents-dev.convos.org` host that today serves the "Mise" install-prompt page).

2. **Q**: How does the web preview at `convos.org/template/<id>` know what to render?
   **A**: It calls the public detail endpoint `GET /api/v2/agent-templates/:idOrHashedSlug` with the template UUID, renders `agentName`, `description`, `emoji`/`avatarUrl`, and (optionally) a category label. The page also embeds a QR encoding the `convos://template/<id>` deep link and renders App Store + Google Play install banners. This matches the existing pattern at `agents-dev.convos.org` (the "Mise" page screenshot in the design references), just keyed by template UUID instead of by hardcoded agent.

3. **Q**: How does the app know which template a verified agent in a conversation came from?
   **A**: The agent publishes a new optional `templateId` field on its per-conversation profile snapshot (the same payload that today carries `agentVerification`). The local client reads it off the snapshot via the existing `ContactsProfileSyncWriter` path, fetches the template via `GET /api/v2/agent-templates/<id>` if not cached, and stores it on the contact row. This is the "passive auto-add" mechanism in §3 (item 6). The backend lead and I agreed this is the V1 binding mechanism; a server-side `AgentInstance` table that maps `inboxId → templateId` is the cleaner long-term shape but is not blocking V1.

4. **Q**: What's the relationship to the existing "Assistants" entry in the Convos top-left menu?
   **A**: Open question — see UAQ. Three options on the table: replace it with "Templates," rename it to "Agents" and broaden the scope, or keep "Assistants" pointing at the legacy hardcoded `agents/join` flow and add a separate path. The favored option is to let the **contacts list itself** be the templates browse surface (via the new Agents filter chip), and let the existing menu entry either go away or redirect to that filtered view.

5. **Q**: If I get passively added to a template because I joined a conversation with someone else's agent, can I delete it from my contacts later?
   **A**: Yes, but with a caveat. Deleting the template from your contacts removes the local row, but if any conversation you're still in contains an instance of that template, the next profile-snapshot sync will re-add it. To really remove it, you'd need to leave or block the conversations that contain it. This is the same eventual-consistency story as the contacts PRD's most-recent-wins profile-sync rule.

6. **Q**: Drafts — can I share a draft via the share link?
   **A**: Anyone you share the link with hits the same `GET /api/v2/agent-templates/:id` endpoint we use everywhere; drafts return 404 to non-owners (and to anonymous web visitors). So sharing a draft's link is a no-op for everyone except you. We don't add client-side guardrails against sharing a draft link, but the recipient experience falls through cleanly.

7. **Q**: What does the Chat button do — does it always spawn a new instance, or does it reuse an existing one?
   **A**: It does an **existing-1:1 short-circuit first**, then falls through to spawn-a-new-instance. Concretely: if the local user already has a 1:1 conversation (exactly two members — the user and one instance of this template) with this agent, tapping Chat navigates to that existing conversation. Otherwise, Chat creates a new conversation and calls the instantiation endpoint to join a freshly-spawned instance into it. This means a user with one existing 1:1 with "Tifoso" will keep returning to the same chat (and the same conversation memory) each time they tap Chat from the contact page — that's the intended behavior, and it's what makes the contact page feel like a contact rather than a "new chat" button. To start a *fresh* conversation with a new instance of the same template, the user goes through the contacts picker and checks the agent there, which always spawns a new instance into the conversation it creates. Group conversations are not considered for the short-circuit even if an instance of this template is in them — only 1:1s qualify, because that's the unambiguous "this person and this agent" surface.

8. **Q**: Does the contact picker badge agents and humans differently in selection state?
   **A**: Yes. Selected templates get the same selected pill treatment as selected humans (avatar bubble in the "To" header), and the row checkmark behaves identically. The agent badge persists on the row even when selected, so the user can tell at a glance which selections will spawn new instances on confirm.

### UAQ (unanswered questions)

- [ ] **Shared agent context across conversations — loud callout.** Today, every running agent is **one instance per one conversation**, full stop. Two instances of the same template in two different conversations are two independent agents that happen to share a recipe: no shared memory, no shared system-prompt state, no shared tool-use history. Open product question: should conversation participants be able to spin out a sub-conversation (for example, a 1:1 sidebar with the agent that branches off a group thread) with the **same** running instance — preserving the agent's context from the parent conversation? If yes, the data model gains an "instance group" or "instance lineage" concept that's strictly larger than a single conversation, the join endpoint needs to support "join an existing instance" rather than always "spawn a fresh one," and the contact card's **Convos with you** list needs to distinguish "different instances of the same template" from "same instance, branched conversations." Not blocking V1, but worth a product call before we lock the instance-per-conversation invariant into anything user-visible (the contact card copy, the share-link semantics, the picker's "spawns a fresh instance" helper text). My recommendation: lock V1 on instance-per-conversation, but write the data model so that lineage / instance-grouping is additive rather than a breaking change.
- [ ] **What's the exact host for the `convos://` scheme — `template`, `agent`, or `agent-template`?** I'm proposing `template` (shortest, matches `convos.org/template/<id>`), but worth a sanity check against the Builder team's naming plans before we burn the namespace.
- [ ] **Chat-button short-circuit when multiple 1:1s exist with instances of the same template.** The §3 item 4 short-circuit is unambiguous for the 0-or-1 case. If the user previously instantiated the same template twice into separate 1:1s (today this is possible — they used the picker, picked the same template twice across two compose flows), tapping Chat has to pick *one*. Most-recently-active wins is the obvious heuristic. Worth confirming this is the right tie-break before we ship — alternatives: most-recently-created, or a disambiguation sheet ("You have 2 conversations with Tifoso — pick one"). Recommendation: most-recently-active, no sheet, and visually surface the alternates in the **Convos with you** list on the contact page (where they already appear).
- [ ] **Default state of the contacts filter chip.** "All" / "Humans" / "Agents" — does it default to All, default to Humans (current behavior), or remember the user's last selection? Designer call.
- [ ] **Agent badge placement.** Inline on each row (like a verified checkmark) vs. a section divider between humans and agents within the same list. Designer pass should resolve.
- [ ] **Stickiness of passively-added templates.** If the conversation that triggered the passive auto-add is deleted / I'm kicked from it, does the template stay in my contacts (because I might still want it), or does it go away? Lean: stays, but flagged for review.
- [ ] **Multi-instance-per-conversation enforcement** (nice-to-have). Should the picker prevent checking the same template twice for one conversation? Should the chat plus-menu's "Add instance" hide a template that's already in the conversation? Easier to add later than to take away.
- [ ] **Quota / cost / authorization for non-owner instantiation.** If user A's template is instantiated 10,000 times by users B–Z, who pays for the agent-pool credits? Tracked in the PRD's open questions; out of scope for this 1-pager.
- [ ] **Sharing semantics for unlisted templates.** A user can `PATCH` a template to `status=unlisted`, which keeps the canonical URL resolvable but hides it from the public list. The share link still works for anyone the owner sends it to. Is that the intended product behavior, or do we want a tighter "private link" mode?
- [ ] **Web-preview Universal Link routing.** Should `https://convos.org/template/<id>` tapped on a device with the app installed deep-link straight into the **Chat** action (spawn instance + open conversation), or land on the **Contact Page** first so the user confirms? Lean: land on the contact page, but verify with designer.
- [ ] **Does today's "Assistants" Convos-menu entry get retired, rebranded, or kept alongside the new contacts surface?** See FAQ #4 — needs a product call before Phase 1 lands.

## 7. Counterintuitive Angle

👉 **An AI agent is a contact, not a tool.** Other AI surfaces treat agents as buttons on a toolbar, slash commands, or a separate "AI Mode" tab. In Convos, an agent lives in the same row as your friends, gets picked from the same picker, has the same chat button, and accumulates the same shared-conversations history. The interesting consequence: sharing an agent is the same gesture as sharing a contact, building one is the same effort as adding a friend, and a conversation with an agent is shaped like a conversation with a person — same UI, same affordances, same memory model.

The spiky version: if your AI feature has a dedicated UI surface, your AI feature is a chatbot in a costume. Ours is just another person in the room.

## 8. Call to Action

- [x] ✅ **Build**
- [ ] 🧪 Test
- [ ] 🚫 Drop
- [ ] 💬 Debate

**Next steps if approved:**

- Designer pass on the **Agent Template Contact Page**, the **contacts list filter chip + agent badge**, and the **`convos.org/template/<id>` web preview** (modeled on the existing `agents-dev.convos.org` Mise page).
- Backend lead confirms the in-progress instantiation endpoint shape and the matching "add instance to existing conversation" endpoint shape.
- Backend lead confirms the agent-side `templateId` profile-snapshot field is on the codec roadmap (V1 binding mechanism per FAQ #3).
- Draft the companion PRD at `docs/plans/agent-templates-prd.md` with the phased Graphite stack, mirroring the structure of `contact-list-prd.md`. First two PRs in the stack: (1) data layer + API client + read-only contact page + passive auto-add via profile snapshot, (2) contacts-list integration with the filter chip + agent badge + picker integration.
- Lock the four swagger-vs-code discrepancies flagged in the PR #199 audit (auth requirement on read endpoints, hashed-slug separator, delete-after-publish rule, slug-uniqueness rule) before Phase 1 lands.
- Resolve the "Assistants" menu-entry question (FAQ #4) with product before the contacts-list integration ships, so we don't have two competing entry points.
