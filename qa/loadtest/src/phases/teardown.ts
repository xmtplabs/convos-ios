import pLimit from 'p-limit';
import { homeDir } from '../util.js';
import type { RunContext } from './context.js';

// Unenroll the phone: remove it from every group so the device's conversation
// list clears without an app reinstall. The groups themselves are left intact
// (re-running enroll would re-add the phone). Idempotent — groups the phone is
// already absent from are skipped.
export async function teardown(ctx: RunContext): Promise<void> {
  const { manifest, config } = ctx;
  const phoneInboxId = manifest.device.inboxId;
  if (!phoneInboxId) {
    ctx.log('nothing to tear down (no phone inbox cached)');
    return;
  }
  const controller = await ctx.driver.open(homeDir(ctx.runDir, 0), config.env);
  const groups = manifest.groups.filter((g) => g.conversationId);
  const limit = pLimit(config.concurrency);
  let removed = 0;
  await Promise.all(
    groups.map((g) =>
      limit(async () => {
        try {
          const members = await controller.memberInboxIds(g.conversationId!);
          if (members.includes(phoneInboxId)) {
            await controller.removeMembers(g.conversationId!, [phoneInboxId]);
            removed++;
          }
        } catch (err) {
          ctx.log(`teardown: ${g.conversationId} failed: ${(err as Error).message}`);
        }
      }),
    ),
  );
  ctx.log(`teardown: removed the phone from ${removed} group(s); the device list should clear on next sync`);
}
