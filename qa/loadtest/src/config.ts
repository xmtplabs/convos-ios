import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { parse as parseYaml } from 'yaml';
import { z } from 'zod';

const here = dirname(fileURLToPath(import.meta.url));
export const PRESETS_DIR = resolve(here, '..', 'presets');

// A weighted bucket whose payload is either a fixed number or an inclusive
// [min, max] range that the RNG samples uniformly. Used for group sizes and
// per-group message counts so a single preset spans empty groups through the
// 150-member cap.
const numberOrRange = z.union([z.number(), z.tuple([z.number(), z.number()])]);

const sizeBucket = z.object({
  weight: z.number().positive(),
  members: numberOrRange,
});

const messagesBucket = z.object({
  weight: z.number().positive(),
  count: numberOrRange,
});

export const EnvSchema = z.enum(['dev', 'local']);
export type LoadTestEnv = z.infer<typeof EnvSchema>;

export const ConfigSchema = z
  .object({
    seed: z.number().int().default(42),
    // `dev` -> hosted XMTP dev network (node-sdk ApiUrls.dev).
    // `local` -> dev/ docker XMTP node at http://localhost:5556.
    env: EnvSchema.default('dev'),

    concurrency: z.number().int().positive().max(64).default(8),

    groups: z.object({
      count: z.number().int().nonnegative(),
      duringRunPerHour: z.number().nonnegative().default(0),
      // Weighted membership distribution. `members` counts NON-phone member
      // VUs; the phone is added on top of every group. `members: 0` is an
      // "empty" group (controller + phone only). The 150 cap is the app's
      // Conversation.maxMembers.
      sizeDistribution: z.array(sizeBucket).min(1),
      nameLength: z.object({ min: z.number().int(), max: z.number().int() }).default({ min: 4, max: 50 }),
      agents: z
        .object({
          perGroupProbability: z.number().min(0).max(1).default(0),
          maxPerGroup: z.number().int().nonnegative().default(0),
          verified: z.boolean().default(false),
        })
        .default({ perGroupProbability: 0, maxPerGroup: 0, verified: false }),
    }),

    backfill: z.object({
      messagesPerGroup: z.array(messagesBucket).min(1),
      contentMix: z
        .object({
          textShort: z.number().nonnegative().default(45),
          textMedium: z.number().nonnegative().default(20),
          textLong: z.number().nonnegative().default(5),
          emojiOnly: z.number().nonnegative().default(8),
          link: z.number().nonnegative().default(5),
          reply: z.number().nonnegative().default(8),
          reaction: z.number().nonnegative().default(7),
          attachmentImage: z.number().nonnegative().default(2),
          attachmentVideo: z.number().nonnegative().default(0),
        })
        .default({}),
      // Near the 50k display cap; guard the ~1MB XMTP ceiling for multibyte text.
      longTextMaxChars: z.number().int().positive().default(49_000),
      // Target byte sizes for generated image attachments; one is picked per
      // attachment. Exercises the app's 10MB->2048px/1MB compression + image cache.
      media: z
        .object({ imageTargetBytes: z.array(z.number().int().positive()).default([200_000, 900_000]) })
        .default({ imageTargetBytes: [200_000, 900_000] }),
      rate: z
        .object({
          perGroupMsgsPerSec: z.number().positive().default(2),
          globalMsgsPerSec: z.number().positive().default(20),
          jitter: z.number().min(0).max(1).default(0.4),
        })
        .default({ perGroupMsgsPerSec: 2, globalMsgsPerSec: 20, jitter: 0.4 }),
    }),

    churn: z
      .object({
        durationMin: z.number().nonnegative().default(0),
        aggregateMsgsPerSec: z.number().nonnegative().default(0),
        bursts: z
          .object({
            everyMin: z.number().positive().default(10),
            multiplier: z.number().positive().default(8),
            durationS: z.number().positive().default(30),
          })
          .optional(),
        hotGroupFraction: z.number().min(0).max(1).default(0.15),
        metadataChurnPerHour: z.number().nonnegative().default(0),
        profileChurnPerHour: z.number().nonnegative().default(0),
        typingNoisePerMin: z.number().nonnegative().default(0),
        readReceiptsPerMin: z.number().nonnegative().default(0),
        membershipGrowthPerHour: z.number().nonnegative().default(0),
      })
      .default({}),

    device: z
      .object({
        // Enrollment is bootstrap-once + direct addMembers; the phone inbox id is
        // learned from the bootstrap group and cached here on resume.
        inboxId: z.string().nullable().default(null),
        bootstrapName: z.string().default('loadtest-bootstrap'),
        // Optional alternative to the QR scan: an invite URL generated on the
        // phone (in the Convos app). When set, the controller joins that invite
        // instead of serving its own QR, so the phone never has to scan. The
        // phone's inbox id is the invite creator, learned with no round-trip.
        inviteUrl: z.string().nullable().default(null),
      })
      .default({ inboxId: null, bootstrapName: 'loadtest-bootstrap', inviteUrl: null }),

    measurement: z
      .object({
        cxdb: z.boolean().default(true),
        runLabel: z.string().optional(),
      })
      .default({ cxdb: true }),

    // Upload provider for remote attachments. Attachments are skipped when no
    // provider is configured (e.g. plain Dev runs). On the local stack, point
    // this at MinIO (s3) or the backend (convos-api). convosApiKey falls back to
    // the CONVOS_API_KEY env var.
    upload: z
      .object({
        provider: z.enum(['convos-api', 's3', 'pinata']).optional(),
        convosApiKey: z.string().optional(),
        convosApiBaseUrl: z.string().optional(),
        token: z.string().optional(),
        gateway: z.string().optional(),
        s3Bucket: z.string().optional(),
        s3Region: z.string().optional(),
        s3Endpoint: z.string().optional(),
      })
      .default({}),
  })
  .strict();

export type UploadConfig = z.infer<typeof ConfigSchema>['upload'];

export type LoadTestConfig = z.infer<typeof ConfigSchema>;

export function loadPreset(name: string): LoadTestConfig {
  const path = name.endsWith('.yaml') || name.includes('/') ? name : resolve(PRESETS_DIR, `${name}.yaml`);
  const raw = parseYaml(readFileSync(path, 'utf8'));
  return ConfigSchema.parse(raw);
}

// Apply `--set a.b.c=value` overrides onto a parsed config object. Values are
// JSON-parsed when possible (numbers, booleans, arrays), else kept as strings.
export function applyOverrides(base: unknown, sets: string[]): LoadTestConfig {
  const obj = structuredClone(base) as Record<string, unknown>;
  for (const entry of sets) {
    const eq = entry.indexOf('=');
    if (eq < 0) throw new Error(`--set expects key=value, got: ${entry}`);
    const path = entry.slice(0, eq).split('.');
    const rawValue = entry.slice(eq + 1);
    let value: unknown;
    try {
      value = JSON.parse(rawValue);
    } catch {
      value = rawValue;
    }
    let cursor = obj;
    for (let i = 0; i < path.length - 1; i++) {
      const key = path[i]!;
      if (typeof cursor[key] !== 'object' || cursor[key] === null) cursor[key] = {};
      cursor = cursor[key] as Record<string, unknown>;
    }
    cursor[path[path.length - 1]!] = value;
  }
  return ConfigSchema.parse(obj);
}
