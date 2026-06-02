---
description: Spin up a locally-attested CLI agent that the iOS app verifies as a Convos assistant. Mints (or reuses) the debug Ed25519 keypair, ensures it's pinned in the shared .env, then runs convos agent serve with the right attestation flags.
---

# /debug-assistant

Spin up a locally-running CLI agent that the iOS app trusts as a verified Convos assistant — without needing the production signing key. Pairs with the DEBUG-only `AGENT_DEBUG_JWKS` knob in `Secrets.swift`.

## Usage

```
/debug-assistant
/debug-assistant "Fitness Trainer"
/debug-assistant "Travel Agent" --conv 0xabc123…
```

If no persona name is passed, ask the user: "What kind of assistant should I fake? (default: 'Assistant'; suggestions: Fitness Trainer, Travel Agent, Calendar Buddy, Training Buddy, Meal Planner)". Use the default if they hit enter.

If no `--conv` (or invite slug) is passed, ask the user for either an invite URL/slug to join, or an existing `<conversation-id>` to attach to.

## Why this exists

By default, CLI agents (`convos agent serve …`) join with no attestation, so the iOS app marks them as `agentVerification == .unverified`. That means:
- Connection cards say "Assistant wants to read your calendar" instead of using the agent's display name.
- System messages say "Assistant has access to calendar data" instead of e.g. "Calendar Buddy has access to…".

Production agents are attested by the dev/prod pool's Ed25519 key (Railway-hosted). Locally we don't have that PEM, so this command sets up a parallel trust loop: a self-minted keypair, public half pinned in iOS via `.env`, private half handed to the CLI which signs `sha256(inboxId || ts)` automatically once the XMTP inbox resolves.

## Instructions

### Step 1: Resolve the shared `.env`

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
LOCAL_ENV="$REPO_ROOT/.env"
SHARED_ENV=$(readlink -f "$LOCAL_ENV" 2>/dev/null || echo "$LOCAL_ENV")
```

Most worktrees have `.env` symlinked to a shared parent (`~/Code/xmtplabs/.env`, or some users have `~/Code/convos-ios-shared.env`). `readlink -f` follows the symlink so we always pin into the file the build phase actually reads.

If `$LOCAL_ENV` doesn't exist or isn't a symlink yet, fall back to the standard parent layout from `/firebase-token` Step 1/2 — see that command if you need to set up the symlink first.

### Step 2: Resolve / mint the debug keypair

The keypair lives at `~/.convos-debug-attest.pem` (private key, gitignored by living outside any repo). Mint once, reuse across runs.

```bash
KEY_PATH="$HOME/.convos-debug-attest.pem"
KID="convos-agents-test"

if [ ! -f "$KEY_PATH" ]; then
    echo "🔑 Minting fresh Ed25519 debug keypair → $KEY_PATH"
    convos attestation generate "bootstrap" --kid "$KID" --json \
        > "$HOME/.convos-debug-attest.json"
    jq -r '.privateKeyPem' "$HOME/.convos-debug-attest.json" > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    rm "$HOME/.convos-debug-attest.json"
    echo "✅ Saved private key (mode 600)"
else
    echo "✅ Reusing existing keypair at $KEY_PATH"
fi

# Derive the matching JWKS for iOS by signing a throwaway value.
JWKS=$(convos attestation generate "bootstrap" \
    --kid "$KID" --private-key "$(cat "$KEY_PATH")" --json | jq -c '.jwks')
echo "🔑 JWKS for iOS: $JWKS"
```

### Step 3: Pin `AGENT_DEBUG_JWKS` in the shared `.env`

```bash
if grep -q '^AGENT_DEBUG_JWKS=' "$SHARED_ENV" 2>/dev/null; then
    EXISTING=$(grep '^AGENT_DEBUG_JWKS=' "$SHARED_ENV" | cut -d'=' -f2- | sed -e "s/^'//" -e "s/'\$//")
    if [ "$EXISTING" = "$JWKS" ]; then
        echo "✅ AGENT_DEBUG_JWKS already pinned and matches"
        REBUILD_NEEDED=0
    else
        # macOS sed -i requires '' after the flag. Wrap value in single quotes so JSON's
        # double quotes survive shell parsing later.
        sed -i '' "s|^AGENT_DEBUG_JWKS=.*|AGENT_DEBUG_JWKS='${JWKS}'|" "$SHARED_ENV"
        echo "🔄 Updated AGENT_DEBUG_JWKS in $SHARED_ENV"
        REBUILD_NEEDED=1
    fi
