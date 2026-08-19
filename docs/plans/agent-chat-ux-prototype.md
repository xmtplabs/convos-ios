# Agent chat UX prototype

## Scope and product thesis

This prototype makes the agent lane feel like a private, controllable workspace inside a group conversation. It extends PR #1325's native resizable conversation sheet and the current Convos profile/paywall language; it does not replace navigation, the group transcript, or the existing subscription purchase flow.

The three features form one system:

1. The composer identifies who the user is talking to and makes switching agents immediate.
2. Ghost Mode creates an explicitly private lane and lets the user release only one chosen message at a time.
3. Each agent profile exposes the model powering that agent, its credit cost, and any plan requirement before activation.
4. External agents can enter the same lane model through a deliberate pairing and permission flow.
5. Links shared in chat become editable Home objects with an agent entry point attached to each object.
6. **My context** is always available to help privately, while a group receives only a user-approved bundle of specific memories, preferences, files, or connection scopes.

## 1. Agent switcher at the composer

- Put a 44-point circular agent-avatar button immediately left of the existing camera/attachment controls. The image is the active agent's real profile photo; Space Abilities uses the orange star avatar shown in the supplied references.
- A tap opens a native selection sheet. Initial prototype content: Flight Tracker, Shane's Agent, Space Abilities, and Ghost Mode. The current lane has a checkmark; Ghost Mode uses a custom ghost glyph and a short privacy subtitle.
- Selecting an agent keeps the user in the same group, replaces the agent transcript/composer context, updates the avatar and placeholder, preserves each lane's scroll position, and dismisses the sheet.
- Draft text, attachments, and response progress belong to their lane. Switching does not cancel an in-flight response; the destination row shows activity, and returning restores the draft and scroll position exactly.
- Empty, unavailable, unread, and loading states must be represented. Agent names truncate to one line, every row remains at least 44 points, and VoiceOver announces current/unread/private state.
- Tapping a different Group/Agent tab opens the conversation sheet to full height. Tapping the already-selected tab toggles the sheet between full height and collapsed, so dragging is optional.

## 2. Ghost Mode and selective sharing

- Ghost Mode is a private conversation between the signed-in user and the agent. Intro copy: **Completely off the record.** Supporting copy: **This stays between you and me. Search, think, and draft here—then choose exactly what leaves.**
- No Ghost Mode message enters the group transcript automatically. Each completed message has one explicit Share action; bulk sharing and implicit forwarding are anti-goals.
- Share opens a native action sheet titled **Send to** with agent destinations plus **Save to Desktop**. The payload is exactly the selected message, never surrounding context. The confirmation names the destination before sending.
- Privacy requirements for production: separate conversation/storage identity, no group unread or push fan-out, per-message audit event without message contents, and a server authorization check that the selected message belongs to the current user/Ghost lane.
- **Off the record** means “never added to the group or another agent unless you explicitly share one message”; it must not imply zero infrastructure retention. Before release, disclose the concrete retention window, model-provider processing, abuse/safety logging, deletion behavior, and whether message content can enter analytics. The prototype copy is not a substitute for that policy.

## 3. Agent profile model selector — first implemented slice

- Verified agent profiles show a prominent **Model** selector before conversation and contact actions. It always names the selected model, provider, and relative credit use.
- The native model sheet starts with the prototype catalog supplied in the brief: GPT-5.6 Sol, Claude Opus, Claude Fable, and DROC 4.6. GPT-5.6 Sol is included; higher-power choices are Plus-gated and disclose their relative credit multiplier before selection.
- Choosing a locked model returns to the profile with an inline explanation and an **Upgrade to use [model]** button. That button presents the existing StoreKit paywall. A successful purchase activates and persists the pending model.
- Prototype persistence is per-agent and on-device. Production requires a runtime-owned catalog (`id`, display name, provider, credit multiplier, required plan, availability) plus read/update endpoints on the agent instance. The server must remain authoritative for entitlement and credit charging.
- Until that runtime contract exists, the selector is available only in non-production app environments. A purchase callback never unlocks a model optimistically; activation waits for the subscription service to publish a confirmed entitlement.

## 4. Bring an external agent

- The agent switcher places **Add an external agent** immediately before Ghost Mode. It opens a full-screen explanation rather than asking for a credential inside the small selector.
- The prototype catalog is Codex, Claude Code, Hermes, OpenClaw, and Grok Bot. Grok Bot is a separate macOS/iOS app from Grok; its connector remains a local demonstration until the provider exposes a supported integration.
- Codex and Claude Code pair through a desktop bridge, where the user signs in with the provider and approves a workspace. Hermes pairs to its OpenAI-compatible API server with a gateway URL and revocable API server key. OpenClaw pairs as an approved device to its WebSocket gateway with a token and explicit scopes. The Grok Bot demo never asks for a key, exports context, or opens the app.
- The mobile client never stores raw provider credentials. The production connector must return a revocable Convos connection ID and a human-readable summary of its runtime, workspace, and granted capabilities.
- Finishing the demo adds that external agent as a real selectable prototype lane. Its transcript, draft, and response state stay isolated from every other lane.
- The lane’s **Agent access** setting exposes three independent permissions: private read/write access to this convo’s Home; listening/replying in the group; and member DMs limited to context from this group. Everything starts off except the private Home collaboration permission.

