import { parseArgs } from 'node:util';
import { readFileSync } from 'node:fs';
import { parse as parseYaml } from 'yaml';
import { applyOverrides, ConfigSchema, loadPreset, PRESETS_DIR } from './config.js';
import { resolve } from 'node:path';
import { loadManifest, type Manifest } from './manifest.js';
import { runDirFor, runLoadTest, runTeardown, type PhaseName } from './orchestrator.js';
import { ingestLog, summarize, parsePerfLog } from './metrics/perfIngest.js';
import { logToCxdb } from './metrics/cxdb.js';

function usage(): void {
  console.log(`convos-loadtest

Usage:
  loadtest run --preset <light|medium|heavy|extreme> [--env dev|local] [--invite-url URL] [--set k.v=x ...] [--run-id ID] [--phase-until PHASE]
  loadtest resume --run-id ID [--invite-url URL] [--phase-until PHASE]
  loadtest status --run-id ID
  loadtest teardown --run-id ID
  loadtest report --run-id ID --log <path-to-exported-convos.log> [--no-cxdb]

Phases: provision, bootstrap, create, enroll, backfill, churn
  (churn is the sustained spam engine; it runs for churn.durationMin, or until
   Ctrl-C when durationMin=0. Use --phase-until backfill to stop before it.)

Bootstrap: by default the controller shows a QR for the phone to scan. Pass
  --invite-url with an invite generated in the app to join it instead (no scan).
Presets live in ${PRESETS_DIR}. Runs are stored under qa/loadtest/runs/<run-id>/.`);
}

function defaultRunId(preset: string): string {
  // Deterministic-ish id without Date dependency at module load; uses wall clock
  // only here at invocation time (fine — the manifest records createdAt anyway).
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12);
  return `loadtest-${preset}-${stamp}`;
}

async function main(): Promise<void> {
  const command = process.argv[2];
  const { values } = parseArgs({
    args: process.argv.slice(3),
    options: {
      preset: { type: 'string' },
      env: { type: 'string' },
      'invite-url': { type: 'string' },
      set: { type: 'string', multiple: true },
      'run-id': { type: 'string' },
      'phase-until': { type: 'string' },
      log: { type: 'string' },
      'no-cxdb': { type: 'boolean' },
      help: { type: 'boolean', short: 'h' },
    },
    allowPositionals: false,
  });

  if (!command || command === 'help' || values.help) {
    usage();
    return;
  }

  const phaseUntil = values['phase-until'] as PhaseName | undefined;

  if (command === 'run') {
    const preset = values.preset;
    if (!preset) throw new Error('run requires --preset');
    const sets = [...(values.set ?? [])];
    if (values.env) sets.push(`env=${JSON.stringify(values.env)}`);
    if (values['invite-url']) sets.push(`device.inviteUrl=${JSON.stringify(values['invite-url'])}`);
    const rawConfig = parseYaml(readFileSync(preset.includes('/') || preset.endsWith('.yaml') ? preset : resolve(PRESETS_DIR, `${preset}.yaml`), 'utf8'));
    const config = sets.length ? applyOverrides(rawConfig, sets) : ConfigSchema.parse(rawConfig);
    const runId = (values['run-id'] as string) ?? defaultRunId(preset);
    console.log(`run ${runId} — preset ${preset}, env ${config.env}, seed ${config.seed}, ${config.groups.count} groups`);
    const manifest = await runLoadTest({ preset, config, runId, resume: false, phaseUntil });
    printSummary(runId, manifest);
    return;
  }

  if (command === 'resume') {
    const runId = values['run-id'] as string;
    if (!runId) throw new Error('resume requires --run-id');
    const existing = loadManifest(runDirFor(runId));
    if (!existing) throw new Error(`no manifest for run ${runId}`);
    // Allow tuning churn/rate axes on resume (e.g. enable churn on a run that
    // was backfilled without it), and supplying an invite URL if bootstrap has
    // not completed yet. Env is intentionally not overridable — the homes are
    // already registered on the original network.
    const sets = [...(values.set ?? [])];
    if (values['invite-url']) sets.push(`device.inviteUrl=${JSON.stringify(values['invite-url'])}`);
    const config = sets.length ? applyOverrides(existing.config, sets) : existing.config;
    console.log(`resume ${runId} — cursor ${existing.phaseCursor}${sets.length ? ` (+${sets.length} override${sets.length > 1 ? 's' : ''})` : ''}`);
    const manifest = await runLoadTest({ preset: existing.preset, config, runId, resume: true, phaseUntil });
    printSummary(runId, manifest);
    return;
  }

  if (command === 'teardown') {
    const runId = values['run-id'] as string;
    if (!runId) throw new Error('teardown requires --run-id');
    console.log(`teardown ${runId} — removing the phone from all groups`);
    const manifest = await runTeardown(runId);
    printSummary(runId, manifest);
    return;
  }

  if (command === 'status') {
    const runId = values['run-id'] as string;
    if (!runId) throw new Error('status requires --run-id');
    const m = loadManifest(runDirFor(runId));
    if (!m) throw new Error(`no manifest for run ${runId}`);
    printSummary(runId, m);
    return;
  }

  if (command === 'report') {
    const runId = values['run-id'] as string;
    const logPath = values.log as string;
    if (!runId || !logPath) throw new Error('report requires --run-id and --log');
    const runDir = runDirFor(runId);
    const summaries = loadManifest(runDir) ? ingestLog(runDir, logPath) : summarize(parsePerfLog(readFileSync(logPath, 'utf8')));
    console.log('\nPerf summary (median / p95 / max ms, n samples):');
    for (const s of summaries) {
      console.log(`  ${s.metric.padEnd(34)} ${String(Math.round(s.median)).padStart(7)} / ${String(Math.round(s.p95)).padStart(7)} / ${String(Math.round(s.max)).padStart(7)}   (n=${s.n})`);
    }
    if (!values['no-cxdb']) await logToCxdb(runId, summaries);
    return;
  }

  usage();
  throw new Error(`unknown command: ${command}`);
}

function printSummary(runId: string, m: Manifest): void {
  const byState = new Map<string, number>();
  for (const g of m.groups) byState.set(g.state, (byState.get(g.state) ?? 0) + 1);
  const states = [...byState.entries()].map(([s, n]) => `${s}:${n}`).join('  ');
  console.log(`\nrun ${runId}`);
  console.log(`  cursor        ${m.phaseCursor}`);
  console.log(`  phone inbox   ${m.device.inboxId ? m.device.inboxId.slice(0, 16) + '…' : '(not bootstrapped)'}`);
  console.log(`  groups        ${m.groups.length}  [${states}]`);
  console.log(`  messages sent ${m.counters.messagesSent}`);
  console.log(`  members added ${m.counters.membersAdded}`);
}

main().catch((err) => {
  console.error('\nloadtest failed:', err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
