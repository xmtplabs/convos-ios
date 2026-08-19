---
version: 1
slug: "convos-contacts-contactdetailview-swift"
primary_target: "Convos/Contacts/ContactDetailView.swift"
related_targets: ["Convos/Contacts/AgentModelSelector.swift","Convos/Contacts/AgentModelPrototypeView.swift"]
---

# Agent chat UX prototype

## Scope and product thesis

This prototype makes the agent lane feel like a private, controllable workspace inside a group conversation. It extends PR #1325's native resizable conversation sheet and the current Convos profile/paywall language; it does not replace navigation, the group transcript, or the existing subscription purchase flow.

The three features form one system:

1. The composer identifies who the user is talking to and makes switching agents immediate.
2. Ghost Mode creates an explicitly private lane and lets the user release only one chosen message at a time.
3. Each agent profile exposes the model powering that agent, its credit cost, and any plan requirement before activation.

## 1. Agent switcher at the composer

- Put a 44-point circular agent-avatar button immediately left of the existing camera/attachment controls. The image is the active agent's real profile photo; Space Abilities uses the orange star avatar shown in the supplied references.
- A tap opens a native selection sheet. Initial prototype content: Flight Tracker, Shane's Agent, Space Abilities, and Ghost Mode. The current lane has a checkmark; Ghost Mode uses a custom ghost glyph and a short privacy subtitle.
- Selecting an agent keeps the user in the same group, replaces the agent transcript/composer context, updates the avatar and placeholder, preserves each lane's scroll position, and dismisses the sheet.
- Draft text, attachments, and response progress belong to their lane. Switching does not cancel an in-flight response; the destination row shows activity, and returning restores the draft and scroll position exactly.
- Empty, unavailable, unread, and loading states must be represented. Agent names truncate to one line, every row remains at least 44 points, and VoiceOver announces current/unread/private state.

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

## Acceptance paths

### Agent switching and Ghost Mode

1. Open any convo in a non-production build and tap **Agent**. The sheet opens to full height on Flight Tracker when no real agent lane is available.
2. Tap the circular avatar immediately left of the composer and see Flight Tracker, Shane's Agent, Space Abilities, and Ghost Mode.
3. Select Ghost Mode and see the private intro, private composer, and share control on each completed message.
4. Tap a message's Share control and see **Send to** destinations plus **Save to Desktop**, with copy that only the selected message leaves.
5. Tap the selected **Agent** tab to collapse or reopen the sheet; tapping **Group** opens that tab fully.

### Agent model selection

1. Open Space Abilities' profile and see GPT-5.6 Sol as the current model.
2. Open the model list, inspect model power/cost, and choose Claude Fable.
3. See the upgrade requirement inline without losing profile context.
4. Open the existing membership sheet from the upgrade button.
5. After a successful purchase, return to the profile with Claude Fable active for Space Abilities only.

## Explicit prototype assumptions

- Model names, providers, credit multipliers, and plan mapping are illustrative until the runtime returns a canonical catalog.
- Existing Plus is the only purchasable paid entitlement, so all non-default prototype models map to Plus.
- Agent switching and Ghost Mode are interactive local prototypes in non-production builds. They demonstrate lane behavior and selective sharing but do not claim a deployed multi-agent or privacy-isolated server runtime.
- A real agent destination reports an explicit preview-only/not-sent result until the Ghost export contract is connected; the prototype never displays false delivery success.
- This branch includes a Debug-only, account-free Space Abilities profile host for design review. Set `CONVOS_AGENT_MODEL_PROTOTYPE=1`; optional `CONVOS_AGENT_MODEL_PROTOTYPE_STATE` values are `picker`, `upgrade`, and `paywall`. The production root view is unchanged when that flag is absent.
