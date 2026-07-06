---
description: Spin up a locally-attested CLI agent that the iOS app verifies as a Convos agent. Two modes - interactive (mint/reuse the debug Ed25519 keypair, pin it in the shared .env, run convos agent serve) and demo (generate a user<->agent transcript, then drive both sides - agent via the serve loop, user via the simulator - to record a product demo).
---

# /debug-agent

Spin up a locally-running CLI agent that the iOS app trusts as a verified Convos agent — without needing the production signing key. Pairs with the DEBUG-only `AGENT_DEBUG_JWKS` knob in `Secrets.swift`.

(Formerly `/debug-assistant`. Renamed because the app now calls assistants "agents" — `agentName ?? "Agent"`, `hasHadVerifiedAgent`, etc. The mechanics are unchanged.)

## Modes

| Mode | Invoke | What it does |
|------|--------|--------------|
| **Interactive** (default) | `/debug-agent [persona] [--conv …]` | Bring up one verified debug agent and talk to it by hand (stdin `send`/`react`/capability requests). |
| **Demo** | `/debug-agent demo "<brief>"` | Generate a scripted user<->agent conversation, then run **both sides** — agent via the serve loop, user via the simulator — paced for a screen recording. |

Demo mode reuses the interactive setup (Steps 1–6) to stand the agent up; the transcript just supplies the persona and the turn-by-turn script. Read the Interactive section first — Demo builds on it.

## Usage

```
# Interactive
/debug-agent
/debug-agent "Fitness Trainer"
/debug-agent "Travel Agent" --conv 0xabc123…

# Demo
/debug-agent demo "a fitness trainer that helps plan a 10k and asks for calendar access"
/debug-agent demo --generate "a travel agent that books a weekend trip"   # write the transcript, don't run
/debug-agent demo --run demos/fitness-trainer.demo.yaml                    # run an existing transcript
/debug-agent demo --run demos/fitness-trainer.demo.yaml --record           # …and capture a .mov
```

If no persona name is passed (interactive), ask the user: "What kind of agent should I fake? (default: 'Agent'; suggestions: Fitness Trainer, Travel Agent, Calendar Buddy, Training Buddy, Meal Planner)". Use the default if they hit enter.

If no `--conv` (or invite slug) is passed, ask the user for either an invite URL/slug to join, or an existing `<conversation-id>` to attach to.

## Why this exists

By default, CLI agents (`convos agent serve …`) join with no attestation, so the iOS app marks them as `agentVerification == .unverified`. That means:
- Connection cards say "Agent wants to read your calendar" (the `agentName ?? "Agent"` fallback) instead of using the agent's display name.
- System messages say "Agent has access to calendar data" instead of e.g. "Calendar Buddy has access to…".

Production agents are attested by the dev/prod pool's Ed25519 key (Railway-hosted). Locally we don't have that PEM, so this command sets up a parallel trust loop: a self-minted keypair, public half pinned in iOS via `.env`, private half handed to the CLI which signs `sha256(inboxId || ts)` automatically once the XMTP inbox resolves.

---

# Interactive mode

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

In the agents-as-contacts build, iOS only surfaces an agent in the Contacts list when it's a **verified** agent whose per-conversation profile also carries a `templateId` in `metadata` (`Contact.isVisibleInContactsList` gates on `isVerifiedAgent && agentTemplateId != nil`; `ContactSyncCoordinator` is what mirrors the `templateId` onto the `DBContact`). A debug agent is already verified via `AGENT_DEBUG_JWKS`, so it just needs the `templateId` — without it the agent renders as a verified agent inside the chat but never appears as a contact. So always set one.

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

iOS reads `metadata.description` (-> `Profile.agentDescription`) and renders it on the `AgentContactCardView` under the agent's name. A real agent writes this itself once it decides what it's set up to do; a debug agent has to set it explicitly or the card shows no subtitle. Map the persona to a short line, generic fallback otherwise:

