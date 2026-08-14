import pLimit from 'p-limit';
import { homeDir } from '../util.js';
import type { RunContext } from './context.js';

// The controller creates each group empty (itself only). The phone and member
// VUs are added in the enroll phase, so the phone lands in the group via an
// addMembers welcome and adder-vouching (the path we're validating). Idempotent:
// groups already `created` (or beyond) are skipped.
export async function create(ctx: RunContext): Promise<void> {
  const { manifest, config } = ctx;
  const controller = await ctx.driver.open(homeDir(ctx.runDir, 0), config.env);
  const pending = manifest.groups.filter((g) => g.state === 'planned');
  if (pending.length === 0) {
    ctx.log('resume: all groups already created');
    manifest.phaseCursor = 'enroll';
    ctx.save();
    return;
  }

  const limit = pLimit(config.concurrency);
  let done = 0;
  await Promise.all(
    pending.map((g) =>
      limit(async () => {
        try {
          const { conversationId } = await controller.createGroup(g.name, []);
          g.conversationId = conversationId;
          g.state = 'created';
        } catch (err) {
          g.state = 'failed';
          g.error = `create: ${(err as Error).message}`;
        }
        done++;
        if (done % 10 === 0 || done === pending.length) ctx.log(`created ${done}/${pending.length}`);
        ctx.save();
      }),
    ),
  );

  manifest.phaseCursor = 'enroll';
  ctx.save();
}
