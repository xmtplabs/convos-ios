import { join } from 'node:path';
import pLimit from 'p-limit';
import { displayName, groupName, mediumText } from '../content/corpus.js';
import { sendMixedContent } from '../content/send.js';
import type { LoadTestConfig } from '../config.js';
import type { VuClient } from '../driver/driver.js';
import type { GroupRecord } from '../manifest.js';
import type { Rng } from '../rng.js';
import { homeDir, sleep } from '../util.js';
import type { RunContext } from './context.js';

const TICK_MS = 250;
const SAVE_EVERY_MS = 5000;
const LOG_EVERY_MS = 10_000;
const MAX_INFLIGHT_FACTOR = 8; // backpressure: shed actions past concurrency * this

type ActionStream = 'message' | 'typing' | 'readReceipt' | 'metadata' | 'profile' | 'membership' | 'newGroup';

// Sustained spam engine. A fixed-interval accumulator scheduler converts each
// axis's rate (per-second / per-minute / per-hour) into discrete actions,
// scaled by burst windows, and dispatches them through a bounded concurrency
// pool against zipf-weighted "hot" groups. Runs for churn.durationMin (0 =
// until Ctrl-C). Every action is best-effort: failures are counted, not fatal.
export async function churn(ctx: RunContext): Promise<void> {
  const { manifest, config } = ctx;
  const c = config.churn;
  const noWork = c.aggregateMsgsPerSec <= 0 && c.typingNoisePerMin <= 0 && c.readReceiptsPerMin <= 0 && c.metadataChurnPerHour <= 0 && c.membershipGrowthPerHour <= 0 && config.groups.duringRunPerHour <= 0;
  if (noWork) {
    ctx.log('churn disabled (all churn rates are 0)');
    manifest.phaseCursor = 'done';
    ctx.save();
    return;
  }

  const phoneInboxId = manifest.device.inboxId;
  if (!phoneInboxId) throw new Error('churn requires a bootstrapped phone inbox id');
  const controller = await ctx.driver.open(homeDir(ctx.runDir, 0), config.env);

  // Groups the phone is in become churn targets.
  for (const g of manifest.groups) {
    if ((g.state === 'phone-added' || g.state === 'backfilled') && g.conversationId) g.state = 'churning';
  }
  ctx.save();

  const clientCache = new Map<number, VuClient>();
  const senderFor = async (g: GroupRecord): Promise<VuClient> => {
    const candidates = [0, ...g.memberVus];
    const vu = candidates[ctx.rng.int(0, candidates.length - 1)]!;
    if (vu === 0) return controller;
    let client = clientCache.get(vu);
    if (!client) {
      client = await ctx.driver.open(homeDir(ctx.runDir, vu), config.env);
      clientCache.set(vu, client);
      try {
        await client.sync();
      } catch {
        // fall through; send will fall back to controller on failure
      }
    }
    return client;
  };

  const stats = { fired: 0, failed: 0, shed: 0 };
  const limit = pLimit(config.concurrency);
  const maxInflight = config.concurrency * MAX_INFLIGHT_FACTOR;

  const schedule = (fn: () => Promise<void>): void => {
    if (limit.activeCount + limit.pendingCount >= maxInflight) {
      stats.shed++;
      return;
    }
    void limit(async () => {
      try {
        await fn();
        stats.fired++;
      } catch {
        stats.failed++;
      }
    });
  };

  const start = Date.now();
  const durationMs = c.durationMin > 0 ? c.durationMin * 60_000 : Infinity;
  let stopping = false;
  const onSignal = (): void => {
    if (stopping) process.exit(1);
    stopping = true;
    ctx.log('stopping churn (finishing in-flight actions)…');
  };
  process.on('SIGINT', onSignal);
  process.on('SIGTERM', onSignal);

  const acc: Record<ActionStream, number> = { message: 0, typing: 0, readReceipt: 0, metadata: 0, profile: 0, membership: 0, newGroup: 0 };
  let lastSave = start;
  let lastLog = start;

  ctx.log(`churn started (${c.durationMin > 0 ? c.durationMin + ' min' : 'until Ctrl-C'}, ${c.aggregateMsgsPerSec} msg/s base)`);

  try {
    while (!stopping && Date.now() - start < durationMs) {
      const elapsedMs = Date.now() - start;
      const burst = burstMultiplier(c, elapsedMs);
      const tickSec = TICK_MS / 1000;

      acc.message += c.aggregateMsgsPerSec * burst * tickSec;
      acc.typing += (c.typingNoisePerMin / 60) * tickSec;
      acc.readReceipt += (c.readReceiptsPerMin / 60) * tickSec;
      acc.metadata += (c.metadataChurnPerHour / 3600) * tickSec;
      acc.profile += (c.profileChurnPerHour / 3600) * tickSec;
      acc.membership += (c.membershipGrowthPerHour / 3600) * tickSec;
      acc.newGroup += (config.groups.duringRunPerHour / 3600) * tickSec;

      const targets = churnTargets(manifest.groups);
      const weights = hotColdWeights(targets.length, c.hotGroupFraction);

      while (acc.message >= 1) {
        acc.message -= 1;
        if (targets.length) schedule(() => messageAction(ctx, config, controller, senderFor, pickWeighted(ctx.rng, targets, weights)));
      }
      while (acc.typing >= 1) {
        acc.typing -= 1;
        if (targets.length) {
          const g = pickWeighted(ctx.rng, targets, weights);
          schedule(async () => (await senderFor(g)).sendTyping(g.conversationId!, true).catch(() => controller.sendTyping(g.conversationId!, true)));
        }
      }
      while (acc.readReceipt >= 1) {
        acc.readReceipt -= 1;
        if (targets.length) {
          const g = pickWeighted(ctx.rng, targets, weights);
          schedule(async () => (await senderFor(g)).sendReadReceipt(g.conversationId!).catch(() => controller.sendReadReceipt(g.conversationId!)));
        }
      }
      while (acc.metadata >= 1) {
        acc.metadata -= 1;
        if (targets.length) schedule(() => metadataAction(ctx, controller, pickWeighted(ctx.rng, targets, weights)));
      }
      while (acc.profile >= 1) {
        acc.profile -= 1;
        if (targets.length) schedule(() => profileAction(ctx, config, controller, pickWeighted(ctx.rng, targets, weights)));
      }
      while (acc.membership >= 1) {
        acc.membership -= 1;
        if (targets.length) schedule(() => membershipAction(ctx, config, controller, pickWeighted(ctx.rng, targets, weights)));
      }
      while (acc.newGroup >= 1) {
        acc.newGroup -= 1;
        schedule(() => newGroupAction(ctx, config, controller, phoneInboxId));
      }

      if (Date.now() - lastSave >= SAVE_EVERY_MS) {
        ctx.save();
        lastSave = Date.now();
      }
      if (Date.now() - lastLog >= LOG_EVERY_MS) {
        const secs = (Date.now() - start) / 1000;
        ctx.log(`churn: ${manifest.counters.messagesSent} msgs, ${manifest.counters.reactionsSent} reactions, ${manifest.groups.length} groups, ${(stats.fired / secs).toFixed(1)} act/s${stats.shed ? `, shed ${stats.shed}` : ''}${burst > 1 ? ' [BURST]' : ''}`);
        lastLog = Date.now();
      }

      await sleep(TICK_MS);
    }
  } finally {
    process.off('SIGINT', onSignal);
    process.off('SIGTERM', onSignal);
  }

  // Let in-flight actions settle.
  while (limit.activeCount + limit.pendingCount > 0) await sleep(100);
  manifest.phaseCursor = 'done';
  ctx.save();
  ctx.log(`churn complete: ${manifest.counters.messagesSent} messages, ${manifest.counters.reactionsSent} reactions, ${stats.failed} failed, ${stats.shed} shed`);
}

