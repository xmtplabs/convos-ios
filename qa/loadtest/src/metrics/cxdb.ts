import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { promisify } from 'node:util';
import type { MetricSummary } from './perfIngest.js';

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
// qa/loadtest/src/metrics -> qa/cxdb/cxdb.sh
const CXDB_SH = resolve(here, '..', '..', '..', 'cxdb', 'cxdb.sh');

// Default per-metric targets (ms), mirroring QA test 15's budgets. A metric not
// listed gets no target (0 = informational).
const TARGETS: Record<string, number> = {
  'sync.all_conversations': 3000,
  'catchup.batch.messages': 1000,
  'message.process': 200,
  'ConversationViewModel.init': 100,
  'conversations.list.render': 500,
  'NewConversation.joinRequestSent': 5000,
};

export function cxdbAvailable(): boolean {
  return existsSync(CXDB_SH);
}

// Push each metric's median into CXDB's perf_measurements via the shared helper,
// so `cxdb.sh report-md <runId>` and `cxdb.sh compare <old> <new>` work across runs.
export async function logToCxdb(runId: string, summaries: MetricSummary[]): Promise<void> {
  if (!cxdbAvailable()) {
    console.warn(`[cxdb] helper not found at ${CXDB_SH}; skipping CXDB logging`);
    return;
  }
  for (const s of summaries) {
    const target = TARGETS[s.metric] ?? 0;
    await execFileAsync('bash', [CXDB_SH, 'log-perf', runId, 'loadtest', s.metric, String(Math.round(s.median)), String(target)]);
  }
}