else
    echo "AGENT_DEBUG_JWKS='${JWKS}'" >> "$SHARED_ENV"
    REBUILD_NEEDED=1
    echo "✅ Appended AGENT_DEBUG_JWKS to $SHARED_ENV"
fi
```

If `REBUILD_NEEDED=1`, the running app won't trust the agent yet — the build phase has to bake the JWKS into `Secrets.swift`. Tell the user to `/run` (or rebuild + relaunch) before the agent joins.

### Step 4: Pick an isolated `CONVOS_HOME` for this agent

CLI defaults to `~/.convos`, which is shared with the user's other identities. Each debug agent gets its own dir so its identity is isolated and can be torn down without disturbing other work:

```bash
SLUG=$(echo "$PERSONA" | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9-]//g')
AGENT_HOME="$HOME/.convos-debug-agent-$SLUG"
CONVOS_HOME="$AGENT_HOME" convos init --env dev --force >/dev/null
```

### Step 4b: Pick an emoji for the profile metadata

iOS reads `metadata.emoji` off the agent's `ProfileUpdate` and renders it as the avatar fallback / sticker on the contact card. Map the persona to a fitting emoji so the agent stands out in the chat list instead of showing a default "A" tile. Pick from the persona's name with a small case-insensitive substring match; fall back to `🤖` for anything unrecognised.

```bash
case "$(echo "$PERSONA" | tr '[:upper:]' '[:lower:]')" in
    *fitness*|*trainer*)               EMOJI="🏋️" ;;
    *travel*|*trip*)                   EMOJI="✈️" ;;
    *calendar*|*schedul*)              EMOJI="📅" ;;
    *training*|*workout*)              EMOJI="💪" ;;
    *meal*|*chef*|*food*|*recipe*)     EMOJI="🍽️" ;;
    *coach*)                           EMOJI="🎯" ;;
    *finance*|*money*|*budget*)        EMOJI="💸" ;;
    *therap*|*coun*)                   EMOJI="🧠" ;;
    *music*|*song*|*dj*)               EMOJI="🎵" ;;
    *photo*|*pic*|*image*)             EMOJI="📸" ;;
    *book*|*read*|*librar*)            EMOJI="📚" ;;
    *garden*|*plant*)                  EMOJI="🌱" ;;
    *dog*|*pet*|*cat*)                 EMOJI="🐾" ;;
    *bike*|*cyclist*|*cycle*|*ride*)   EMOJI="🚴" ;;
    *run*|*runner*)                    EMOJI="🏃" ;;
    *) EMOJI="🤖" ;;
