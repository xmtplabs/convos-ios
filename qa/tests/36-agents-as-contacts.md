# 36 - Agents As Contacts (happy path)

Part of the **Agents-as-Contacts** QA sequence (36 -> 37 -> 37b) that validates the
agent-contacts refactor against the **local stack**. This is the rerunnable happy
path; 37 covers non-destructive edges, 37b covers the destructive consent/block
cases.

## What this guards

| Refactor behavior | Code | Step |
|---|---|---|
| A verified, template-backed agent shows up as a contact | `Contact+BrowseVisibility.isVisibleInContactsList` (`agentVerification != nil && agentTemplateId != nil`) | `agent_appears_in_contacts` |
| Contact only appears after the local user acts | `ContactSyncCoordinator.syncContactsOnFirstMessage` (the first-message action gate) | `send_message_triggers_contact_sync` |
| The same agent (same templateId) across N conversations dedups to one contact | `ContactsRepository.canonicalContacts` + `Contact+CanonicalTemplate.dedupingAgentsByTemplate` | `dedup_shared_template` |
| App Settings badge agrees with the visible list | `AppSettingsView` contacts count + `isVisibleInContactsList` | `badge_matches_list` |
| Agent card affordances + verification | `ContactDetailView` (Agent pill, Share-agent, attestation) | `open_agent_contact_card` |
| "One agent, many convos" gate before a new agent convo | `OneAgentManyConvosInfoSheet` | `chat_shows_agent_info_sheet` / `confirm_agent_info_proceeds` |

## Key facts learned from a live run (validated against the local stack)

- A **verified** agent join lands directly in the conversation showing the agent
  **profile card** ("Fitness Trainer" + tagline) and a "Fitness Trainer, N members"
  toolbar - NOT the unverified "Agent is present" cell from test 30.
- The agent becomes a contact **only after the local user sends a message** in the
  conversation. Joining + receiving the agent's profile is not enough: the
  membership-change sync hook short-circuits because the *agent* created the
  conversation (the local user is not the creator), so the first-message hook is
  the trigger. This is the single most important step - without it the contact
  never appears.
- `convos agent serve --name X` names the **conversation** X, so the joined
  conversation is titled after the agent (e.g. "Fitness Trainer").
- The contact card's `contact-detail-debug-attestation` reads **"Attestation,
  Valid - convos"**, confirming the pinned `AGENT_DEBUG_JWKS` verified the agent.
- The "Got it" button on the One-agent sheet has **no stable accessibility id**
  (it goes through the shared `FeatureInfoSheet` + `convosButtonStyle` `AnyView`
  wrapper, which doesn't surface the identifier to idb). Match the sheet by its
  unique title "One agent, many convos" and tap the "Got it" label.
- **The Local app resets to an empty inbox on relaunch.** Run the whole 36/37/37b
  sequence in a single app session and join agents fresh via `open_invite_url` -
  do NOT relaunch mid-sequence expecting joined agents/contacts to persist.
- `publishAgentTemplate` may 404 on the local stack (no published URL); the
  publish-and-share step accepts either the share sheet or a publish-error alert.

## Runbook (provision + run)

Prereqs: Docker-backed local stack already bootstrapped (workspace `convos-mono`),
`convos` CLI + `jq` + `idb` installed.

```bash
cd <this convos-ios checkout>

# 1. Point this checkout at the running local stack (sets .env -> localhost:4000,
#    config.local.json xmtpNetwork -> dev). Confirm the stack is healthy first.
make -C dev/local-stack status            # backend/herald/worker/minio should be 200
make -C dev/local-stack ios-config IOS="$(pwd)"

# 2. Provision the verified, template-backed agents (mints/pins AGENT_DEBUG_JWKS,
#    starts `convos agent serve` for each, pushes templateId/emoji, prints invites).
qa/scripts/provision-agents-as-contacts.sh start
#   -> writes invite URLs to /tmp/convos-qa-agents.env:
#      INVITE_FITNESS_TRAINER=...  (templateId debug-fitness-trainer)
#      INVITE_TRIP_PLANNER=...     (templateId qa-shared-template)
#      INVITE_ROAD_TRIPPER=...     (templateId qa-shared-template)  <- dedup pair
#      INVITE_MYSTERY_BOT=...      (no templateId)                  <- test 37

# 3. Build + launch the Local scheme so Secrets bakes the pinned JWKS + localhost
#    backend. (Local uses ad-hoc signing; org.convos.ios-local.)
SIM=$(cat .claude/.simulator_id)
xcodebuild build -project Convos.xcodeproj -scheme "Convos (Local)" \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .derivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM=""
APP=$(find .derivedData/Build/Products -path '*Local-iphonesimulator*' -name 'Convos.app' -type d | head -1)
xcrun simctl install "$SIM" "$APP" && xcrun simctl launch "$SIM" org.convos.ios-local

# 4. Run the sequence. Substitute the captured invite URLs into the test state
#    (the runner opens them via `open_invite_url`). Run 36 -> 37 -> 37b IN ONE
#    SESSION (no relaunch):
/qa 36 37 37b
#    (or drive the structured YAMLs directly; for test 37's name-only update use:
#     qa/scripts/provision-agents-as-contacts.sh rename-fitness)

# 5. Teardown when done.
qa/scripts/provision-agents-as-contacts.sh stop
```

## Status

The happy-path core was validated live on the local stack (join -> local send ->
verified agent contact with Agent pill + "Valid - convos" attestation -> contact
card -> One-agent sheet -> proceed). The dedup, edge (37), and consent (37b) cases
are authored to match the observed UI; their underlying logic is additionally
covered by the ConvosCore unit suite (`ContactsRepositoryTests`,
`ConversationConsentReconcilerTests`, `StaleStrangerGCTests`).
