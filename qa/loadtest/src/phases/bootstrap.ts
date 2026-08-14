import { createIdentityStore } from '@xmtp/convos-cli';
import type { VuClient } from '../driver/driver.js';
import { runBootstrapServe } from '../driver/serveBootstrap.js';
import { homeDir, nowIso, sleep } from '../util.js';
import type { RunContext } from './context.js';

// Collect every non-controller member across all of the controller's
// conversations (the control group and the phone's join-request DM both contain
// the phone), deduped. Returns the single device inbox id, or undefined if none
// / ambiguous. Independent of any serve event field names.
async function deriveDeviceInbox(controller: VuClient): Promise<string | undefined> {
  await controller.sync();
  const others = new Set<string>();
  for (const cid of await controller.listConversationIds()) {
    let members: string[] = [];
    try {
      await controller.sync(cid);
      members = await controller.memberInboxIds(cid);
    } catch {
      continue;
    }
    for (const id of members) if (id !== controller.inboxId) others.add(id);
  }
  if (others.size === 1) return [...others][0];
  return undefined;
}

// One-time device enrollment anchor. Two ways in, both making the controller a
// contact on the phone (the adder-vouching anchor) and learning the phone's
// stable inbox id:
//   - default: the controller serves its own control-group QR; the human scans
//     it once and replies from the device.
//   - `device.inviteUrl`: the phone generates the invite instead and the
//     controller joins it (no scan, no serve subprocess).
// Skipped when the inbox id is already cached, and reused without a rescan when
// the controller home already holds an identity paired with the device.
export async function bootstrap(ctx: RunContext): Promise<void> {
  const { manifest, config } = ctx;
  if (manifest.device.inboxId) {
    ctx.log(`resume: phone inbox already known (${manifest.device.inboxId.slice(0, 12)}…)`);
    manifest.phaseCursor = 'create';
    ctx.save();
    return;
  }

  const controllerHome = homeDir(ctx.runDir, 0);
  let phoneInboxId: string | undefined;
  let controllerInboxId: string | undefined;

  // Fast path: the controller identity already exists (e.g. a prior run/attempt
  // where the phone joined). Try to derive the device inbox with no serve/scan.
  if (createIdentityStore(controllerHome).exists()) {
    ctx.log('controller identity exists — checking for an existing device pairing…');
    const controller = await ctx.driver.open(controllerHome, config.env);
    controllerInboxId = controller.inboxId;
    phoneInboxId = await deriveDeviceInbox(controller);
    if (phoneInboxId) ctx.log('reused existing pairing — no scan needed');
  }

  // Invite-URL path (opt-in): the phone made the invite; the controller joins
  // it. The invite creator is the phone, so its inbox id is known with no
  // round-trip, and joining + the profile republish below makes the controller
  // a non-blocked contact for adder-vouching — same anchor the QR flow builds.
  if (!phoneInboxId && config.device.inviteUrl) {
    ctx.log('joining the phone-provided invite URL — no scan needed');
    const controller = await ctx.driver.open(controllerHome, config.env);
    controllerInboxId = controller.inboxId;
    const res = await controller.joinViaInvite(config.device.inviteUrl, { profileName: config.device.bootstrapName });
    phoneInboxId = res.creatorInboxId;
    manifest.device.bootstrapConversationId = res.conversationId;
    ctx.log(`joined the phone's control group (inbox ${phoneInboxId.slice(0, 12)}…)`);
  }

  // Normal path: run the serve loop, show the QR, wait for the join.
  if (!phoneInboxId) {
    ctx.log('starting bootstrap serve — scan the QR on the device to join the control group');
    const res = await runBootstrapServe({ home: controllerHome, env: config.env, name: config.device.bootstrapName });
    controllerInboxId = res.controllerInboxId ?? controllerInboxId;
    manifest.device.bootstrapConversationId = res.bootstrapConversationId;
    phoneInboxId = res.phoneInboxId;

    // Serve has stopped and released the DB. Derive from membership, polling for
    // the join to propagate into the controller's local db.
    if (!phoneInboxId) {
      ctx.log('deriving phone inbox id from control-group membership…');
      const controller = await ctx.driver.open(controllerHome, config.env);
      controllerInboxId = controller.inboxId;
      for (let attempt = 0; attempt < 15 && !phoneInboxId; attempt++) {
        if (attempt > 0) await sleep(2000);
        phoneInboxId = await deriveDeviceInbox(controller);
        if (!phoneInboxId && attempt === 4) {
          ctx.log('still waiting for the phone to appear — is the join complete on the device?');
        }
      }
    }
  }

  if (!controllerInboxId) throw new Error('failed to resolve the controller inbox id');
  if (!phoneInboxId) {
    throw new Error('could not determine the phone inbox id — did the device actually join the control group?');
  }

  // Publish the controller's profile as a regular user. `agent serve` publishes a
  // startup profile with memberKind Agent (and has no stdin lever to change it),
  // so overwrite it here through the library, which sends memberKind Unspecified.
  // This is what makes the device render the controller as a normal contact
  // rather than an agent account.
  const bootstrapConversationId = manifest.device.bootstrapConversationId;
  if (bootstrapConversationId) {
    const controller = await ctx.driver.open(controllerHome, config.env);
    try {
      await controller.sync(bootstrapConversationId);
      await controller.updateProfile(bootstrapConversationId, config.device.bootstrapName);
      ctx.log('published controller profile as a regular user');
    } catch (err) {
      ctx.log(`warning: could not publish controller profile: ${(err as Error).message}`);
    }
  }

  manifest.device.controllerInboxId = controllerInboxId;
  manifest.vus[0]!.inboxId = controllerInboxId;
  manifest.device.inboxId = phoneInboxId;
  manifest.device.pairedAt = nowIso();
  manifest.phaseCursor = 'create';
  ctx.save();
  ctx.log(`phone enrolled. inbox ${phoneInboxId.slice(0, 12)}… cached — no more scans needed this run`);
}
