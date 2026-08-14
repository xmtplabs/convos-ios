import { spawn, execFile } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { promisify } from 'node:util';
import { createInterface } from 'node:readline';
import qrcodeTerminal from 'qrcode-terminal';
import type { LoadTestEnv } from '../config.js';
import { convosChildEnv, resolveConvosBin } from '../convosBin.js';

const execFileAsync = promisify(execFile);

export interface BootstrapResult {
  inviteUrl?: string;
  bootstrapConversationId?: string;
  controllerInboxId?: string;
  phoneInboxId?: string; // best-effort from the member_joined event; may be resolved later
}

// After the phone joins, the controller sends this so the device has a message
// (and its ProfileUpdate) to respond to. The reply is what proves the controller
// landed as a contact on the device before we hand off to the library phases.
const BOOTSTRAP_GREETING =
  "You're in. This is the load-test control agent — reply here to finish setup and start filling the app.";

// A 32-byte inbox id renders as 64 lowercase hex chars. Used to salvage an
// inbox id out of an event whose exact field name we don't want to hard-code.
const INBOX_ID_RE = /\b[0-9a-f]{64}\b/;

function extractInboxId(obj: unknown): string | undefined {
  if (!obj || typeof obj !== 'object') return undefined;
  const rec = obj as Record<string, unknown>;
  for (const key of ['inboxId', 'memberInboxId', 'addedInboxId', 'joinerInboxId']) {
    if (typeof rec[key] === 'string' && INBOX_ID_RE.test(rec[key] as string)) return rec[key] as string;
  }
  const nested = rec['member'] ?? rec['data'];
  if (nested) {
    const inner = extractInboxId(nested);
    if (inner) return inner;
  }
  const m = INBOX_ID_RE.exec(JSON.stringify(obj));
  return m?.[0];
}

// Ensure the home has an initialized identity + env before serving. Idempotent:
// `--force` re-inits config without destroying an existing identity's data dir.
export async function cliInit(home: string, env: LoadTestEnv): Promise<void> {
  // Home must exist before it can be the child cwd; convos populates it.
  mkdirSync(home, { recursive: true });
  await execFileAsync(resolveConvosBin(), ['init', '--env', env, '--home', home], {
    cwd: home,
    env: convosChildEnv(home),
  });
}

/**
 * Run the one-time bootstrap: create a control group via `convos agent serve`,
 * show its invite QR, and wait for the phone to scan+join. Serve owns the home's
 * SQLite DB for its lifetime, so it is fully stopped before the library takes over.
 */
export async function runBootstrapServe(opts: {
  home: string;
  env: LoadTestEnv;
  name: string;
}): Promise<BootstrapResult> {
  await cliInit(opts.home, opts.env);

  const result: BootstrapResult = {};

  await new Promise<void>((resolvePromise, reject) => {
    const child = spawn(
      resolveConvosBin(),
      ['agent', 'serve', '--json', '--env', opts.env, '--home', opts.home, '--name', opts.name, '--profile-name', opts.name],
      { cwd: opts.home, env: convosChildEnv(opts.home), stdio: ['pipe', 'pipe', 'inherit'] },
    );

    let joined = false;
    let acknowledged = false;
    let stopping = false;

    const rl = createInterface({ input: child.stdout });
    const manual = createInterface({ input: process.stdin, output: process.stdout });

    // Queue one ndjson command to the serve loop's stdin. Ignored once stdin has
    // been closed by stop().
    const sendCommand = (cmd: Record<string, unknown>) => {
      if (stopping) return;
      try {
        child.stdin.write(`${JSON.stringify(cmd)}\n`);
      } catch {
        // stdin already closed
      }
    };

    const stop = () => {
      if (stopping) return;
      stopping = true;
      manual.close();
      // agent serve stops on stdin-close or SIGINT; closing stdin avoids
      // guessing the command schema. Escalate to SIGKILL if it lingers so the
      // home's SQLite lock is released before the library opens the same home.
      try {
        child.stdin.end();
      } catch {
        // ignore
      }
      child.kill('SIGINT');
      setTimeout(() => {
        try {
          child.kill('SIGKILL');
        } catch {
          // already gone
        }
      }, 5000).unref();
    };

    // The phone joined the control group. Send a greeting the user must reply to.
    // We keep serving until that text reply lands — the round-trip is what makes
    // the controller a non-blocked contact on the device (so adder-vouching can
    // promote every later group into the phone's main list). The controller's own
    // profile is (re)published as a regular user by the caller once serve stops;
    // serve can only publish an agent-kind profile, so it's not set here.
    const onJoined = (inboxId?: string) => {
      if (joined) return;
      joined = true;
      if (inboxId) result.phoneInboxId = inboxId;
      console.log(`\n[bootstrap] phone joined${inboxId ? ` (inbox ${inboxId.slice(0, 12)}…)` : ''}.`);
      sendCommand({ type: 'send', text: BOOTSTRAP_GREETING });
      console.log('[bootstrap] sent greeting. Reply with a text message on the device to finish setup.');
      console.log('(Or press Enter here once you have replied, if not detected.)');
    };

    // The user replied with a text message after joining. The controller is now an
    // established contact on the device; safe to stop serve and hand off to the
    // library phases.
    const onAcknowledged = (inboxId?: string) => {
      if (!joined || acknowledged) return;
      acknowledged = true;
      if (inboxId && !result.phoneInboxId) result.phoneInboxId = inboxId;
      console.log('\n[bootstrap] text reply received — setup complete. Stopping serve…');
      stop();
    };

    rl.on('line', (line) => {
      const trimmed = line.trim();
      if (!trimmed.startsWith('{')) return;
      let evt: any;
      try {
        evt = JSON.parse(trimmed);
      } catch {
        return;
      }
      const type = evt.type ?? evt.event;
      if (type === 'ready') {
        result.inviteUrl = evt.inviteUrl;
        result.bootstrapConversationId = evt.conversationId;
        result.controllerInboxId = evt.inboxId;
        console.log('\n[bootstrap] Scan this QR on the phone (Convos, matching env), or open the URL:');
        console.log(`  ${evt.inviteUrl}\n`);
        if (evt.inviteUrl) qrcodeTerminal.generate(evt.inviteUrl, { small: true });
        console.log('\nWaiting for the phone to join. (Or press Enter here once it has, if not detected.)');
      } else if (type === 'member_joined') {
        onJoined(extractInboxId(evt));
      } else if (type === 'message') {
        // Wait specifically for a text reply from the phone; attachments,
        // reactions, replies, etc. don't count. The serve stream already excludes
        // the controller's own messages, and catch-up messages are historical.
        if (!evt.catchup && evt.contentType?.typeId === 'text') {
          onAcknowledged(typeof evt.senderInboxId === 'string' ? evt.senderInboxId : undefined);
        }
      } else if (type === 'error') {
        console.error('[bootstrap] serve error:', trimmed);
      }
    });

    // Manual fallback: Enter advances the current stage — first press stands in
    // for the join detection, the next for the reply detection.
    manual.on('line', () => {
      if (!joined) onJoined(undefined);
      else onAcknowledged(undefined);
    });

    child.on('exit', () => {
      rl.close();
      if (!stopping) manual.close();
      if (joined || result.controllerInboxId) resolvePromise();
      else reject(new Error('serve exited before the phone joined'));
    });
    child.on('error', reject);
  });

  return result;
}
