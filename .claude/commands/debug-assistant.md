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
/debug-assistant --focus <invite-slug>           # Assistant Builder focus mode
/debug-assistant "Travel Buddy" --focus <invite> # focus mode with custom persona
```

If no persona name is passed, ask the user: "What kind of assistant should I fake? (default: 'Assistant'; suggestions: Fitness Trainer, Travel Agent, Calendar Buddy, Training Buddy, Meal Planner)". Use the default if they hit enter.

If no `--conv`, `--focus`, or invite slug is passed, ask the user for one of:
- an invite URL/slug to join via `agent serve` (standard agent),
- an existing `<conversation-id>` to attach to, or
- `--focus <invite>` if they're testing the Assistant Builder focus-mode flow (hammer toolbar in iOS).

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

### Step 5: Join (or attach), with one command

Three paths, all single-shot now that the CLI signs internally with `--attestation-private-key`:

**a. Joining via invite (most common — user just generated an invite from the app):**

```bash
INVITE="$1"
PERSONA_NAME="$PERSONA"

JOIN=$(CONVOS_HOME="$AGENT_HOME" convos conversations join "$INVITE" \
    --profile-name "$PERSONA_NAME" \
    --attestation-private-key "$KEY_PATH" \
    --attestation-kid "$KID" \
    --timeout 120 \
    --json)
CONV_ID=$(echo "$JOIN" | jq -r '.conversationId')
echo "🤝 Joined conversation $CONV_ID"
```

The CLI mints the attestation itself, signing `sha256(inboxId || now)` once the XMTP client materializes the inboxId. No re-mint, no manual `update-profile` push.

**b. Attaching to an existing conversation:**

```bash
CONV_ID="<existing-id>"
```

(Skip the join — go straight to step 6 with `--attestation-private-key` and the agent serve loop will publish a fresh ProfileUpdate at startup containing the attestation.)

**c. Assistant Builder focus mode (`--focus <invite>`):**

For testing the iOS hammer-toolbar / live-co-typing flow. `convos agent focus` does the join itself, then waits for `FocusModeControl(.start)` from iOS and enters the streaming-text loop. There is no separate `conversations join` step and no follow-up `agent serve` — focus mode is a single command.

```bash
INVITE="$2"   # the slug after --focus
PERSONA_NAME="$PERSONA"

CONVOS_HOME="$AGENT_HOME" convos agent focus "$INVITE" --env dev \
    --profile-name "$PERSONA_NAME" \
    --attestation-private-key "$KEY_PATH" \
    --attestation-kid "$KID"
```

Skip Step 6 entirely — the focus loop runs inline. iOS auto-promotes the agent to focused once it sees the join, and the indicator's avatar should render with the verified ring (`agentVerification == .verified(.convos)`) since the ProfileUpdate carries the attestation triple.

### Step 6: Serve (skip for focus mode)

```bash
echo "🤖 Starting $PERSONA_NAME on $CONV_ID"
CONVOS_HOME="$AGENT_HOME" convos agent serve "$CONV_ID" \
    --name "$PERSONA_NAME" \
    --profile-name "$PERSONA_NAME" \
    --attestation-private-key "$KEY_PATH" \
    --attestation-kid "$KID"
```

Keep this in the foreground — the user interacts via stdin (`{"type":"send","text":"…"}`, `{"type":"react",…}`, etc.). Ctrl-C to stop. Nothing persists beyond `~/.convos-debug-attest.pem`, the `.env` entry, and the agent's identity dir.

When backgrounding via Claude Code (e.g. for QA, or for `--focus` runs Claude is driving), pipe a fifo into stdin so the process doesn't see EOF:

```bash
mkfifo /tmp/agent-stdin
( exec 3>/tmp/agent-stdin; sleep 9999 ) &  # writer keeps fifo open
cat /tmp/agent-stdin | convos agent serve … &
```

Focus-mode stdin commands are different from `agent serve` — they're `{"type":"text","text":"…"}` (publish a snapshot of the current bubble), `{"type":"clear"}` (end-of-thought), and `{"type":"stop"}` (send `FocusModeControl(.stop)` and exit). Snapshots are full bubble text, not deltas — empty text means the user backspaced to nothing, and is **not** the same as a clear.

### Step 7: Report

```
🔑 Debug keypair: ~/.convos-debug-attest.pem (kid: convos-agents-test)
📌 Pinned in:    <SHARED_ENV>
📂 Agent home:   ~/.convos-debug-agent-<slug>
🤖 Agent:         <PERSONA_NAME>
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

Whatever they pick goes into both `--name` (agent's XMTP display) and `--profile-name` (per-conversation profile). If they want different values, accept `<displayName>::<profileName>` syntax — split on `::`.

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

## Cleanup

To revert: clear `AGENT_DEBUG_JWKS` from `$SHARED_ENV`, `/run` to rebuild Secrets.swift, `rm -rf ~/.convos-debug-agent-*` to drop the isolated identity dirs, and `rm ~/.convos-debug-attest.pem` if you want to wipe the keypair too.