```bash
case "$(echo "$PERSONA" | tr '[:upper:]' '[:lower:]')" in
    *fitness*|*trainer*|*workout*)  DESCRIPTION="Your personal fitness coach - workout plans, form cues, and accountability." ;;
    *travel*|*trip*)                DESCRIPTION="Plans trips end to end - flights, stays, and a day-by-day itinerary." ;;
    *calendar*|*schedul*)           DESCRIPTION="Keeps your week in order - scheduling, reminders, and conflict-spotting." ;;
    *meal*|*chef*|*food*|*recipe*)  DESCRIPTION="Plans meals and recipes around your goals and what is in the fridge." ;;
    *finance*|*money*|*budget*)     DESCRIPTION="Tracks spending and helps you stick to a budget." ;;
    *) DESCRIPTION="A $PERSONA agent (local debug agent)." ;;
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

Caveat about join `--metadata`: emoji, description, templateId, and publishedUrl are written into the join's profile, but `convos agent serve` (Step 6) publishes its own `ProfileUpdate` at startup built only from `--name` / `--profile-name` (plus the attestation metadata from `--attestation-*`) — carrying **no custom metadata** — which **overwrites** the join's emoji/description/templateId/publishedUrl. So none of those four set here survives the serve loop. You must re-push all four after serve is up (Step 6 below). Verified on the simulator: without the re-push the agent renders as "FT"-style initials and never appears as a contact.

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

When backgrounding via Claude Code (e.g. for QA or a demo run), pipe a fifo into stdin so the process doesn't see EOF — and keep the fifo path so you can send the `update-profile` (and later commands) into it:

```bash
FIFO=/tmp/agent-stdin-$SLUG
rm -f "$FIFO"; mkfifo "$FIFO"
( exec 3>"$FIFO"; sleep 99999 ) &  # writer keeps fifo open
cat "$FIFO" | CONVOS_HOME="$AGENT_HOME" convos agent serve … &
# once serve logs the `ready` event, push emoji + description + templateId + publishedUrl:
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

Default is plain `"Agent"`; suggest a few flavorful options so the renderer change is obvious:

- `Agent` (default — generic)
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

---

# Demo mode

`/debug-agent demo` turns the agent into a **scripted, two-sided puppet show** for recording a product demo. Claude plays the agent (via the serve loop's stdin) *and* the user (by driving the iOS simulator's composer), paced so the back-and-forth looks natural on screen.

It's the same bidirectional loop the QA suite already exercises in `qa/tests/structured/02-send-receive-messages.yaml`, just turned into a director's script:

| Demo role | Who drives it | How |
|-----------|---------------|-----|
| `agent` | the CLI serve loop | write `{"type":"send","text":…}` / `{"type":"attach","file":…}` to the serve `$FIFO`; optionally `{"type":"typing","isTyping":true}` first |
| `user` | the iOS simulator | `type_in_field {id: message-text-field}` + `tap {id: send-message-button}` (per `qa/TOOLS-CLAUDE.md`) |

Because Claude controls both ends, the conversation is deterministic: every line lands in the order the transcript says, with the timing the transcript says.

## Demo flow at a glance

1. **Generate** a transcript from a one-line brief (or hand it `--run <file>`).
2. **Bring the agent up** via interactive Steps 1–6, using the transcript's `persona`. Keep the serve `$FIFO` and the serve event stream.
3. **Open the conversation** on the simulator so it's on screen and the composer (`message-text-field`) is visible.
4. **Optionally start recording** (`--record`).
5. **Play the turns** in order, syncing on real events so nothing overlaps.
6. **Stop recording, report** where the `.mov` and transcript landed.

### Step D1: Generate the transcript

When invoked as `/debug-agent demo "<brief>"` (or `--generate "<brief>"`), draft a transcript that tells a tight product story for that brief: a believable user goal, an agent that's helpful and concise, and — as the money shot — the agent **making a thing for the group**: an HTML artifact sent as an attachment (a plan, an itinerary, a packing list), which renders as a card in the conversation and lands in the Things tab. This is the same artifact archetype the NUX empty state showcases (the bundled mocks at `Convos/Conversations List/Empty State/Mock Data/mock-thing-{countdown,dinner,pushups}.html`), so the demo mirrors exactly what the product promises. Write the artifact HTML alongside the transcript (`demos/<slug>-<thing>.html`, self-contained, system fonts, light/dark via `prefers-color-scheme` — copy the style of the bundled empty-state mocks). Give it a meaningful `<title>`: the Things tab now titles each artifact cell by the HTML `<title>` (falling back to the filename), so it's what the user reads on the card.

