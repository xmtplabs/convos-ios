# QA

Create and manage stress test conversations for Convos QA testing.

## Usage

Use natural language. Examples:

```
/qa create a convo with 5 members
/qa make a conversation about travel with 10 members and join it in the simulator
/qa join in the simulator a convo with 8 members
/qa 5 members talking about coffee, join in sim
/qa add 3 fake members to https://convos.app/v2?i=abc123
/qa what's running?
/qa stop stress-test-abc123
/qa update
```

## When to Use

- Creating test conversations with fake AI-generated members
- Stress testing the messaging system
- Testing invite flows in the iOS simulator
- Adding fake members to existing conversations

## Instructions

### Step 0: Bootstrap (Run Every Time)

Before executing any QA command, ensure the convos-agents service is running.

#### 0.1: Check if Service is Already Running

```bash
curl -s http://localhost:3000/health 2>/dev/null | grep -q '"status":"ok"'
```

If health check passes, skip to Step 1 (Execute Command).

If service is NOT running, continue with bootstrap steps 0.2-0.5.

#### 0.2: Check GitHub CLI Authentication

```bash
gh auth status
```

If not authenticated:
```
❌ Not logged into GitHub CLI.

Run: gh auth login
```
Stop and wait for user to authenticate.

#### 0.3: Clone or Update the Repository

Check if the repo exists:

```bash
ls ~/.convos-qa/convos-ai/package.json 2>/dev/null
```

If repo doesn't exist, clone it:
```bash
mkdir -p ~/.convos-qa
gh repo clone xmtplabs/convos-ai ~/.convos-qa/convos-ai
```

If repo exists, pull latest:
```bash
cd ~/.convos-qa/convos-ai && git pull
```

#### 0.4: Check for OPENAI_API_KEY

Check if `~/.convos-qa/.env` exists and contains `OPENAI_API_KEY`:

```bash
grep -s "^OPENAI_API_KEY=" ~/.convos-qa/.env | cut -d'=' -f2
```

If empty or file doesn't exist, ask the user:
```
🔑 OpenAI API key required for AI-generated conversations.

Enter your OpenAI API key (starts with sk-):
```

Save the key:
```bash
mkdir -p ~/.convos-qa
echo "OPENAI_API_KEY=<user-provided-key>" > ~/.convos-qa/.env
```

#### 0.5: Install Dependencies, Build, and Start the Service

Install dependencies, build TypeScript, and start the service:

```bash
cd ~/.convos-qa/convos-ai

# Install dependencies if node_modules doesn't exist or package.json changed
if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules" ]; then
  npm install
fi

# Build TypeScript if dist doesn't exist or src changed
if [ ! -d "dist" ] || [ -n "$(find src -newer dist -name '*.ts' 2>/dev/null | head -1)" ]; then
  npm run build
fi

# Load environment and start service in background
source ~/.convos-qa/.env
export OPENAI_API_KEY
export XMTP_ENV=dev
nohup npm start > ~/.convos-qa/convos-agents.log 2>&1 &
echo $! > ~/.convos-qa/convos-agents.pid
```

Wait for health check:
```bash
for i in {1..30}; do
  if curl -s http://localhost:3000/health | grep -q '"status":"ok"'; then
    echo "✅ convos-agents is ready"
    break
  fi
  sleep 1
done
```

**Note:** First startup may take ~60 seconds while generating DALL-E avatars.

After setup completes successfully, inform the user:
```
✅ QA service is running!

You can also use the web dashboard at: http://localhost:3000

The dashboard lets you:
- Create stress test conversations
- View and manage running agents
- Monitor message activity
```

### Step 1: Parse Intent and Execute

Parse the user's natural language to determine:

