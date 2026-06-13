export const meta = {
  name: 'qa-run',
  description: 'Run Convos iOS QA: a qa-runner over the main sequential chunk on the primary simulator, optionally with migration (test 13) in parallel on its own simulator. Parameterized by args so the same script runs a focused validation or the full suite.',
  phases: [{ title: 'QA', detail: 'qa-runner per chunk (main sequence + optional migration)' }],
}

// args: {
//   runId: string,            // CXDB run id (created by the caller via cxdb.sh new-run)
//   udid: string,             // primary simulator UDID
//   simulatorName?: string,   // primary simulator name (for the runner's logs)
//   mainChunk: string[],      // ordered test ids to run on the primary sim, e.g. ["39","32"]
//   runMigration?: boolean,   // also run test 13 on its own isolated simulator, in parallel
// }
let a = args || {}
// Defensive: args can arrive JSON-encoded (a string) depending on how the
// caller passes it; parse it so both an object and a stringified object work.
if (typeof a === 'string') {
  try { a = JSON.parse(a) } catch (_) { a = {} }
}
const runId = a.runId
const udid = a.udid
const simName = a.simulatorName || ''
const mainChunk = Array.isArray(a.mainChunk) ? a.mainChunk : []
const runMigration = a.runMigration === true

if (!runId || !udid) {
  throw new Error('qa-run requires args.runId and args.udid (create the CXDB run first via qa/cxdb/cxdb.sh new-run)')
}
if (mainChunk.length === 0 && !runMigration) {
  throw new Error('qa-run requires a non-empty args.mainChunk or args.runMigration=true')
}

function runnerPrompt(ids, sharedSim, extraNote) {
  return [
    `You are executing QA test(s) ${JSON.stringify(ids)} for run ${runId}.`,
    ``,
    `Inputs:`,
    `- test_ids: ${JSON.stringify(ids)}`,
    `- run_id: "${runId}"`,
    `- udid: "${udid}"`,
    `- simulator_name: "${simName}"`,
    ``,
    `Follow the instructions in your agent definition. For each id, read`,
    `qa/tests/structured/<id>-*.yaml, translate actions via qa/TOOLS-CLAUDE.md`,
    `and qa/RULES.md, record every criterion + state to CXDB (qa/cxdb/cxdb.sh)`,
    `under run ${runId}, then move to the next id in order.`,
    sharedSim
      ? `These tests share the primary simulator and CXDB run state; run them strictly in order on udid ${udid}.`
      : `Test ${ids.join(',')} creates and runs on its OWN isolated simulator per the YAML; do not touch the primary simulator (${udid}).`,
    `A test marked "blocked: true" in its YAML should be recorded as skipped (not failed) with its blocked_reason.`,
    extraNote || '',
    `Return the compact chunk summary when done.`,
  ].filter(Boolean).join('\n')
}

phase('QA')

const lanes = []
if (mainChunk.length > 0) {
  lanes.push(() => agent(
    runnerPrompt(mainChunk, true),
    { label: `qa:main[${mainChunk.join(',')}]`, phase: 'QA', agentType: 'qa-runner' }
  ))
}
if (runMigration) {
  lanes.push(() => agent(
    runnerPrompt(['13'], false),
    { label: 'qa:migration[13]', phase: 'QA', agentType: 'qa-runner' }
  ))
}

// At most two lanes (main + migration) to avoid simulator / CXDB contention.
const results = await parallel(lanes)
const summaries = results.filter(Boolean)

log(`QA chunks complete: ${summaries.length}/${lanes.length} lane(s) returned for run ${runId}`)
return { runId, mainChunk, runMigration, chunks: summaries }