Avoid capability requests in simulator demos — granting one drives a composio OAuth flow that can't complete in the sim (see Demo tips). Only script one if the brief explicitly asks for the permission beat, and end on the card without tapping Connect.

Keep it short and demo-paced: **6–12 turns**, agent lines ≤ 2 sentences, no dead air. Open with the agent introducing itself (so the verified-agent name/emoji is visible early), end on a satisfying payoff (a plan, a booking, a summary).

Write it to `demos/<slug>.demo.yaml` (create `demos/` if missing). Then **show the user the transcript and ask them to approve or tweak it** before running — this is the cheapest place to iterate. With `--generate`, stop here and print the path.

Offer 2–3 candidate angles if the brief is open-ended ("plan-a-trip vs rescue-a-trip vs compare-two-trips") rather than committing to one silently.

### The transcript format

YAML, in the spirit of the `qa/tests/structured/*.yaml` corpus. One file per demo.

```yaml
name: "Fitness Trainer makes a 10k plan for the group"
persona:
  display_name: "Fitness Trainer"   # --name + --profile-name
  emoji: "🏋️"
  description: "Your personal fitness coach - plans, form cues, accountability."
  template_id: "debug-fitness-trainer"          # optional; defaults to debug-<slug>
  published_url: "https://agents-dev.convos.org/fitness-trainer.dbg01"  # optional

# Pacing defaults (seconds). Per-turn `delay_s` overrides these.
pacing:
  user_read_s: 1.5        # pause before the "user" starts typing a reply (reading the agent)
  agent_typing_s: 1.4     # how long the agent shows its typing indicator before the line lands
  after_turn_s: 0.8       # settle time after a bubble appears, before the next turn

# The agent sends a read receipt the moment it registers each user message,
# so the user's bubbles flip to "Read" instantly on camera. Default true.
read_receipts: true

turns:
  - role: agent
    typing: true
    text: "Hey! I'm your fitness trainer 🏋️ What are we training for?"

  - role: user
    text: "I want to run a 10k in 8 weeks"

  - role: agent
    typing: true
    text: "Love it. Give me a sec — I'll put week 1 together for you."

  # The money shot: the agent makes a thing for the group. HTML attachments
  # from agents render as artifact cards and land in the Things tab.
  - role: agent
    typing: true
    attach:
      file: demos/fitness-trainer-plan.html
      mime_type: text/html

  - role: user
    text: "This is perfect, let's do it 💪"

  - role: agent
    react: { to: last_user, emoji: "🔥" }   # react to the user's last message instead of sending text
```

Turn fields:

