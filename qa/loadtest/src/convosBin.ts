import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';

// Resolve an absolute path to the `convos` CLI. Node's child_process spawn uses
// process.env.PATH, which under `npm run` / GUI launches often lacks
// /opt/homebrew/bin even when the interactive shell has it (=> spawn ENOENT).
// Resolving the absolute path up front sidesteps that entirely.
let cached: string | undefined;

export function resolveConvosBin(): string {
  if (cached) return cached;

  const override = process.env.CONVOS_BIN;
  if (override && existsSync(override)) return (cached = override);

  for (const p of ['/opt/homebrew/bin/convos', '/usr/local/bin/convos']) {
    if (existsSync(p)) return (cached = p);
  }

  // Last resort: ask a login shell (which sources the user's profile and thus
  // has the full PATH, including Homebrew and nvm-managed node).
  for (const shell of ['zsh', 'bash', 'sh']) {
    try {
      const out = execFileSync(shell, ['-lc', 'command -v convos'], { encoding: 'utf8' }).trim();
      if (out && existsSync(out)) return (cached = out);
    } catch {
      // try next shell
    }
  }

  throw new Error('convos CLI not found. Install it (npm i -g @xmtp/convos-cli) or set CONVOS_BIN=/path/to/convos');
}

// A child env whose PATH is guaranteed to include the convos bin dir, so the
// `convos` node script can also find `node` and its own siblings.
export function convosChildEnv(home: string): NodeJS.ProcessEnv {
  const bin = resolveConvosBin();
  const binDir = dirname(bin);
  const path = process.env.PATH ?? '';
  return {
    ...process.env,
    CONVOS_HOME: home,
    PATH: path.split(':').includes(binDir) ? path : `${binDir}:${path}`,
  };
}
