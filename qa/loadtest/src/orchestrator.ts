import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import type { LoadTestConfig } from './config.js';
import { LibraryDriver } from './driver/libraryDriver.js';
import { loadManifest, newManifest, type Manifest } from './manifest.js';
import { Rng } from './rng.js';
import { makeContext } from './phases/context.js';
import { provision } from './phases/provision.js';
import { bootstrap } from './phases/bootstrap.js';
import { create } from './phases/create.js';
import { enroll } from './phases/enroll.js';
import { backfill } from './phases/backfill.js';
import { churn } from './phases/churn.js';
import { teardown } from './phases/teardown.js';
import { nowIso } from './util.js';

// Package-relative so runs land in qa/loadtest/runs regardless of cwd.
export const RUNS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'runs');

const PHASE_ORDER = ['provision', 'bootstrap', 'create', 'enroll', 'backfill', 'churn'] as const;
export type PhaseName = (typeof PHASE_ORDER)[number];

export function runDirFor(runId: string): string {
  return join(RUNS_DIR, runId);
}

export interface RunOptions {
  preset: string;
  config: LoadTestConfig;
  runId: string;
  resume: boolean;
  phaseUntil?: PhaseName;
}

export async function runLoadTest(opts: RunOptions): Promise<Manifest> {
  const runDir = runDirFor(opts.runId);
  mkdirSync(runDir, { recursive: true });

  const manifest = opts.resume
    ? loadManifest(runDir) ?? newManifest({ runId: opts.runId, preset: opts.preset, runDir, config: opts.config, createdAt: nowIso() })
    : newManifest({ runId: opts.runId, preset: opts.preset, runDir, config: opts.config, createdAt: nowIso() });

  // On resume, honor any --set overrides passed this invocation (e.g. enabling
  // churn on a run that was only backfilled) while keeping all other run state.
  if (opts.resume) manifest.config = opts.config;

  const rng = new Rng(manifest.config.seed);
  const driver = new LibraryDriver(manifest.config.env, manifest.config.upload);
  const ctx = makeContext({ config: manifest.config, rng, driver, runDir, manifest });

  const until = opts.phaseUntil ? PHASE_ORDER.indexOf(opts.phaseUntil) : PHASE_ORDER.length - 1;

  try {
    // Phases self-skip completed work via manifest state, so running them in
    // order is inherently resume-safe.
    provision(ctx);
    if (until >= PHASE_ORDER.indexOf('bootstrap')) await bootstrap(ctx);
    if (until >= PHASE_ORDER.indexOf('create')) await create(ctx);
    if (until >= PHASE_ORDER.indexOf('enroll')) await enroll(ctx);
    if (until >= PHASE_ORDER.indexOf('backfill')) await backfill(ctx);
    if (until >= PHASE_ORDER.indexOf('churn')) await churn(ctx);
  } finally {
    await driver.closeAll();
  }

  return manifest;
}

// Standalone teardown: remove the phone from every group of a prior run.
export async function runTeardown(runId: string): Promise<Manifest> {
  const runDir = runDirFor(runId);
  const manifest = loadManifest(runDir);
  if (!manifest) throw new Error(`no manifest for run ${runId}`);
  const rng = new Rng(manifest.config.seed);
  const driver = new LibraryDriver(manifest.config.env, manifest.config.upload);
  const ctx = makeContext({ config: manifest.config, rng, driver, runDir, manifest });
  try {
    await teardown(ctx);
  } finally {
    await driver.closeAll();
  }
  return manifest;
}
