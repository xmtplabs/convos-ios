import { mkdirSync, readFileSync, renameSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { LoadTestConfig } from './config.js';

// Per-group lifecycle. Each transition is checkpointed so `--resume` can skip
// completed work: created -> phone-added (welcome landed) -> backfilled -> churning.
export type GroupState = 'planned' | 'created' | 'phone-added' | 'backfilled' | 'churning' | 'failed';

export interface GroupRecord {
  index: number;
  name: string;
  state: GroupState;
  conversationId?: string;
  // VU indices that are non-phone members of this group (creator is the controller).
  memberVus: number[];
  targetMembers: number;
  // How the phone was enrolled. `direct` = addMembers/createGroup-with-member
  // (adder-vouching); `invite` = fallback join path when direct didn't promote.
  enrollPath?: 'direct' | 'invite';
  backfill: { planned: number; sent: number; lastMessageId?: string };
  error?: string;
}

export interface VuRecord {
  index: number;
  home: string;
  role: 'controller' | 'creator' | 'member' | 'agent';
  inboxId?: string;
}

export interface Manifest {
  runId: string;
  preset: string;
  seed: number;
  env: string;
  createdAt: string;
  phaseCursor: 'provision' | 'bootstrap' | 'create' | 'enroll' | 'backfill' | 'churn' | 'done';
  device: {
    inboxId: string | null;
    bootstrapConversationId?: string;
    controllerInboxId?: string;
    pairedAt?: string;
  };
  vus: VuRecord[];
  groups: GroupRecord[];
  counters: {
    messagesSent: number;
    reactionsSent: number;
    membersAdded: number;
  };
  config: LoadTestConfig;
}

export function manifestPath(runDir: string): string {
  return join(runDir, 'manifest.json');
}

export function loadManifest(runDir: string): Manifest | undefined {
  const path = manifestPath(runDir);
  if (!existsSync(path)) return undefined;
  return JSON.parse(readFileSync(path, 'utf8')) as Manifest;
}

// Atomic write: serialize to a sibling tmp file then rename, so a crash mid-write
// never leaves a truncated manifest. The manifest is the resume ground truth.
export function saveManifest(runDir: string, manifest: Manifest): void {
  const path = manifestPath(runDir);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(manifest, null, 2));
  renameSync(tmp, path);
}

export function newManifest(args: {
  runId: string;
  preset: string;
  runDir: string;
  config: LoadTestConfig;
  createdAt: string;
}): Manifest {
  return {
    runId: args.runId,
    preset: args.preset,
    seed: args.config.seed,
    env: args.config.env,
    createdAt: args.createdAt,
    phaseCursor: 'provision',
    device: { inboxId: args.config.device.inboxId },
    vus: [],
    groups: [],
    counters: { messagesSent: 0, reactionsSent: 0, membersAdded: 0 },
    config: args.config,
  };
}