function burstMultiplier(c: LoadTestConfig['churn'], elapsedMs: number): number {
  if (!c.bursts) return 1;
  const periodMs = c.bursts.everyMin * 60_000;
  const inPeriod = elapsedMs % periodMs;
  return inPeriod < c.bursts.durationS * 1000 ? c.bursts.multiplier : 1;
}

function churnTargets(groups: GroupRecord[]): GroupRecord[] {
  return groups.filter((g) => g.state === 'churning' && g.conversationId);
}

// First ceil(n*fraction) groups collectively receive ~80% of traffic.
function hotColdWeights(n: number, fraction: number): number[] {
  if (n === 0) return [];
  const hot = Math.max(1, Math.ceil(n * fraction));
  const cold = n - hot;
  const hotShare = cold === 0 ? 1 : 0.8;
  const weights: number[] = [];
  for (let i = 0; i < n; i++) weights.push(i < hot ? hotShare / hot : (1 - hotShare) / cold);
  return weights;
}

function pickWeighted(rng: Rng, groups: GroupRecord[], weights: number[]): GroupRecord {
  return groups[rng.weightedIndex(weights)]!;
}

async function messageAction(
  ctx: RunContext,
  config: LoadTestConfig,
  controller: VuClient,
  senderFor: (g: GroupRecord) => Promise<VuClient>,
  g: GroupRecord,
): Promise<void> {
  const sender = await senderFor(g);
  const res = await sendMixedContent({
    rng: ctx.rng,
    config,
    sender,
    controller,
    conversationId: g.conversationId!,
    getLast: () => g.backfill.lastMessageId,
    setLast: (id) => (g.backfill.lastMessageId = id),
    mediaCacheDir: join(ctx.runDir, 'media-cache'),
    hasProvider: ctx.driver.hasUploadProvider(),
  });
  ctx.manifest.counters.messagesSent += res.messages;
  ctx.manifest.counters.reactionsSent += res.reactions;
}