esac
echo "🎨 Emoji: $EMOJI"
```

If the user wants a specific emoji rather than the auto-pick, accept `<displayName>::<profileName>::<emoji>::<templateId>` as the persona arg (split on `::`, all trailing parts optional) — same parsing convention as the existing display/profile-name override.

### Step 4c: Pick a `templateId` so the agent shows up as a contact

In the agents-as-contacts build, iOS only surfaces an agent in the Contacts list when its per-conversation profile carries a `templateId` in `metadata` (that's what `ContactSyncCoordinator` mirrors onto the `DBContact`, and what `Contact.isVisibleInContactsList` gates on). Without it the agent renders as a verified assistant inside the chat but never appears as a contact. So always set one.

```bash
# Default: a stable per-persona debug id. Nothing on the backend has this id,
# so `GET /api/v2/agent-templates/{id}` 404s gracefully and the contact shows
# the agent's instance name/emoji (the cold-cache path). To exercise the
# canonical-name override instead, pass a REAL published template id via the
# `<...>::<templateId>` persona override slot.
TEMPLATE_ID="${TEMPLATE_ID:-debug-$SLUG}"
echo "🪪 templateId: $TEMPLATE_ID"
```

### Step 4d: Write a one-line description for the contact card

iOS reads `metadata.description` (-> `Profile.agentDescription`) and renders it on the `AgentContactCard` under the agent's name. A real agent writes this itself once it decides what it's set up to do; a debug agent has to set it explicitly or the card shows no subtitle. Map the persona to a short line, generic fallback otherwise:

```bash
case "$(echo "$PERSONA" | tr '[:upper:]' '[:lower:]')" in
    *fitness*|*trainer*|*workout*)  DESCRIPTION="Your personal fitness coach - workout plans, form cues, and accountability." ;;
    *travel*|*trip*)                DESCRIPTION="Plans trips end to end - flights, stays, and a day-by-day itinerary." ;;
    *calendar*|*schedul*)           DESCRIPTION="Keeps your week in order - scheduling, reminders, and conflict-spotting." ;;
    *meal*|*chef*|*food*|*recipe*)  DESCRIPTION="Plans meals and recipes around your goals and what is in the fridge." ;;
    *finance*|*money*|*budget*)     DESCRIPTION="Tracks spending and helps you stick to a budget." ;;
    *) DESCRIPTION="A $PERSONA assistant (local debug agent)." ;;
esac
echo "📝 description: $DESCRIPTION"
```

### Step 4e: Set a `publishedUrl` so the contact card's Share button shows

iOS only renders the Share button / agent-share QR overlay on the contact detail view when the agent's profile carries a non-empty `publishedUrl` in `metadata` (`Profile.agentTemplatePublishedURL`, which `ContactDetailView` gates the share action on). Real template agents get a backend-minted link shaped like `https://agents-dev.convos.org/<slug>.<shortid>`; a debug agent fakes one. The host doesn't have to resolve — the QR just encodes whatever string you set:

```bash
PUBLISHED_URL="${PUBLISHED_URL:-https://agents-dev.convos.org/$SLUG.dbg01}"
echo "🔗 publishedUrl: $PUBLISHED_URL"
```

### Step 5: Join (or attach), with one command

Two paths, both single-shot now that the CLI signs internally with `--attestation-private-key`:

**a. Joining via invite (most common — user just generated an invite from the app):**

```bash
INVITE="$1"
PERSONA_NAME="$PERSONA"

JOIN=$(CONVOS_HOME="$AGENT_HOME" convos conversations join "$INVITE" \
    --profile-name "$PERSONA_NAME" \
    --metadata "emoji=$EMOJI" \
    --metadata "description=$DESCRIPTION" \
    --metadata "templateId=$TEMPLATE_ID" \
    --metadata "publishedUrl=$PUBLISHED_URL" \
    --attestation-private-key "$KEY_PATH" \
    --attestation-kid "$KID" \
    --timeout 120 \
    --json)
CONV_ID=$(echo "$JOIN" | jq -r '.conversationId')
echo "🤝 Joined conversation $CONV_ID"
```

The CLI mints the attestation itself, signing `sha256(inboxId || now)` once the XMTP client materializes the inboxId. No re-mint needed.

Caveat about join `--metadata`: emoji, description, templateId, and publishedUrl are written into the join's profile, but `convos agent serve` (Step 6) publishes its own `ProfileUpdate` at startup built only from `--name` / `--profile-name` — with no metadata — which **overwrites** the join metadata with an empty set. So none of the emoji, description, templateId, or publishedUrl set here survives the serve loop. You must re-push all four after serve is up (Step 6 below). Verified on the simulator: without the re-push the agent renders as "FT"-style initials and never appears as a contact.

**b. Attaching to an existing conversation:**

```bash
CONV_ID="<existing-id>"
CONVOS_HOME="$AGENT_HOME" convos conversation update-profile "$CONV_ID" \
    --name "$PERSONA_NAME" \
    --metadata "emoji=$EMOJI" \
    --metadata "description=$DESCRIPTION" \
    --metadata "templateId=$TEMPLATE_ID" \
    --metadata "publishedUrl=$PUBLISHED_URL"
```

