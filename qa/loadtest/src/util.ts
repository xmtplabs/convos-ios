import { join } from 'node:path';

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export function homeDir(runDir: string, vuIndex: number): string {
  return join(runDir, 'homes', `vu-${vuIndex}`);
}

export function nowIso(): string {
  return new Date().toISOString();
}
