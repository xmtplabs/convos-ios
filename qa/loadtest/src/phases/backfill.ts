import { join } from 'node:path';
import pLimit from 'p-limit';
import { sendMixedContent } from '../content/send.js';
import { homeDir, sleep } from '../util.js';
import type { RunContext } from './context.js';

// Load each enrolled group with its planned message count using the full content
// mix (text/emoji/link/reply/reaction/attachment). Backfill happens only after
// `phone-added` (the join-before-send rule: messages sent before the phone is a
// member never sync). Resumable via g.backfill.sent.
export async function backfill(ctx: RunContext): Promise<void> {
  const { manifest, config } = ctx;
  const controller = await ctx.driver.open(homeDir(ctx.runDir, 0), config.env);
  const mediaCacheDir = join(ctx.runDir, 'media-cache');
  const hasProvider = ctx.driver.hasUploadProvider();

  const weights = config.backfill.messagesPerGroup.map((b) => b.weight);
  for (const g of manifest.groups) {
    if (g.state === 'phone-added' && g.backfill.planned === 0) {
      const bucket = config.backfill.messagesPerGroup[ctx.rng.weightedIndex(weights)]!;
      g.backfill.planned = ctx.rng.resolveRange(bucket.count);
    }
  }
  ctx.save();

  const targets = manifest.groups.filter((g) => g.state === 'phone-added' && g.backfill.sent < g.backfill.planned);
  if (targets.length === 0) {
    ctx.log('resume: backfill already complete');
    manifest.phaseCursor = 'churn';
    ctx.save();
    return;
  }
  if (!hasProvider && config.backfill.contentMix.attachmentImage > 0) {
    ctx.log('no upload provider configured — image attachments will be sent as text');
  }

  const perGroupDelay = 1000 / config.backfill.rate.perGroupMsgsPerSec;
  const limit = pLimit(config.concurrency);
  await Promise.all(
    targets.map((g) =>
      limit(async () => {
        // Per-group deterministic sub-stream so content is reproducible.
        const gRng = ctx.rng.fork(g.index);
        while (g.backfill.sent < g.backfill.planned) {
          const res = await sendMixedContent({
            rng: gRng,
            config,
            sender: controller,
            controller,
            conversationId: g.conversationId!,
            getLast: () => g.backfill.lastMessageId,
            setLast: (id) => (g.backfill.lastMessageId = id),
            mediaCacheDir,
            hasProvider,
          }).catch((err): null => {
            g.error = `backfill: ${(err as Error).message}`;
            return null;
          });
          if (!res) break;
          g.backfill.sent += res.messages;
          manifest.counters.messagesSent += res.messages;
          manifest.counters.reactionsSent += res.reactions;
          if (g.backfill.sent % 25 === 0) ctx.save();
          await sleep(perGroupDelay * gRng.jitterFactor(config.backfill.rate.jitter));
        }
        if (g.backfill.sent >= g.backfill.planned && g.state === 'phone-added') g.state = 'backfilled';
        ctx.save();
      }),
    ),
  );

  manifest.phaseCursor = 'churn';
  ctx.save();
  const totalSent = manifest.groups.reduce((a, g) => a + g.backfill.sent, 0);
  ctx.log(`backfill complete: ${totalSent} messages across ${targets.length} groups`);
}
