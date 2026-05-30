# 37 - Agent Contact Visibility Edges

Non-destructive edge/negative cases of the agents-as-contacts refactor. Runs after
test 36, reusing the contacts/conversations it established. See
`36-agents-as-contacts.md` for the runbook, provisioning, and the Firebase App
Check prerequisite (without a valid Local App Check debug token the app never
authorizes and the lists show empty).

## What this guards

| Behavior | Code | Step |
|---|---|---|
| A verified assistant with NO templateId stays hidden from the browse list | `isVisibleInContactsList` returns false when `agentVerification != nil && agentTemplateId == nil` | `legacy_agent_hidden_in_contacts` |
| A metadata-less name-only update does not drop a template-backed agent | `DBContact.replacingProfileFields` sticky coalesce (`snapshot.agentTemplateId ?? agentTemplateId`) | `name_only_update_keeps_template` |
| Agents are selectable in the add-to-conversation picker | `ContactsPickerViewModel.isPickable` (true for agents in every mode) | `agent_pickable_in_add_mode` |
| A member already in the chat is inline-disabled in the picker | `ContactsPickerRow` `.disabled(isAlreadyInChat)` + `toggleSelection` guard | `already_in_chat_disabled` |
| Adding a second agent to a convo that already has one is a no-op | `AddFromContactsPickerModifier.handleConfirm` gates `requestAgentJoin` on `!hasAgent` | `hasagent_guard_blocks_second_agent` |

## Notes

- "Mystery Bot" is served with attestation but **no** templateId (only an emoji is
  pushed), so it is verified-but-template-less. The test sends it a message (so its
  DBContact is created with `agentVerification` set, `templateId` nil) and then
  asserts it is absent from the browse list - exercising the visibility rule, not
  just the absence of a contact row.
- The name-only update is pushed from the agent shell via
  `qa/scripts/provision-agents-as-contacts.sh rename-fitness`
  (`{"type":"update-profile","name":"Fit Coach"}` with no metadata).
- The add-to-conversation entry is `add-to-conversation-button` ->
  `context-menu-add-from-contacts` -> the picker (`contacts-picker-confirm`,
  `contacts-picker-row-<inboxId>`). The already-in-chat row carries an "in chat"
  badge and is `.disabled`; tapping it must not add a `contacts-picker-selected-pills`
  pill.
- The conversation used for the picker is the agent-named "Fitness Trainer"
  conversation from test 36 (it already has an agent, for the hasAgent guard).