async function metadataAction(ctx: RunContext, controller: VuClient, g: GroupRecord): Promise<void> {
  const cid = g.conversationId!;
  if (ctx.rng.next() < 0.5) {
    const name = groupName(ctx.rng, g.index, ctx.config.groups.nameLength.min, ctx.config.groups.nameLength.max);
    await controller.updateName(cid, name);
    g.name = name;
  } else {
    await controller.updateDescription(cid, mediumText(ctx.rng));
  }
}

async function profileAction(ctx: RunContext, config: LoadTestConfig, controller: VuClient, g: GroupRecord): Promise<void> {
  // Churn a member's own display name (the app re-renders it via ProfileUpdate).
  // Prefer a member VU; fall back to the controller for phone-only groups.
  const cid = g.conversationId!;
  const name = displayName(ctx.rng);
  if (g.memberVus.length === 0) {
    await controller.updateProfile(cid, name);
    return;
  }
  const vuIndex = ctx.rng.pick(g.memberVus);
  const client = await ctx.driver.open(homeDir(ctx.runDir, vuIndex), config.env);
  await client.updateProfile(cid, name).catch(() => controller.updateProfile(cid, name));
}

async function membershipAction(ctx: RunContext, config: LoadTestConfig, controller: VuClient, g: GroupRecord): Promise<void> {
  // Add the next unused member VU from the pool (respecting the 150 cap).
  if (g.memberVus.length >= 150) return;
  const used = new Set(g.memberVus);
  let vuIndex = 1;
  while (used.has(vuIndex)) vuIndex++;
  const home = homeDir(ctx.runDir, vuIndex);
  const client = await ctx.driver.open(home, config.env);
  await controller.addMembers(g.conversationId!, [client.inboxId]);
  g.memberVus.push(vuIndex);
  const vu = ctx.manifest.vus.find((v) => v.index === vuIndex);
  if (!vu) ctx.manifest.vus.push({ index: vuIndex, home, role: 'member', inboxId: client.inboxId });
  else vu.inboxId = client.inboxId;
  ctx.manifest.counters.membersAdded++;
}

async function newGroupAction(ctx: RunContext, config: LoadTestConfig, controller: VuClient, phoneInboxId: string): Promise<void> {
  const index = ctx.manifest.groups.length;
  const name = groupName(ctx.rng, index, config.groups.nameLength.min, config.groups.nameLength.max);
  const { conversationId } = await controller.createGroup(name, []);
  await controller.addMembers(conversationId, [phoneInboxId]);
  ctx.manifest.counters.membersAdded++;
  ctx.manifest.groups.push({
    index,
    name,
    state: 'churning',
    conversationId,
    memberVus: [],
    targetMembers: 0,
    enrollPath: 'direct',
    backfill: { planned: 0, sent: 0 },
  });
}
