# 36 - Agents As Contacts (happy path, agent-builder)

Entry point of the **Agents-as-Contacts** QA sequence (36 -> 37 -> 37b), validating the
agent-contacts refactor against the **local stack** by building a real agent entirely
in-app via the **agent-builder** (no CLI, no invite deep-links). 37 covers the
non-destructive picker edges; 37b covers the destructive consent/block cases. The
human counterpart (non-agent members as contacts) is test 40 (two simulators).

## What this guards

| Refactor behavior | Code | Step |
|---|---|---|
| A built agent gets a templateId (backend provisioning) | agent-builder + AgentTemplate provisioning | `agent_provisions_template` |
| A verified, template-backed agent shows up as a contact | `Contact+BrowseVisibility.isVisibleInContactsList` (`agentVerification != nil && agentTemplateId != nil`) | `agent_appears_in_contacts` |
| Agent card affordances + verification | `ContactDetailView` (Agent pill, Share-agent, "Valid - convos" attestation) | `open_agent_contact_card` |
| "New chat, new context" gate before a new agent convo | `OneAgentManyConvosInfoSheet` | `chat_shows_agent_info_sheet` / `confirm_agent_info_proceeds` |

## Validated live against the local stack

Built "King's Tutor" from the prompt "a friendly chess coach that teaches openings":
it provisioned a templateId, appeared in the Contacts browse list with the **"Agent"
pill**, the card showed Share + Chat + Get skills + **"Attestation: Valid - convos"**,
Chat presented **"New chat, new context"**, and "Got it" proceeded to a new
conversation. (Screenshots captured during the run.)

## Key facts

- **Agent-builder, not CLI.** Type a prompt in the home composer
  (`agent-composer-text-field`) and tap `agent-make-button`; the builder names the
  agent and provisions it. This avoids the invite deep-link path (which opened Safari
  / created non-joining drafts on this build) entirely.
- **Local stack caveat:** the browse list now intentionally shows verified agents
  even before the backend mirrors a templateId. If the account isn't provisioned
  (`GET /accounts/me/credits` 403 / generator `ownerAccountId does not exist`), the
  agent may show "lost power" / missing publish/share affordances, but it remains
  selectable as an existing inbox. Once the stack provisions the account and assigns
  a templateId, starting or adding it can spawn a fresh template instance.
- **Publish/share is a known-issue on local.** Even with a visible contact, Share can
  404 (`agent-templates` registry has no published row for the templateId). The app
  surfaces a readable DisplayError now (not "error 6").
- The "Got it" button on the One-agent sheet has **no stable accessibility id** (shared
  `FeatureInfoSheet` + `convosButtonStyle` `AnyView` wrapper) - match the sheet by its
  unique title "New chat, new context" and tap the "Got it" label.

## Runbook

Prereqs: Docker-backed local stack bootstrapped (workspace `convos-mono`), with agent
provisioning working (account credits + templateId generator); `idb` installed.

```bash
cd <this convos-ios checkout>
LS="$(git rev-parse --show-toplevel)/dev/local-stack"
make -C "$LS" status                       # backend/herald/worker/minio = 200
make -C "$LS" ios-config IOS="$(pwd)"       # .env -> localhost:4000, config xmtpNetwork dev

# Build + launch the Local app (ad-hoc signing; org.convos.ios-local).
SIM=$(cat .claude/.simulator_id)
xcodebuild build -project Convos.xcodeproj -scheme "Convos (Local)" -configuration Local \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath .derivedData -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  PROVISIONING_PROFILE_SPECIFIER="" DEVELOPMENT_TEAM=""
APP=$(find .derivedData/Build/Products -path '*Local-iphonesimulator*' -name 'Convos.app' -type d | head -1)
xcrun simctl install "$SIM" "$APP"; xcrun simctl launch "$SIM" org.convos.ios-local

# App Check: after a fresh install/erase the app makes an UNREGISTERED debug token and
# 403s on exchangeDebugToken -> never authorizes -> empty contacts. Force the registered
# Local token, then relaunch so the inbox reaches clientAuthorized:
xcrun simctl terminate "$SIM" org.convos.ios-local
xcrun simctl spawn "$SIM" defaults write org.convos.ios-local GACAppCheckDebugToken "<registered Local token>"
xcrun simctl launch "$SIM" org.convos.ios-local
#   (the token is op://Engineering/Convos iOS Local AppCheck/credential, == the
#    stack-owning checkout's FIREBASE_APP_CHECK_DEBUG_TOKEN.)
# Verify in Logs/convos.log (app-group container): no
#   "authenticatingBackend -> clientAuthorized" failures / no 403 on exchangeDebugToken.

# Then run the sequence (agents are built in-app per the test; no CLI provisioning):
/qa 36 37 37b
```

## Status

Test 36's core is validated **passing** on the local stack (above). `publish_and_share`
is annotated as a known-issue (backend `agent-templates` registry). The
`qa/scripts/provision-agents-as-contacts.sh` CLI helper is retained for reference but
is **not** used by the agent-builder tests.
