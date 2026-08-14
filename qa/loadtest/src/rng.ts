// Deterministic RNG so a given `seed` reproduces an identical run (identical
// manifest minus timestamps). All randomness in the harness must draw from a
// Rng instance derived from the config seed — never Math.random().

export class Rng {
  private state: number;

  constructor(seed: number) {
    // mulberry32; force to uint32.
    this.state = seed >>> 0;
  }

  /** Next float in [0, 1). */
  next(): number {
    this.state = (this.state + 0x6d2b79f5) | 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  /** Uniform integer in [min, max] inclusive. */
  int(min: number, max: number): number {
    if (max < min) [min, max] = [max, min];
    return min + Math.floor(this.next() * (max - min + 1));
  }

  /** Uniform float in [min, max). */
  float(min: number, max: number): number {
    return min + this.next() * (max - min);
  }

  pick<T>(items: readonly T[]): T {
    if (items.length === 0) throw new Error('pick from empty array');
    return items[this.int(0, items.length - 1)]!;
  }

  /** Resolve a fixed number or an inclusive [min, max] range. */
  resolveRange(value: number | [number, number]): number {
    return Array.isArray(value) ? this.int(value[0], value[1]) : value;
  }

  /** Weighted choice. Returns the chosen item's index. */
  weightedIndex(weights: readonly number[]): number {
    const total = weights.reduce((a, b) => a + b, 0);
    let r = this.next() * total;
    for (let i = 0; i < weights.length; i++) {
      r -= weights[i]!;
      if (r < 0) return i;
    }
    return weights.length - 1;
  }

  /** Multiplicative +/- jitter factor, e.g. jitter=0.4 -> [0.6, 1.4). */
  jitterFactor(jitter: number): number {
    return 1 + this.float(-jitter, jitter);
  }

  /** A fresh Rng deterministically derived from this one and an index. */
  fork(index: number): Rng {
    return new Rng(mix(this.state, index));
  }
}

// A cheap integer hash used to derive per-VU / per-group sub-seeds.
export function mix(a: number, b: number): number {
  let h = (a ^ 0x9e3779b9) >>> 0;
  h = Math.imul(h ^ b, 0x85ebca6b) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
}

// Zipf-weighted ordering: returns weights over `n` items where the first items
// (the "hot" groups) receive most of the traffic. `s` controls skew.
export function zipfWeights(n: number, s = 1.1): number[] {
  const weights: number[] = [];
  for (let i = 1; i <= n; i++) weights.push(1 / Math.pow(i, s));
  return weights;
}