## 5. Links as agent-editable Home objects — WebView-owned follow-up

- Home is a WebView and remains fully unobstructed in the iOS prototype. The removed native shelf must not be reintroduced above it.
- Link cards and their agent affordances should be rendered by the Home web experience itself. The WebView can use the existing navigation bridge to request a native Agent sheet when that contract is implemented.
- A future card keeps the source URL, title, site, preview image when available, sender, and source message ID. Its edit action should name the object and require a preview before publishing.
- Production edits must target stable Home object IDs and use optimistic concurrency. The source chat message remains immutable; the Home projection can be rearranged, annotated, hidden, or replaced without rewriting message history.

## 6. My context — private by default, explicit on the way out

- Do not expose a separate “personal agent.” **My context** is a private user capability that is always available from the current Home or conversation.
- The primary entry point is **Share context** in the Group composer’s attachment menu. The agent drawer keeps **My context** immediately above **Add an external agent** for inspecting and revoking existing access; it is not the main sharing path.
- Opening **Share context** shows the complete personal-context catalog. Four details useful to this Home and recent trip-planning chat start selected: home airport, seat preference, free/busy calendar scope, and a travel-profile file. Every suggestion can be deselected and every other item can be selected.
- Before reviewing values, the user chooses one destination: a Group chat context card, the Trip planner Home widget, a Shared note on Home, or the Members list. Production replaces these demo rows with the conversation’s actual writable Home objects.
- The suggestion is viewer-private. A second screen names the exact values and one destination before presenting a destination-specific approval action. Nothing enters the group chat, Home object, agent context, or members surface before that action.
- Approved items remain reusable by the group agent until the user removes access. New items always require a new approval. A dynamic connection can return only the approved scope (for example free/busy, never private calendar details).
- After approval, the Group composer shows a local confirmation naming the destination and item count. The drawer changes to show the approved-item count. Space Abilities’ profile shows **Access to Shane’s context** and inventories only approved items; it never exposes the private catalog.
- This flow does not create another agent lane or merge transcripts. Removing access immediately removes every personal-context item from group retrieval while preserving the user’s private context.

## Acceptance paths

### Agent switching and Ghost Mode

1. Open any convo in a non-production build and tap **Agent**. The sheet opens to full height on Flight Tracker when no real agent lane is available.
2. Tap the circular avatar immediately left of the composer and see Flight Tracker, Shane's Agent, Space Abilities, and Ghost Mode.
3. Select Ghost Mode and see the private intro, private composer, and share control on each completed message.
4. Tap a message's Share control and see **Send to** destinations plus **Save to Desktop**, with copy that only the selected message leaves.
5. Start work in one prototype agent, switch lanes, and return; the original response and each lane's draft remain in place.
6. Tap the selected **Agent** tab to collapse the sheet, tap it again to open fully, then tap **Group** and confirm the new tab opens fully.

### Agent model selection

1. Open Space Abilities' profile and see GPT-5.6 Sol as the current model.
2. Open the model list, inspect model power/cost, and choose Claude Fable.
3. See the upgrade requirement inline without losing profile context.
4. Open the existing membership sheet from the upgrade button.
5. After a successful purchase, return to the profile with Claude Fable active for Space Abilities only.

### External agent

1. Open the agent switcher and tap **Add an external agent** before Ghost Mode.
2. Inspect all five providers, open one connection explanation, and complete **Connect demo** without entering a secret.
3. Return to the selected external-agent lane and open **Agent access**. Confirm private Home access is on and the group/DM permissions are off.
4. Collapse the conversation sheet and confirm the Home WebView remains unobstructed and fully interactive.

### My context

1. Open the Group composer’s attachment menu and tap **Share context**.
2. Choose Group chat, Trip planner, Shared note, or Members and confirm that the four group-relevant suggestions begin selected inside the complete eight-item catalog.
3. Change at least one selection, tap **Review**, and inspect the exact values, destination, audience effect, and approval boundary.
4. Complete the destination-specific approval and return to a visible confirmation above the Group composer. Confirm no extra agent lane is created.
5. Open the agent selector and choose **My context** to see the approved items plus **Remove access**.
6. Open Space Abilities’ profile and confirm **Access to Shane’s context** lists only those approved items.

## Explicit prototype assumptions

- Model names, providers, credit multipliers, and plan mapping are illustrative until the runtime returns a canonical catalog.
- Existing Plus is the only purchasable paid entitlement, so all non-default prototype models map to Plus.
- Agent switching and Ghost Mode are interactive local prototypes in non-production builds. They demonstrate lane behavior and selective sharing but do not claim a deployed multi-agent or privacy-isolated server runtime.
- External connections, permission changes, and personal-context grants are local non-production demonstrations. The UI says **prototype** at each sharing boundary and sends no provider credential, memory, ability invocation, or remote request. Home-edit controls are deferred to the WebView implementation.
- Ghost sharing completes inside local prototype lanes. If a requested row resolves to a real agent lane before the export contract exists, the UI explicitly says the preview was not sent rather than reporting a false success.
- This branch includes a Debug-only, account-free Space Abilities profile host for design review. Set `CONVOS_AGENT_MODEL_PROTOTYPE=1`; optional `CONVOS_AGENT_MODEL_PROTOTYPE_STATE` values are `picker`, `upgrade`, and `paywall`. The production root view is unchanged when that flag is absent.