(Skip the join — go straight to step 6. As with path (a), the serve loop's startup `ProfileUpdate` carries no metadata, so the emoji and templateId have to be pushed *after* serve is up via the stdin `update-profile` command in Step 6, not here.)

### Step 6: Serve

```bash
echo "🤖 Starting $PERSONA_NAME on $CONV_ID"
CONVOS_HOME="$AGENT_HOME" convos agent serve "$CONV_ID" \
    --name "$PERSONA_NAME" \
    --profile-name "$PERSONA_NAME" \
    --attestation-private-key "$KEY_PATH" \
    --attestation-kid "$KID"
```

Keep this in the foreground — the user interacts via stdin (`{"type":"send","text":"…"}`, `{"type":"react",…}`, etc.). Ctrl-C to stop. Nothing persists beyond `~/.convos-debug-attest.pem`, the `.env` entry, and the agent's identity dir.

`agent serve` has no `--metadata` flag, so the emoji, description, templateId, and publishedUrl set at join time are gone after the startup `ProfileUpdate`. Re-publish all four through the running loop's stdin once serve is up (a single `update-profile` carries the whole metadata set). Build it with `jq` so the free-text description can't break the JSON:

```bash
jq -nc --arg n "$PERSONA_NAME" --arg e "$EMOJI" --arg d "$DESCRIPTION" --arg t "$TEMPLATE_ID" --arg u "$PUBLISHED_URL" \
  '{type:"update-profile",name:$n,metadata:{emoji:$e,description:$d,templateId:$t,publishedUrl:$u}}' > "$FIFO"
```

The loop logs `{"event":"sent","type":"update-profile",...,"metadata":{"emoji":"…","description":"…","templateId":"…","publishedUrl":"…"}}`; iOS re-renders the avatar with the emoji within a few seconds, shows the description and the Share button on the contact card, and the agent shows up as a contact once the local user next acts in the conversation (`ContactSyncCoordinator` mirrors the templateId onto the contact on the first outbound message / member sync).

When backgrounding via Claude Code (e.g. for QA), pipe a fifo into stdin so the process doesn't see EOF — and keep the fifo path so you can send the `update-profile` (and later commands) into it:

```bash
FIFO=/tmp/agent-stdin-$SLUG
rm -f "$FIFO"; mkfifo "$FIFO"
( exec 3>"$FIFO"; sleep 99999 ) &  # writer keeps fifo open
cat "$FIFO" | CONVOS_HOME="$AGENT_HOME" convos agent serve … &
# once serve logs the `ready` event, push the emoji + description + templateId:
jq -nc --arg n "$PERSONA_NAME" --arg e "$EMOJI" --arg d "$DESCRIPTION" --arg t "$TEMPLATE_ID" --arg u "$PUBLISHED_URL" \
  '{type:"update-profile",name:$n,metadata:{emoji:$e,description:$d,templateId:$t,publishedUrl:$u}}' > "$FIFO"
```

### Step 7: Report

```
🔑 Debug keypair: ~/.convos-debug-attest.pem (kid: convos-agents-test)
📌 Pinned in:    <SHARED_ENV>
📂 Agent home:   ~/.convos-debug-agent-<slug>
🤖 Agent:         <PERSONA_NAME>
🪪 templateId:    <TEMPLATE_ID>
📝 Description:   <DESCRIPTION>
🔗 publishedUrl:  <PUBLISHED_URL>
💬 Conversation:  <CONV_ID>

Agent is running. iOS marks it as verified(.convos) once it sees the
ProfileUpdate metadata. If the agent stays "unverified" in the app:
  • Did you /run after AGENT_DEBUG_JWKS was set? (build phase has to bake it in)
  • Logs: pull `Logs/convos.log` from the app group and grep for [Attestation].
```

## Persona suggestions

Default is plain `"Assistant"`; suggest a few flavorful options so the renderer change is obvious:

- `Assistant` (default — generic)
- `Fitness Trainer`
- `Travel Agent`
- `Calendar Buddy`
- `Training Buddy`
- `Meal Planner`

Whatever they pick goes into both `--name` (agent's XMTP display) and `--profile-name` (per-conversation profile). If they want different values, accept `<displayName>::<profileName>::<emoji>::<templateId>` syntax — split on `::`, all parts after the display name optional. Pass a real published `templateId` in the 4th slot to test the canonical-template cache override; omit it to get the auto `debug-<slug>` cold-cache id.

## Triggering capability requests

Once the agent is running, you can fire capability flows from another shell:

```bash
CONVOS_HOME="$AGENT_HOME" convos conversation send-capability-request "$CONV_ID" \
    --subject calendar --capability read \
    --rationale "Help plan your trip itinerary." \
    --preferred-providers composio.google_calendar
```

Subjects: `calendar`, `contacts`, `tasks`, `mail`, `photos`, `fitness`, `music`, `location`, `home`, `screen_time`. Capabilities: `read`, `write_create`, `write_update`, `write_delete`. Drop `--preferred-providers` to let the picker default; pass it to nudge the user toward a specific provider (e.g. force the OAuth path over the device-Calendar fallback).

## Troubleshooting

- **"AGENT_DEBUG_JWKS not in Secrets.swift" / agent stays unverified after rebuild.** The build phase only writes the field on a clean Xcode build. Try `rm -rf .derivedData` then `/run`.
- **`convos attestation generate` errors with "private key not Ed25519".** The PEM at `~/.convos-debug-attest.pem` is corrupt; delete it and rerun this command to remint.
- **iOS log shows "[Attestation] timestamp too old".** The agent's `attestation_ts` is older than 24 h. Just re-run `agent serve` — `--attestation-private-key` re-signs on each start.
- **iOS log shows "[Attestation] cached result: unverified".** Either the JWKS pubkey doesn't match the private key (re-derive JWKS in step 2 and re-pin in step 3), or the kid in `Secrets.swift` differs from the kid used to sign — make sure both ends use the same `--kid`.
- **Two agents joined; only one is verified.** Each XMTP identity has its own inboxId; each agent needs its own `CONVOS_HOME` so the CLI signs against the correct inboxId.
- **Agent shows initials (e.g. "FT") instead of its emoji, or the contact card has no description.** The metadata you passed at join time (`emoji` / `description` / `templateId`) was overwritten by the serve loop's metadata-less startup `ProfileUpdate`. Push the whole set again through the running loop's stdin: `jq -nc --arg n "<persona>" --arg e "🏋️" --arg d "<one-liner>" --arg t "debug-<slug>" '{type:"update-profile",name:$n,metadata:{emoji:$e,description:$d,templateId:$t}}' > "$FIFO"`. iOS re-renders the avatar and card subtitle within a few seconds. (`agent serve` has no `--metadata` flag, so there's no way to carry it through startup — the post-serve push is the reliable path.)
- **Agent is verified in chat but never appears in Contacts.** Its profile is missing `templateId` in `metadata` — `Contact.isVisibleInContactsList` only surfaces agents that carry one. Re-push the profile with both `emoji` and `templateId` (see above), then have the local user send a message in the conversation so `ContactSyncCoordinator` mirrors the templateId onto the contact. (If you only ever set `emoji`, the agent stays chat-only.)
- **Contact card has no Share button.** The profile is missing `publishedUrl` in `metadata` — `ContactDetailView` only shows the Share action / agent-share QR when `Profile.agentTemplatePublishedURL` is non-empty. Re-push the profile including `publishedUrl` (see Step 6). Any plausible string works for a debug agent; the QR just encodes it.

## Cleanup

To revert: clear `AGENT_DEBUG_JWKS` from `$SHARED_ENV`, `/run` to rebuild Secrets.swift, `rm -rf ~/.convos-debug-agent-*` to drop the isolated identity dirs, and `rm ~/.convos-debug-attest.pem` if you want to wipe the keypair too.
