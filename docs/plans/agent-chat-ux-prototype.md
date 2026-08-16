# Agent chat UX prototype

## Scope and product thesis

This prototype makes the agent lane feel like a private, controllable workspace inside a group conversation. It extends PR #1325's native resizable conversation sheet and the current Convos profile/paywall language; it does not replace navigation, the group transcript, or the existing subscription purchase flow.

The three features form one system:

1. The composer identifies who the user is talking to and makes switching agents immediate.
2. Ghost Mode creates an explicitly private lane and lets the user release only one chosen message at a time.
3. Each agent profile exposes the model powering that agent, its credit cost, and any plan requirement before activation.
4. External agents can enter the same lane model through a deliberate pairing and permission flow.
5. Links shared in chat become editable Home objects with an agent entry point attached to each object.

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
- The prototype catalog is Codex, Claude Code, Hermes, OpenClaw, and GrokBot. The GrokBot name represents a Convos bot powered by the xAI API; it is not presented as an official standalone xAI product.
- Codex and Claude Code pair through a desktop bridge, where the user signs in with the provider and approves a workspace. Hermes pairs to its OpenAI-compatible API server with a gateway URL and revocable API server key. OpenClaw pairs as an approved device to its WebSocket gateway with a token and explicit scopes. Grok uses a server-held, scoped xAI project key.
- The mobile client never stores raw provider credentials. The production connector must return a revocable Convos connection ID and a human-readable summary of its runtime, workspace, and granted capabilities.
- Finishing the demo adds that external agent as a real selectable prototype lane. Its transcript, draft, and response state stay isolated from every other lane.
- The lane’s **Agent access** setting exposes three independent permissions: private read/write access to this convo’s Home; listening/replying in the group; and member DMs limited to context from this group. Everything starts off except the private Home collaboration permission.

## 5. Links as agent-editable Home objects

- Link previews in the group transcript are projected into a **From the chat** shelf on Home. The card keeps the source URL, title, site, preview image when available, sender, and source message ID.
- Each card has a small active-agent avatar. Tapping it opens the Agent sheet fully, selects a non-Ghost lane, and seeds a draft that names the object and requires a preview before publishing.
- **Edit Home** provides the same loop for the whole desktop. The agent first summarizes what it can see and asks what to change; it does not publish on the first tap.
- The prototype supplies three cards labeled **Demo** when a convo has no link previews so the interaction remains testable. Demo cards do not inflate the **From the chat** count, and real cards immediately replace them as links arrive.
- Production edits must target stable Home object IDs and use optimistic concurrency. The source chat message remains immutable; the Home projection can be rearranged, annotated, hidden, or replaced without rewriting message history.

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

### External agent and Home editing

1. Open the agent switcher and tap **Add an external agent** before Ghost Mode.
2. Inspect all five providers, open one connection explanation, and complete **Connect demo** without entering a secret.
3. Return to the selected external-agent lane and open **Agent access**. Confirm private Home access is on and the group/DM permissions are off.
4. Collapse the conversation sheet and see the **From the chat** link shelf on Home.
5. Tap a card’s agent avatar and confirm the Agent sheet opens fully with an object-specific draft in the selected lane.
6. Tap **Edit Home** and confirm the sheet opens with a safe preview-first editing prompt.

## Explicit prototype assumptions

- Model names, providers, credit multipliers, and plan mapping are illustrative until the runtime returns a canonical catalog.
- Existing Plus is the only purchasable paid entitlement, so all non-default prototype models map to Plus.
- Agent switching and Ghost Mode are interactive local prototypes in non-production builds. They demonstrate lane behavior and selective sharing but do not claim a deployed multi-agent or privacy-isolated server runtime.
- External connections, permission changes, and Home edits are also local non-production demonstrations. The UI says **demo** at the connection boundary and sends no provider credential, remote request, or Home mutation.
- Ghost sharing completes inside local prototype lanes. If a requested row resolves to a real agent lane before the export contract exists, the UI explicitly says the preview was not sent rather than reporting a false success.
- This branch includes a Debug-only, account-free Space Abilities profile host for design review. Set `CONVOS_AGENT_MODEL_PROTOTYPE=1`; optional `CONVOS_AGENT_MODEL_PROTOTYPE_STATE` values are `picker`, `upgrade`, and `paywall`. The production root view is unchanged when that flag is absent.
