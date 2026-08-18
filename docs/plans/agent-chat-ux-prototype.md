# Agent chat UX prototype

## Scope and product thesis

This prototype makes the agent lane feel like a private, controllable workspace inside a group conversation. It extends PR #1325's native resizable conversation sheet and the current Convos profile/paywall language; it does not replace navigation, the group transcript, or the existing subscription purchase flow.

The three features form one system:

1. The composer identifies who the user is talking to and makes switching agents immediate.
2. Ghost Mode creates an explicitly private lane and lets the user release only one chosen message at a time.
3. Each agent profile exposes the model powering that agent, its credit cost, and any plan requirement before activation.
4. External agents remain in their own apps; Convos provides a deliberate, time-bounded context handoff and an optional scoped return connector.
5. Links shared in chat become editable Home objects with an agent entry point attached to each object.
6. An agent the user owns can span two convos as one shared operating layer: memory, abilities, connections, and skills.

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
- The prototype catalog is Codex, Claude Code, Hermes, OpenClaw, and GrokBot. Adding one creates a selectable handoff lane, not a duplicate chat or a provider-authenticated runtime inside Convos.
- The handoff lane defaults to **Share last 24 hours + group desktop info**. The user can choose one hour, 24 hours, seven days, or all available group history and can independently exclude the group desktop.
- **Copy context** puts one paste-ready block on the iOS clipboard. The block names the time window and included surfaces. Ghost Mode, private agent chats, member DMs, other convos, membership lists, and unsaved files are always excluded.
- **Open [agent]** opens a fixed official web destination. The context is never placed in a URL, query string, or automatic provider request; the user pastes it into the external agent themselves.
- The lane has no transcript, draft, or composer. Its only primary loop is choose scope → copy → open and paste.
- An optional **Copy key** demonstrates return access. Production must copy a one-time pairing code—not a bearer secret—which the external agent’s secure Convos connector exchanges for a revocable, least-privilege credential. Return access can read visible Home object summaries and create link/widget update proposals; it cannot read group messages, Ghost content, private DMs, or publish changes without the existing approval flow.
- The Firebase build copies clearly labeled demo context and a non-functional demo key. It does not export real group content or grant write access.

## 5. Links as agent-editable Home objects — WebView-owned follow-up

- Home is a WebView and remains fully unobstructed in the iOS prototype. The removed native shelf must not be reintroduced above it.
- Link cards and their agent affordances should be rendered by the Home web experience itself. The WebView can use the existing navigation bridge to request a native Agent sheet when that contract is implemented.
- A future card keeps the source URL, title, site, preview image when available, sender, and source message ID. Its edit action should name the object and require a preview before publishing.
- Production edits must target stable Home object IDs and use optimistic concurrency. The source chat message remains immutable; the Home projection can be rearranged, annotated, hidden, or replaced without rewriting message history.

## 6. Share an agent across convos

- **Connect an agent from another convo** appears immediately above **Add an external agent**. It lists only agents the current user owns in other convos.
- Connecting does not clone the agent or merge transcripts. It makes the same agent operating layer available in both convos: existing and future durable memory, every ability, every approved connection, and every installed skill.
- The warning states that people in either convo can influence future saved memory, and the agent's complete operating layer becomes usable in both places.
- Raw messages/full transcripts, Ghost Mode, private agent chats, member DMs, membership lists, and unsaved files remain in their original convo. They do not enter the shared memory namespace.
- Only the agent owner can create or disconnect the link, and the user must be an active member of both convos. Both convos visibly identify the shared agent and the other linked convo.
- The linked lane exposes **Shared memory** settings that inventory everything shared and let the owner disconnect this convo without deleting the agent or its original memory.

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
2. Choose GrokBot, review the context-handoff explanation, and tap **Add GrokBot**.
3. In the selected GrokBot lane, change the context window and toggle **Include group desktop info**. Confirm the scope sentence updates.
4. Tap **Copy context**, open GrokBot from the fixed bottom action, and paste the clearly labeled prototype block.
5. Return to Convos, tap **Copy key**, and confirm the UI states that it is a non-functional demo key. Review the proposed Home-only return scopes.
6. Collapse the conversation sheet and confirm the Home WebView remains unobstructed and fully interactive.

### Cross-convo shared agent

1. Open the selector and choose **Connect an agent from another convo** directly above the external-agent action.
2. Choose one owned agent and review its origin convo, saved-memory summary, abilities, connections, and installed skills.
3. Read the warning and complete **Share memory across convos**.
4. Confirm the shared agent appears as the selected lane and names the other convo.
5. Open **Shared memory** settings, confirm the full operating layer is inventoried, and verify the disconnect control explains that the original agent is preserved.

## Explicit prototype assumptions

- Model names, providers, credit multipliers, and plan mapping are illustrative until the runtime returns a canonical catalog.
- Existing Plus is the only purchasable paid entitlement, so all non-default prototype models map to Plus.
- Agent switching and Ghost Mode are interactive local prototypes in non-production builds. They demonstrate lane behavior and selective sharing but do not claim a deployed multi-agent or privacy-isolated server runtime.
- External context handoffs, return keys, and cross-convo agent links are local non-production demonstrations. The external lane copies an explicitly labeled sample block and demo key; it does not export real messages, mint credentials, invoke an agent, or write Home data. Home-edit controls remain owned by the WebView implementation.
- Ghost sharing completes inside local prototype lanes. If a requested row resolves to a real agent lane before the export contract exists, the UI explicitly says the preview was not sent rather than reporting a false success.
- This branch includes a Debug-only, account-free Space Abilities profile host for design review. Set `CONVOS_AGENT_MODEL_PROTOTYPE=1`; optional `CONVOS_AGENT_MODEL_PROTOTYPE_STATE` values are `picker`, `upgrade`, and `paywall`. The production root view is unchanged when that flag is absent.
