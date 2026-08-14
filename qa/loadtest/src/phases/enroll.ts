import pLimit from 'p-limit';
import { homeDir } from '../util.js';
import type { RunContext } from './context.js';

// Add the phone (and this group's member VUs) to each created group via the
// controller. The MLS welcome syncs the group to the phone; adder-vouching
// (controller is a non-blocked contact from bootstrap) promotes consent to
// .allowed so it appears in the phone's main conversations list. This is the
// make-or-break mechanic. Member VU inbox ids are resolved by opening their
// homes once (registers each inbox on the network) and cached in the manifest.
export async function enroll(ctx: RunContext): Promise<void> {
  const { manifest, config } = ctx;
  const phoneInboxId = manifest.device.inboxId;
  if (!phoneInboxId) throw new Error('enroll requires a bootstrapped phone inbox id');

  const controller = await ctx.driver.open(homeDir(ctx.runDir, 0), config.env);

  // Resolve the inbox id for every member VU referenced by any group.
  const neededVus = new Set<number>();
  for (const g of manifest.groups) if (g.state === 'created') for (const v of g.memberVus) neededVus.add(v);
  if (neededVus.size > 0) ctx.log(`registering ${neededVus.size} member VU inbox(es)…`);
  for (const vuIndex of [...neededVus].sort((a, b) => a - b)) {
    const vu = manifest.vus[vuIndex];
    if (!vu) continue;
    if (!vu.inboxId) {
      const client = await ctx.driver.open(homeDir(ctx.runDir, vuIndex), config.env);
      vu.inboxId = client.inboxId;
      ctx.save();
    }
  }

  const pending = manifest.groups.filter((g) => g.state === 'created');
  if (pending.length === 0) {
    ctx.log('resume: all groups already enrolled');
    manifest.phaseCursor = 'backfill';
    ctx.save();
    return;
  }

  const limit = pLimit(config.concurrency);
  let done = 0;
  await Promise.all(
    pending.map((g) =>
      limit(async () => {
        try {
          const memberInboxIds = g.memberVus
            .map((v) => manifest.vus[v]?.inboxId)
            .filter((id): id is string => typeof id === 'string');
          const toAdd = [phoneInboxId, ...memberInboxIds];
          await controller.addMembers(g.conversationId!, toAdd);

          // Verify the phone actually landed as a member; a silent miss would
          // mean no welcome and an invisible group. Retry once before failing.
          let members = await controller.memberInboxIds(g.conversationId!);
          if (!members.includes(phoneInboxId)) {
            await controller.addMembers(g.conversationId!, [phoneInboxId]);
            members = await controller.memberInboxIds(g.conversationId!);
          }
          if (!members.includes(phoneInboxId)) {
            g.state = 'failed';
            g.error = 'enroll: phone not present after addMembers';
          } else {
            g.enrollPath = 'direct';
            g.state = 'phone-added';
            manifest.counters.membersAdded += toAdd.length;
          }
        } catch (err) {
          g.state = 'failed';
          g.error = `enroll: ${(err as Error).message}`;
        }
        done++;
        if (done % 10 === 0 || done === pending.length) ctx.log(`enrolled ${done}/${pending.length}`);
        ctx.save();
      }),
    ),
  );

  manifest.phaseCursor = 'backfill';
  ctx.save();
}