| Signal | Look for | Default |
|--------|----------|---------|
| **Member count** | Numbers like "5 members", "with 10", etc. | 5 |
| **Topic/theme** | "about X", "talking about X", quoted text | None (AI generates) |
| **Join in simulator** | "join in simulator", "join in sim", "and join", "open in app" | No |
| **Invite URL** | URLs containing `convos.app` or invite slugs | None |
| **Status check** | "status", "what's running", "list", "agents" | - |
| **Stop agent** | "stop", "kill", "end" + agent ID | - |
| **Update service** | "update", "upgrade", "pull latest" | - |

Then execute the matching action:

#### Intent: Create new conversation

```bash
curl -s -X POST http://localhost:3000/api/stress-test \
  -H "Content-Type: application/json" \
  -d '{"memberCount": N, "customPrompt": "topic"}'
```

Response format:
```
✅ Created stress test conversation

**Invite URL:** https://convos.app/v2?i=abc123
**Group Name:** AI-generated name
**Members:** Alice, Bob, Charlie

Paste this URL in the Convos app. Fake members will start messaging automatically.
```

**If user wants to join in simulator:** After creating the conversation, proceed to Step 2.

#### Intent: Add members to existing conversation

Extract the invite slug from the URL (the `i=` parameter) and call:

```bash
curl -s -X POST http://localhost:3000/api/stress-test/join \
  -H "Content-Type: application/json" \
  -d '{"inviteSlug": "extracted-slug", "memberCount": N}'
```

Response format:
```
✅ Joined conversation with N fake members

**Agent ID:** stress-test-xyz
**Members added:** Alice, Bob, Charlie

Fake members will start messaging automatically.
```

#### Intent: Check status

```bash
curl -s http://localhost:3000/api/agents
```

Response format:
```
**Running Agents (2):**

stress-test-abc123
  - Status: active
  - Members: 5
  - Messages remaining: 15
  - Created: 2024-01-15 10:30 AM

stress-test-xyz789
  - Status: paused
  - Members: 3
  - Created: 2024-01-15 09:15 AM
```

If no agents:
```
No running agents.

Use `/qa new convo with 5 members` to create a test conversation.
```

#### Intent: Stop agent

```bash
curl -s -X POST http://localhost:3000/api/agents/<agent-id>/stop
```

Response format:
```
✅ Stopped agent: <agent-id>
```

#### Intent: Update service

Pull the latest changes, rebuild, and restart the service:

```bash
# 1. Stop the running service
kill $(cat ~/.convos-qa/convos-agents.pid) 2>/dev/null

# 2. Pull latest changes
cd ~/.convos-qa/convos-ai && git pull

# 3. Reinstall dependencies if package.json changed
npm install

# 4. Rebuild TypeScript
npm run build

# 5. Restart the service
source ~/.convos-qa/.env
export OPENAI_API_KEY
export XMTP_ENV=dev
nohup npm start > ~/.convos-qa/convos-agents.log 2>&1 &
echo $! > ~/.convos-qa/convos-agents.pid
```

Wait for health check:
```bash
for i in {1..30}; do
  if curl -s http://localhost:3000/health | grep -q '"status":"ok"'; then
    echo "✅ convos-agents updated and ready"
    break
  fi
  sleep 1
done
```

Response format:
```
✅ Updated convos-agents service

Changes pulled from git and service restarted.
Web dashboard: http://localhost:3000
```

### Step 2: Join in Simulator

If the user wants to join in the simulator (detected phrases like "join in simulator", "join in sim", "and join it", "open in app"), automatically join the conversation after creating it.

#### 2.1: Get Simulator ID

Read the simulator ID from `.claude/.simulator_id`:

```bash
cat .claude/.simulator_id
```

If the file doesn't exist, inform the user to run `/build --run` first to launch the app.

#### 2.2: Ensure Simulator is Booted

Use the XcodeBuildMCP tool to boot the simulator:

```
mcp__XcodeBuildMCP__session-set-defaults with simulatorId from step 2.1
mcp__XcodeBuildMCP__boot_sim
```

#### 2.3: Copy Invite URL to Simulator Clipboard

Copy the invite URL to the **simulator's** clipboard (not the Mac clipboard):

