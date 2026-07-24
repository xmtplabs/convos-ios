# Agent DMs - Local QA Sequence

A repeatable procedure to verify the agent-DM feature end to end on the local
stack: create an agent, confirm it joins, DM it, and confirm the DM attaches,
stays, is deduplicated, and routes replies to the DM channel.

Most failures we hit during development were **stale state**, not code: a warm
Durable Object running old code, orphaned DM-registry rows holding a peer's
single-DM slot, and client-side marker flips. This runbook front-loads a clean
slate so a failure means a real regression, not accumulated cruft.

## 0. Identifiers (run once per session)

Everything below uses these. Paste into your shell.

```bash
# Booted simulator + its most-recently-written client DB
SIM=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
DB=$(find ~/Library/Developer/CoreSimulator/Devices/$SIM/data/Containers/Shared/AppGroup \
  -name convos-single-inbox.sqlite -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

# Backend paths
DODIR=~/xmtplabs/convos-assistants/workers/assistant/.wrangler/state/v3/do/convos-assistants-local-dev-Assistant
WORKERLOG=~/xmtplabs/.run/worker.log
HERALDLOG=~/xmtplabs/.run/herald.log

# Your current app inbox (the "peer" the agent sees). Note it - DMs are keyed by this.
ME=$(sqlite3 "$DB" "SELECT inboxId FROM inbox;")
echo "SIM=$SIM"; echo "DB=$DB"; echo "ME=$ME"
```

If `ME` is empty the app has no authorized inbox yet - finish onboarding on the
sim first.

## 1. Prerequisites

1. **Stack is up.** `herald`, `worker`, `backend`, and the XMTP node running.
   ```bash
   curl -s -o /dev/null -w "worker %{http_code}\n" http://localhost:8787/
   docker ps --format '{{.Names}}' | grep -E "node|minio|convos_db" | head
   ```
2. **The worker is running current code.** This is the one that bit us: a warm,
   actively-processing Durable Object keeps running the **old** module across a
   `wrangler dev` hot-reload. If you changed anything under
   `workers/assistant/src`, restart the worker so the DO reloads:
   ```bash
   pkill -f "wrangler.*convos-assistants-local-dev"
   (cd ~/xmtplabs/convos-assistants/workers/assistant && nohup pnpm dev > "$WORKERLOG" 2>&1 &)
   # wait for readiness
   until curl -s -o /dev/null http://localhost:8787/; do sleep 1; done; echo ready
   ```
   This drops any in-flight agent turn - fine for QA, avoid mid-demo.
3. **Correct client build installed** on the sim (Convos (Local)).

## 2. Clean slate

Accumulated DM-registry rows from prior runs will make a fresh DM look broken
(the agent leaves it as a "duplicate"). Start clean.

**Preferred: use a fresh agent.** Create a brand-new agent for the test (Section
3) rather than reusing one that already has DM history. A new agent instance has
an empty registry.

**If reusing an agent**, clear its stale slot-holding rows for your peer. This is
what the `cleanupStalePeerDms` code does automatically once the new code is live;
do it by hand only when testing against a warm/old DO:

```bash
for f in "$DODIR"/*.sqlite; do
  [ "$(basename "$f")" = metadata.sqlite ] && continue
  n=$(sqlite3 "$f" "SELECT count(*) FROM dm_conversation
       WHERE lower(peer_inbox_id)=lower('$ME') AND status IN ('active','pending');" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != 0 ] && \
    echo "$(basename "$f" | cut -c1-10): $(sqlite3 "$f" "DELETE FROM dm_conversation
      WHERE lower(peer_inbox_id)=lower('$ME') AND status IN ('active','pending'); SELECT changes();")"
done
echo "cleared"
```

Optionally note pre-existing ghost DMs so you can tell new from old:
```bash
sqlite3 -header -column "$DB" "SELECT substr(id,1,10) id, isAgentDm, conversationEmoji e,
  (SELECT count(*) FROM conversation_members m WHERE m.conversationId=c.id) mem
  FROM conversation c WHERE isAgentDm=1;"
```

## 3. Test A - Create an agent and confirm it joins

**Do on sim:** tap **Make an agent** -> enter a brief (e.g. "Plan a NOLA trip")
-> submit. Wait for "Activating" to finish.

**Expect on sim:** the agent card stops "Activating"; the agent appears as a
member and greets you.

**Verify (DB):** the builder conversation reaches **2 members** with the agent
present, and it is **not** classified as a DM.
```bash
sqlite3 -header -column "$DB" "SELECT substr(c.id,1,10) id, c.isAgentDm ad,
  (SELECT count(*) FROM conversation_members m WHERE m.conversationId=c.id) mem,
  (SELECT substr(group_concat(p.name),1,20) FROM conversation_members m
     JOIN profile p ON p.inboxId=m.inboxId
     WHERE m.conversationId=c.id AND p.memberKind LIKE 'agent%') agent
  FROM conversation c ORDER BY c.createdAt DESC LIMIT 3;"
```
Pass: newest row has `mem=2`, `ad=0`, a non-null `agent`.

Fail signature: `mem=1` (agent never joined). Check the worker log for the join
workflow, and confirm the worker was restarted (step 1.2).

## 4. Test B - Agent responds in the group

**Do on sim:** send a message in the group/builder conversation.

