# 37 - Agent Contact Visibility Edges

Picker/visibility edge cases of the agents-as-contacts refactor, driven through the
**in-app agent-builder** (no CLI, no invites). Runs after test 36, reusing its agent
and building a second one. See `36-agents-as-contacts.md` for the runbook + the
Firebase App Check / backend-provisioning prerequisites.

## What this guards

| Behavior | Code | Step |
|---|---|---|
| Agents are selectable in the add-to-conversation picker | `ContactsPickerViewModel.isPickable` (true for agents in every mode) | `agent_pickable_in_add_mode` |
| A member already in the chat is inline-disabled | `ContactsPickerRow` `.disabled(isAlreadyInChat)` + `toggleSelection` guard ("in chat" badge) | `already_in_chat_disabled` |
| Adding a second agent to a convo that already has one is a no-op | `AddFromContactsPickerModifier.handleConfirm` gates `requestAgentJoin` on `!hasAgent` | `hasagent_guard_blocks_second_agent` |

## Notes

- **Agent-builder, not CLI.** A second agent is built via the composer
  (`agent-composer-text-field` -> `agent-make-button`) so the picker has a
  template-backed agent contact to offer that isn't already in the first agent's
  conversation. Requires backend provisioning (templateId) like test 36.
- The add picker is reached from the first agent's contact card: `contact-detail-chat`
  -> confirm the One-agent sheet -> land in the conversation -> `add-to-conversation-button`
  -> `context-menu-add-from-contacts` -> the picker.
- The first agent (a member of that conversation) shows the "in chat" badge and is
  `.disabled`; selecting the second agent + confirming must not spawn it (hasAgent guard).

## Unit-covered (not cleanly reproducible via the builder UI)

- **Verified agent with no templateId stays hidden:** `isVisibleInContactsList` returns
  false when `agentVerification != nil && agentTemplateId == nil`. The agent-builder
  always assigns a templateId once provisioned, so this lives in the ConvosCore unit
  suite (and is briefly observable pre-provision).
- **Metadata-less name-only update keeps the sticky templateId:**
  `DBContact.replacingProfileFields` coalesces `snapshot.agentTemplateId ?? agentTemplateId`
  - covered by `ContactsRepository` / `ContactsWriter` unit tests.
