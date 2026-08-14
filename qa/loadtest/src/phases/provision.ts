import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { groupName } from '../content/corpus.js';
import type { GroupRecord, VuRecord } from '../manifest.js';
import { homeDir } from '../util.js';
import type { RunContext } from './context.js';

// Build the deterministic plan: VU registry (controller + member pool) and the
// per-group plan (name + target member count sampled from the size distribution).
// Idempotent — re-running with the same seed reproduces the same plan, and an
// existing plan (resume) is left untouched.
export function provision(ctx: RunContext): void {
  const { manifest, config, rng } = ctx;
  if (manifest.vus.length > 0 && manifest.groups.length > 0) {
    ctx.log(`resume: ${manifest.vus.length} VUs, ${manifest.groups.length} groups already planned`);
    return;
  }

  mkdirSync(join(ctx.runDir, 'homes'), { recursive: true });

  // Plan groups first so we know how large the member pool must be.
  const weights = config.groups.sizeDistribution.map((b) => b.weight);
  const groups: GroupRecord[] = [];
  let maxMembers = 0;
  for (let i = 0; i < config.groups.count; i++) {
    const bucket = config.groups.sizeDistribution[rng.weightedIndex(weights)]!;
    const target = Math.min(150, rng.resolveRange(bucket.members));
    maxMembers = Math.max(maxMembers, target);
    groups.push({
      index: i,
      name: groupName(rng, i, config.groups.nameLength.min, config.groups.nameLength.max),
      state: 'planned',
      memberVus: Array.from({ length: target }, (_, k) => k + 1), // vu-1..vu-target (reused pool)
      targetMembers: target,
      backfill: { planned: 0, sent: 0 },
    });
  }

  // VU 0 is always the controller (owns the bootstrap group, holds the phone
  // inbox id, does addMembers). VUs 1..maxMembers are the reusable member pool.
  const vus: VuRecord[] = [{ index: 0, home: homeDir(ctx.runDir, 0), role: 'controller' }];
  for (let i = 1; i <= maxMembers; i++) {
    vus.push({ index: i, home: homeDir(ctx.runDir, i), role: 'member' });
  }

  manifest.vus = vus;
  manifest.groups = groups;
  manifest.phaseCursor = 'bootstrap';
  ctx.save();
  ctx.log(`planned ${groups.length} groups, member pool size ${maxMembers}`);
}