- `role:` — `agent` (serve loop) or `user` (simulator). Required.
- `text:` — the message body. For `agent`, sent via the `$FIFO`; for `user`, typed into `message-text-field`.
- `typing:` (agent only) — emit `{"type":"typing","isTyping":true}` for `agent_typing_s` before the line, so the app shows the agent's typing indicator. Defaults true for agent text turns; set false to skip.
- `delay_s:` — override the default pre-turn pause for this turn.
- `reply_to: last_agent | last_user` — send as a reply (maps to the serve `replyTo` / a user-side reply gesture).
- `react: { to: last_user|last_agent|<msgId>, emoji: "…" }` — react instead of (or in addition to) sending text.
- `attach: { file: <path>, mime_type: text/html }` (agent only) — send a file attachment via the serve loop (`{"type":"attach","file":…,"mimeType":…}`). An HTML attachment is how the agent **makes a thing**: it renders as an artifact card in the conversation and surfaces in the Things tab (the Things overview keys on agent-sent `text/html` files — it now shows **every** agent HTML thing in the conversation, each titled by the artifact's HTML `<title>`). Requires `CONVOS_API_KEY` (or `CONVOS_UPLOAD_PROVIDER`) in the agent's `CONVOS_HOME/.env` — serve refuses attachments without an upload provider. Beware the env-file shadowing gotcha: the CLI loads `.env` from the *current working directory* before falling back to `CONVOS_HOME/.env`, so a serve launched from a repo checkout (whose `.env` is the iOS build env, with no API key) silently loses the key — pass `--env-file "$AGENT_HOME/.env"` explicitly when running serve from inside a checkout. Write the artifact as a self-contained HTML file styled like the bundled empty-state mocks (system fonts, `prefers-color-scheme` dark support).
- `then.capability_request:` (agent only) — after the line, fire `convos conversation send-capability-request` with `subject` / `capability` / `rationale` / optional `preferred_providers`.
- `action:` (user only) — a scripted UI action instead of typing a message. Supported: `grant_capability` (drive the permission sheet to Allow), `deny_capability`, `open_contact_card`, `tap {id|label}`. Keep these to what the demo needs.

Top-level `read_receipts:` (default `true`) — after every user turn, the runner pushes `{"type":"read-receipt"}` to the serve FIFO as soon as the agent's `message` event confirms receipt, so the user's bubble flips to "Read" instantly — the agent looks attentive on camera. Set `false` to leave receipts off (e.g. when demoing the unread state itself).

### Step D2: Stand the agent up

Run interactive Steps 1–6 with `PERSONA` and the metadata taken from the transcript's `persona` block (not the auto-derived guesses). Use the **backgrounded serve** form so Claude can both write to `$FIFO` and keep playing turns:

```bash
FIFO=/tmp/agent-stdin-$SLUG
SERVE_LOG=/tmp/agent-serve-$SLUG.ndjson
rm -f "$FIFO"; mkfifo "$FIFO"
( exec 3>"$FIFO"; sleep 99999 ) &
cat "$FIFO" | CONVOS_HOME="$AGENT_HOME" convos agent serve "$CONV_ID" \
    --name "$PERSONA_NAME" --profile-name "$PERSONA_NAME" \
    --env-file "$AGENT_HOME/.env" \
    --attestation-private-key "$KEY_PATH" --attestation-kid "$KID" \
    > "$SERVE_LOG" 2>/tmp/agent-serve-$SLUG.err &
```

The explicit `--env-file` matters when running from inside a repo checkout: the CLI loads `.env` from the current working directory before `CONVOS_HOME/.env`, and the checkout's `.env` (the iOS build env) has no `CONVOS_API_KEY` — without the flag, `attach` turns fail with "Configure an upload provider".

Wait for `{"event":"ready"}` in `$SERVE_LOG`, then push the profile metadata (Step 6's `update-profile`). The `ready` event carries `conversationId`, `inviteUrl`, `inviteSlug`, and `inviteTag` — capture `conversationId` for the turn loop and surface the `inviteUrl` for the app to join. `$SERVE_LOG` is the synchronization channel for the turn loop: it carries `{"event":"sent"}` (the agent's own lines landed) and `{"event":"message"}` (a user line was received by the agent). Note the field asymmetry: an outbound `sent` event puts the body in `.text`, but an inbound `message` event puts it in `.content` (with `.senderProfile.name` and a `.contentType.typeId`).

### Step D3: Get the conversation on screen

Resolve the simulator UDID (`cat .claude/.simulator_id`, fall back per `qa/TOOLS-CLAUDE.md`). Make sure the app is foregrounded on the conversation detail for `$CONV_ID` and the composer is visible:

```bash
UDID=$(cat .claude/.simulator_id)
# wait for the composer before playing any turn
deadline=$(($(date +%s) + 20)); ok=""
while [ $(date +%s) -lt $deadline ]; do
  $IDB ui describe-all --udid $UDID 2>/dev/null | grep -q 'message-text-field' && { ok=1; break; }
done
[ -n "$ok" ] || { echo "❌ composer not visible — open $CONV_ID in the app first"; exit 1; }
```

If the conversation isn't open, tap into it from the chat list (or deep-link via `xcrun simctl openurl`). Don't start the loop until `message-text-field` is on screen.

The cleanest way to put the local user and the agent in the same conversation is the **agent-creates, app-joins** path: the serve loop already created a conversation and printed `inviteUrl` in its `ready` event, so just `xcrun simctl openurl "$UDID" "$INVITE"` and the app joins and lands in it. The Dev build's `ASSOCIATED_DOMAIN` is `dev.convos.org`, which matches the CLI invite host, so the universal link routes straight to the app.

Admission takes a few seconds: right after the join the app shows "Verifying. See and send messages after your access is verified." with the header reading "1 member"; wait for the serve loop's `{"event":"member_joined"}` and for the header to flip to "2 members" before driving any turn.

### Step D4: Record (optional, `--record`)

`simctl` records the simulator framebuffer straight to an `.mov` (no device bezel, no cursor):

```bash
mkdir -p demos
OUT="demos/$SLUG.mov"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT" &
REC_PID=$!
```

Stop it after the last turn with a clean SIGINT so the file finalizes:

```bash
kill -INT "$REC_PID"; wait "$REC_PID" 2>/dev/null
```

Make sure `demos/*.mov` is gitignored so recordings don't get committed:

```bash
grep -qxF 'demos/*.mov' .gitignore 2>/dev/null || printf '\n# Demo recordings\ndemos/*.mov\n' >> .gitignore
```

For a polished, bezel-framed capture, a screen recording of the Simulator window (QuickTime, `⌘⇧5`) looks better than the raw framebuffer — mention this to the user and let them choose. Either way, drive Reduce Motion on first (`qa.md` step 4) so animations are crisp and deterministic.

### Step D5: Play the turns

Walk `turns` in order. For each turn, resolve `delay_s` (or the matching `pacing` default), then:

**Agent text turn:**
```bash
# optional typing indicator
[ "$TYPING" = true ] && { jq -nc '{type:"typing",isTyping:true}' > "$FIFO"; sleep "$AGENT_TYPING_S"; }
# the line itself
jq -nc --arg t "$TEXT" '{type:"send",text:$t}' > "$FIFO"          # add replyTo:$ID for reply turns
# sync: wait for the serve loop to confirm it sent, then for the bubble to render in the app
#   - grep $SERVE_LOG (tail since marker) for {"event":"sent"...}
#   - wait_for_element { label_contains: <first words of TEXT> } in the app (qa/TOOLS-CLAUDE.md)
```

**User text turn:**
```bash
# tap the field, type, send (qa/TOOLS-CLAUDE.md recipes)
#   type_in_field { id: message-text-field, text: TEXT }
#   tap { id: send-message-button }
# sync: wait_for_element { label_contains: TEXT } locally, AND for the agent to
#   register it — grep $SERVE_LOG for {"event":"message",...,"content":"TEXT"}
#   (inbound bodies live in .content, not .text).
# read receipt (if read_receipts, default true): the instant the message event
#   lands, push the receipt so the user's bubble flips to "Read" on camera —
jq -nc '{type:"read-receipt"}' > "$FIFO"
#   confirmation: $SERVE_LOG logs {"event":"sent","type":"read-receipt"}.
```

**Agent attach turn (make a thing):**
```bash
# optional typing beat first, same as a text turn
jq -nc --arg f "demos/<slug>-plan.html" --arg m "text/html" \
  '{type:"attach",file:$f,mimeType:$m}' > "$FIFO"
# sync: $SERVE_LOG logs {"event":"sent","type":"attachment",...,"url":...}
#   once uploaded (note: "attachment", not "attach");
#   then wait for the artifact card to render in the app (wait_for_element on
#   the attachment cell — give it a generous timeout, upload + thumbnail
#   render take a few seconds). Hold an extra beat: the card IS the demo.
#   The chat-list preview + push now read "<agent> made you a thing"
#   (group: "made a thing for the group") — a handy sync / on-camera signal.
```
If serve emits `Configure an upload provider…` instead of `sent`, the agent's `CONVOS_HOME/.env` is missing `CONVOS_API_KEY` — set it before the run (attachments are the only turn type that needs it).

**`then.capability_request`:** after the agent line lands, run the `send-capability-request` from "Triggering capability requests" with the transcript's subject/capability/rationale.

**`action: grant_capability`:** wait for the capability sheet, then drive it to Allow — `tap { label_contains: "Allow" }`, falling back to the validated coords in `qa/TOOLS-CLAUDE.md` ("System dialog buttons") if the tree tap misses. `deny_capability` taps "Don't Allow" / "Not now".

**`react`:** resolve the target message id from the serve `$SERVE_LOG` (the `last_agent`/`last_user` `{"event":"sent"|"message"}` line carries the id) and push `{"type":"react","messageId":…,"emoji":…}`, or perform the user-side long-press→emoji gesture.

Sync on **real events, never blind sleeps** for correctness — the `sleep`s are only the deliberate *pacing* beats (`agent_typing_s`, `user_read_s`). The barrier between turns is: the previous line is confirmed both sent (serve `$SERVE_LOG`) and rendered (app `wait_for_element`). This is what keeps the agent from talking over the user when the network lags.

### Step D6: Stop and report

```
🎬 Demo complete: <name>
📝 Transcript:  demos/<slug>.demo.yaml   (<n> turns)
🎥 Recording:   demos/<slug>.mov         (only if --record)
🤖 Agent:        <PERSONA_NAME> on <CONV_ID>
```

Stop recording (SIGINT), leave the serve loop running so the user can keep poking at the conversation, and remind them how to tear down (Cleanup, below). If a turn failed to sync (timed out waiting for a bubble or a serve event), report which turn and stop rather than letting the script drift out of order.

## Demo tips

- **Keep agent lines short.** Long bubbles scroll the composer off screen and read slowly on video. ≤ 2 sentences.
- **Put the verified name/emoji on camera early.** Lead with the agent's intro line so the avatar + display name (the whole point of the attestation) is visible in the first few seconds.
- **Make the thing the climax.** "Agents make things for the group" is the product story, so build every demo toward the agent's `attach` turn: a couple of chat beats, then the artifact card lands, the user reacts, done. One thing per demo — let it breathe on screen for a few seconds before the next turn.
- **Avoid capability requests in sim demos.** A `calendar`/`read` request renders an in-conversation card ("Fitness Trainer wants to read your calendar … Google Calendar / Connect / Deny") — but tapping **Connect** launches a real composio.dev Google OAuth via `ASWebAuthenticationSession`, which **cannot complete in the simulator**: the web-auth sheet covers the conversation and blocks every later turn (the composer included). If the brief explicitly needs the permission beat, treat the card itself as the final shot (fire the `capability_request`, hold, stop — never tap Connect), script `action: deny_capability` to keep the conversation flowing, or record on a real device with a real Google account. One per demo at most; the sheet drags if repeated.
- **Re-run is cheap.** Tweak the YAML and `--run` it again on a fresh conversation. Generate a new invite from the app (or attach to a clean conversation) so the scrollback starts empty for the take.
- **Reduce Motion + a clean conversation** make the most reproducible footage.

---

## Troubleshooting

- **"AGENT_DEBUG_JWKS not in Secrets.swift" / agent stays unverified after rebuild.** The build phase only writes the field on a clean Xcode build. Try `rm -rf .derivedData` then `/run`.
- **Agent stays unverified even though `.env` has an `AGENT_DEBUG_JWKS` line.** Check the *value*, not just the line: re-derive the JWKS from the keypair (Step 2) and compare it to what's pinned. A placeholder or truncated value (e.g. literally `...`) bakes garbage into every build and the app silently marks every debug agent unverified — `grep -c '^AGENT_DEBUG_JWKS='` passing proves nothing. On success the app logs `[AgentVerification] upgraded N agent(s) to verified` on the next launch, and verified agents render with the lava-badge avatar treatment (header pill, hero card with description, message rows) instead of the plain emoji tile.
- **`convos attestation generate` errors with "private key not Ed25519".** The PEM at `~/.convos-debug-attest.pem` is corrupt; delete it and rerun this command to remint.
- **iOS log shows "[Attestation] timestamp too old".** The agent's `attestation_ts` is older than 24 h. Just re-run `agent serve` — `--attestation-private-key` re-signs on each start.
- **iOS log shows "[Attestation] agent <id> cached result: unverified" (a debug-level log).** Either the JWKS pubkey doesn't match the private key (re-derive JWKS in step 2 and re-pin in step 3), or the kid in `Secrets.swift` differs from the kid used to sign — make sure both ends use the same `--kid`.
- **Two agents joined; only one is verified.** Each XMTP identity has its own inboxId; each agent needs its own `CONVOS_HOME` so the CLI signs against the correct inboxId.
- **Agent shows initials (e.g. "FT") instead of its emoji, or the contact card has no description.** The metadata you passed at join time (`emoji` / `description` / `templateId` / `publishedUrl`) was overwritten by the serve loop's startup `ProfileUpdate` (which republishes only name + attestation metadata, dropping custom fields). Push the whole set again through the running loop's stdin: `jq -nc --arg n "<persona>" --arg e "🏋️" --arg d "<one-liner>" --arg t "debug-<slug>" --arg u "<published-url>" '{type:"update-profile",name:$n,metadata:{emoji:$e,description:$d,templateId:$t,publishedUrl:$u}}' > "$FIFO"`. iOS re-renders the avatar and card subtitle within a few seconds. (`agent serve` has no `--metadata` flag, so there's no way to carry it through startup — the post-serve push is the reliable path.)
- **Agent is verified in chat but never appears in Contacts.** Its profile is missing `templateId` in `metadata` — `Contact.isVisibleInContactsList` only surfaces agents that carry one. Re-push the profile with both `emoji` and `templateId` (see above), then have the local user send a message in the conversation so `ContactSyncCoordinator` mirrors the templateId onto the contact. (If you only ever set `emoji`, the agent stays chat-only.)
- **Contact card has no Share button.** The profile is missing `publishedUrl` in `metadata` — `ContactDetailView` only shows the Share action / agent-share QR when `Profile.agentTemplatePublishedURL` is non-empty. Re-push the profile including `publishedUrl` (see Step 6). Any plausible string works for a debug agent; the QR just encodes it.

### Demo-mode troubleshooting

- **The agent talks over the user (lines out of order).** A turn advanced on a `sleep` instead of a real event. Make sure each turn waits for both the serve `$SERVE_LOG` confirmation and the app `wait_for_element` before the next turn starts. The pacing `sleep`s are *additive* delays, not the sync barrier.
- **Typing indicator never shows.** `{"type":"typing","isTyping":true}` has to be sent on its own line *before* the `send`, with a real gap (`agent_typing_s`) between them — if you send typing and the message back-to-back, the indicator is replaced before it renders.
- **A user turn doesn't send.** `message-text-field` lost focus, or the toolbar `send-message-button` wasn't enumerated. Re-tap the field, re-type, and tap send by id; fall back to coords per `qa/TOOLS-CLAUDE.md` only as a last resort.
- **Recording is empty / 0 bytes.** `recordVideo` was killed with `SIGKILL` (or the process never started). Stop it with `kill -INT` and `wait` so the moov atom is written.
- **Recording looks janky.** Reduce Motion wasn't on. Set the `qa.md` step-4 defaults and relaunch the app before recording.
- **A web page covers the conversation mid-demo.** A capability card's **Connect** was tapped, launching composio.dev OAuth in an `ASWebAuthenticationSession` that can't finish in the simulator. Cancel it (tap "Cancel" on the "wants to use composio.dev to Sign In" sheet) to get the conversation back, and end future takes at the capability card instead of tapping Connect (see Demo tips).

## Cleanup

To revert: clear `AGENT_DEBUG_JWKS` from `$SHARED_ENV`, `/run` to rebuild Secrets.swift, `rm -rf ~/.convos-debug-agent-*` to drop the isolated identity dirs, and `rm ~/.convos-debug-attest.pem` if you want to wipe the keypair too. For demo runs, also `kill -INT` any background `recordVideo`, send `{"type":"stop"}` to the serve `$FIFO` (or kill the serve process), and `rm -f /tmp/agent-stdin-* /tmp/agent-serve-*`. Generated transcripts under `demos/` are safe to keep and re-run; the `.mov` files are gitignored.
