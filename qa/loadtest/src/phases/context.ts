import type { LoadTestConfig } from '../config.js';
import type { Driver } from '../driver/driver.js';
import type { Manifest } from '../manifest.js';
import { saveManifest } from '../manifest.js';
import type { Rng } from '../rng.js';

// Shared state threaded through every phase. `save()` checkpoints the manifest
// so any phase can be resumed after a crash or Ctrl-C.
export interface RunContext {
  config: LoadTestConfig;
  rng: Rng;
  driver: Driver;
  runDir: string;
  manifest: Manifest;
  save(): void;
  log(msg: string): void;
}

export function makeContext(args: {
  config: LoadTestConfig;
  rng: Rng;
  driver: Driver;
  runDir: string;
  manifest: Manifest;
}): RunContext {
  return {
    ...args,
    save() {
      saveManifest(args.runDir, args.manifest);
    },
    log(msg: string) {
      console.log(`[${args.manifest.phaseCursor}] ${msg}`);
    },
  };
}