**Expect:** the agent replies in that conversation, and you see thinking/read
receipts.

**Verify (log):**
```bash
grep -E "conversation/[0-9a-f]+/messages|turn-end|delivery-complete" "$WORKERLOG" | tail -5
```

## 5. Test C - DM the agent (the feature under test)

**Do on sim:** open the group -> swipe to the agent's **DM pager page** (the dot
next to Messages) -> send the first message.

**Expect on sim:**
- A DM transcript opens (disclosure cell + your message).
- The agent joins the DM and replies **in the DM**, not in the group.
- The DM does **not** appear as a row in the main conversations list.

**Verify 1 - client created one 2-member DM, classified and hidden:**
```bash
sqlite3 -header -column "$DB" "SELECT substr(id,1,10) id, isAgentDm ad,
  (SELECT count(*) FROM conversation_members m WHERE m.conversationId=c.id) mem,
  datetime(createdAt) created
  FROM conversation c WHERE isAgentDm=1 ORDER BY createdAt DESC LIMIT 3;"
```
Pass: exactly one new `ad=1` row, `mem=2` (you + agent).

**Verify 2 - backend attached (did not leave):**
```bash
grep -E "agent-dm (attached|attach failed|duplicate|cleanup|denied)" "$WORKERLOG" | tail -8
```
Pass: `agent-dm attached`.
Fail: `duplicate (peer already has an active DM); leaving` -> a slot-holding row
blocked it (see Troubleshooting).

**Verify 3 - registry has exactly one active row for your peer:**
```bash
for f in "$DODIR"/*.sqlite; do [ "$(basename "$f")" = metadata.sqlite ] && continue
  r=$(sqlite3 "$f" "SELECT group_concat(substr(conversation_id,1,8)||':'||status,', ')
       FROM dm_conversation WHERE lower(peer_inbox_id)=lower('$ME');" 2>/dev/null)
  [ -n "$r" ] && echo "$(basename "$f" | cut -c1-10): $r"; done
```
Pass: one `...:active` for your peer. No lingering `pending`, no second `active`.

**Verify 4 - reply routed to the DM, not the group:** confirm on the sim the
reply is in the DM page. In the log, the reply's conversation id should be the DM
id from Verify 1, not the group id.

## 6. Test D - Dedup (no duplicate DM)

**Do on sim:** from the same group, try to open/create a DM with the same agent
again (swipe back to the DM page and send).

**Expect:** you land in the **same** DM; no new conversation is created.

**Verify:** the `ad=1 mem=2` count for this agent stays at **1**; no new ghost
`ad=1 mem=1` rows appear.
```bash
sqlite3 "$DB" "SELECT count(*) FROM conversation WHERE isAgentDm=1;"
```

## 7. Pass criteria (all must hold)

- Agent creation reaches `mem=2` and greets you (Test A).
- Agent replies in the group (Test B).
- First DM: one `ad=1 mem=2` DM, `agent-dm attached` in the log, DM hidden from
  the list, reply in the DM channel (Test C).
- Registry: exactly one `active` row for your peer, no `pending`, no duplicates
  (Test C, Verify 3).
- No duplicate DM or ghost `mem=1` rows on re-open (Test D).

## 8. Troubleshooting - known failure signatures

| Symptom | Log / state | Cause | Fix |
|---|---|---|---|
| Agent stuck "Activating", DM/group at `mem=1` | no `agent-dm attached`; builder workflow incomplete | agent-creation join interrupted (often a worker reload mid-workflow) | restart worker (1.2), recreate agent |
| Agent joins DM then leaves; DM ends at `mem=1` | `duplicate (peer already has an active DM); leaving` | a stale `active`/`pending` registry row holds the peer's single-DM slot | clear rows (Section 2); permanently fixed by `cleanupStalePeerDms` once the DO runs current code |
| Same as above but no `cleanup` log lines after restart | rows unchanged after a DM attempt | DO warm on **old** code | restart worker (1.2) so the DO reloads |
| DM shows up in the main conversations list | client `isAgentDm=0` on a real 2-member DM | on-wire marker transiently rewritten; client re-derives `isAgentDm=false` | client classification robustness (tracked); one-way latch keeps a once-classified DM hidden |
| Client keeps creating new DMs for one agent | `findAgentDm` returns nil because the existing DM's agent left, or its marker flipped | client can't find its own DM, so it makes another | backend keeps one DM alive (dedup); client reconciler + classification fix (tracked) |

## 9. Registry reference

`dm_conversation` rows live in the per-agent DO SQLite under `$DODIR`. Each row:
`conversation_id`, `peer_inbox_id`, `status` (`pending` -> `active`, or
`revoked`). Invariant: **at most one `active`/`pending` row per peer**. More than
one, or a row whose conversation is not a live 2-member group containing the
agent, is stale and blocks new DMs until cleaned.

Dump everything for a peer:
```bash
for f in "$DODIR"/*.sqlite; do [ "$(basename "$f")" = metadata.sqlite ] && continue
  sqlite3 "$f" "SELECT '$(basename "$f" | cut -c1-8)', substr(conversation_id,1,10),
    substr(peer_inbox_id,1,10), status FROM dm_conversation
    WHERE lower(peer_inbox_id)=lower('$ME');" 2>/dev/null; done | column -t
```
