import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export interface PerfSample {
  metric: string;
  ms: number;
  count?: number;
  raw: string;
}

export interface MetricSummary {
  metric: string;
  n: number;
  median: number;
  p95: number;
  max: number;
}

// Tolerant parser for the app's file-only [PERF] lines in convos.log. Handles:
//   [PERF] sync.all_conversations: 1234ms
//   [PERF] ConversationViewModel.init: 42ms, 87 messages loaded (90 list items)
//   [PERF] conversations.list.render: 210ms count=180
const PERF_RE = /\[PERF\]\s+([A-Za-z0-9_.]+):\s+([0-9]+(?:\.[0-9]+)?)\s*ms/;
const COUNT_RE = /count=([0-9]+)|,\s*([0-9]+)\s+messages/;

export function parsePerfLog(logText: string): PerfSample[] {
  const samples: PerfSample[] = [];
  for (const line of logText.split('\n')) {
    const m = PERF_RE.exec(line);
    if (!m) continue;
    const countMatch = COUNT_RE.exec(line);
    const count = countMatch ? Number(countMatch[1] ?? countMatch[2]) : undefined;
    samples.push({ metric: m[1]!, ms: Number(m[2]), count, raw: line.trim() });
  }
  return samples;
}

function quantile(sorted: number[], q: number): number {
  if (sorted.length === 0) return 0;
  const pos = (sorted.length - 1) * q;
  const base = Math.floor(pos);
  const rest = pos - base;
  const lo = sorted[base]!;
  const hi = sorted[Math.min(base + 1, sorted.length - 1)]!;
  return lo + (hi - lo) * rest;
}

export function summarize(samples: PerfSample[]): MetricSummary[] {
  const byMetric = new Map<string, number[]>();
  for (const s of samples) {
    const arr = byMetric.get(s.metric) ?? [];
    arr.push(s.ms);
    byMetric.set(s.metric, arr);
  }
  const out: MetricSummary[] = [];
  for (const [metric, values] of byMetric) {
    const sorted = [...values].sort((a, b) => a - b);
    out.push({
      metric,
      n: sorted.length,
      median: quantile(sorted, 0.5),
      p95: quantile(sorted, 0.95),
      max: sorted[sorted.length - 1]!,
    });
  }
  return out.sort((a, b) => a.metric.localeCompare(b.metric));
}

// Parse an exported convos.log into per-metric summaries and persist the raw
// samples as ndjson next to the run for later comparison.
export function ingestLog(runDir: string, logPath: string): MetricSummary[] {
  const samples = parsePerfLog(readFileSync(logPath, 'utf8'));
  const ndjson = samples.map((s) => JSON.stringify(s)).join('\n');
  writeFileSync(join(runDir, 'device-perf.ndjson'), ndjson + (ndjson ? '\n' : ''));
  return summarize(samples);
}