```bash
xcrun simctl pbcopy <SIMULATOR_ID> <<< "<INVITE_URL>"
```

Example:
```bash
xcrun simctl pbcopy 17795D3B-A34E-4FB9-88B4-1F25B7AFA7CD <<< "https://convos.app/v2?i=abc123"
```

#### 2.4: Navigate to Join Flow

Use `mcp__XcodeBuildMCP__describe_ui` to get the current screen state.

**If on Home screen (shows "New conversation" and "or join one"):**
1. Find and tap the "or join one" button using `mcp__XcodeBuildMCP__tap`

**If on Join screen (shows "Paste an invite link"):**
1. Proceed to step 2.5

**If on another screen:**
1. Look for navigation options to get to the join flow
2. Or inform the user to navigate to the home screen manually

#### 2.5: Paste the Invite URL

1. Use `describe_ui` to find the clipboard paste button (usually shows a clipboard icon)
2. Tap the clipboard button to paste the invite URL

#### 2.6: Handle Paste Permission

iOS will show a permission dialog: "Convos would like to paste from CoreSimulatorBridge"

1. Use `describe_ui` to find the "Allow Paste" button
2. Tap "Allow Paste" to grant permission

#### 2.7: Verify Join Success

1. Wait 1-2 seconds for the join to complete
2. Use `mcp__XcodeBuildMCP__screenshot` to capture the result
3. Confirm the conversation was joined successfully

Response format when joining in simulator:
```
✅ Created and joined stress test conversation

**Group Name:** AI-generated name
**Members:** Alice, Bob, Charlie

The conversation is now open in the Simulator. Fake members will start messaging automatically.
```

## Error Handling

### Service Not Starting

If the service fails to start:
```
❌ Failed to start convos-agents service.

Check logs: cat ~/.convos-qa/convos-agents.log
```

### API Not Responding

If API calls fail after service should be running:
```
❌ convos-agents API not responding.

Try restarting:
1. Kill existing process: kill $(cat ~/.convos-qa/convos-agents.pid) 2>/dev/null
2. Run /qa setup to restart the service
Check logs: tail -50 ~/.convos-qa/convos-agents.log
```

### Invalid API Key

If stress test creation fails with auth error:
```
❌ OpenAI API key invalid or expired.

Update your key:
1. Get a new key from https://platform.openai.com/api-keys
2. Run: echo "OPENAI_API_KEY=sk-..." > ~/.convos-qa/.env
3. Restart service: kill $(cat ~/.convos-qa/convos-agents.pid) && run /qa setup
```

## Examples

**Create a basic test conversation:**
```
User: /qa give me a convo with 5 members
Claude: [Checks container, creates stress test]
        ✅ Created stress test conversation
        **Invite URL:** https://convos.app/v2?i=abc123
        ...
```

**Create a themed conversation:**
```
User: /qa 8 people talking about planning a surprise birthday party
Claude: [Creates stress test with custom prompt]
        ✅ Created stress test conversation
        **Invite URL:** https://convos.app/v2?i=xyz789
        **Group Name:** Birthday Planning Committee
        ...
```

**Check running agents:**
```
User: /qa what's running?
Claude: **Running Agents (1):**
        stress-test-abc123
          - Status: active
          - Members: 5
          ...
```

**Create and automatically join in simulator:**
```
User: /qa join in the simulator a convo with 5 members
Claude: [Creates stress test, copies invite to simulator clipboard,
        navigates to join flow, pastes URL, handles permission dialog]

        ✅ Created and joined stress test conversation

        **Group Name:** Weekend Hikers
        **Members:** Alex, Jordan, Sam, Riley, Morgan

        The conversation is now open in the Simulator.
```

## Cleanup

To stop the service:
```bash
kill $(cat ~/.convos-qa/convos-agents.pid) 2>/dev/null
```

To completely reset the QA environment:
```bash
kill $(cat ~/.convos-qa/convos-agents.pid) 2>/dev/null
rm -rf ~/.convos-qa
```
