import type { Rng } from '../rng.js';

// A small dependency-free word pool. Text realism matters less than length
// distribution and multibyte handling for load purposes, so a wordlist +
// sentence assembler is enough. Everything draws from a seeded Rng.
const WORDS = [
  'the', 'meeting', 'ship', 'today', 'later', 'quick', 'update', 'thanks', 'sounds', 'good',
  'let', 'me', 'know', 'when', 'ready', 'pushed', 'branch', 'build', 'failing', 'again',
  'coffee', 'lunch', 'tomorrow', 'weekend', 'plan', 'draft', 'review', 'merge', 'deploy', 'rollback',
  'great', 'work', 'team', 'almost', 'there', 'blocked', 'waiting', 'reply', 'ping', 'call',
  'notes', 'shared', 'doc', 'link', 'above', 'below', 'context', 'reminder', 'standup', 'demo',
  'looks', 'like', 'working', 'now', 'fixed', 'issue', 'edge', 'case', 'tested', 'locally',
];

// Emoji palette for emoji-only messages and reactions.
export const EMOJI = ['👍', '🔥', '🎉', '😂', '❤️', '🚀', '👀', '💯', '🙌', '😅', '🤔', '✅', '⚡️', '🥳', '👏'];

const LINK_HOSTS = ['example.com', 'github.com', 'docs.example.org', 'news.example.net'];

export function randomWord(rng: Rng): string {
  return rng.pick(WORDS);
}

export function sentence(rng: Rng, words: number): string {
  const parts: string[] = [];
  for (let i = 0; i < words; i++) parts.push(randomWord(rng));
  const text = parts.join(' ');
  return text.charAt(0).toUpperCase() + text.slice(1) + '.';
}

export function shortText(rng: Rng): string {
  // 5-120 chars: 1-2 short sentences.
  return sentence(rng, rng.int(2, 12));
}

export function mediumText(rng: Rng): string {
  // 120-1000 chars: several sentences.
  const sentences = rng.int(3, 10);
  const out: string[] = [];
  for (let i = 0; i < sentences; i++) out.push(sentence(rng, rng.int(6, 18)));
  return out.join(' ');
}

// Long text near the display cap. Built by repetition to a target char count,
// guarding against the ~1MB XMTP body ceiling (target chars stay well under it).
export function longText(rng: Rng, maxChars: number): string {
  const target = rng.int(Math.floor(maxChars * 0.6), maxChars);
  const chunks: string[] = [];
  let len = 0;
  while (len < target) {
    const s = sentence(rng, rng.int(8, 20));
    chunks.push(s);
    len += s.length + 1;
  }
  return chunks.join(' ').slice(0, target);
}

export function emojiOnly(rng: Rng): string {
  const count = rng.int(1, 6);
  const out: string[] = [];
  for (let i = 0; i < count; i++) out.push(rng.pick(EMOJI));
  return out.join('');
}

export function linkText(rng: Rng): string {
  const host = rng.pick(LINK_HOSTS);
  const slug = randomWord(rng) + '-' + randomWord(rng);
  const lead = rng.next() < 0.5 ? sentence(rng, rng.int(3, 8)) + ' ' : '';
  return `${lead}https://${host}/${slug}`;
}

const FIRST_NAMES = ['Alex', 'Sam', 'Jordan', 'Casey', 'Riley', 'Morgan', 'Taylor', 'Jamie', 'Avery', 'Quinn', 'Dana', 'Rowan'];
const LAST_INITIALS = ['A', 'B', 'C', 'D', 'K', 'L', 'M', 'R', 'S', 'T', 'V', 'W'];

// A member display name bounded by the app's 50-char name limit. Suffixed so
// repeated profile churn produces visibly-changing names.
export function displayName(rng: Rng): string {
  const name = `${rng.pick(FIRST_NAMES)} ${rng.pick(LAST_INITIALS)}.`;
  const tag = rng.int(1, 999);
  return `${name} ${tag}`.slice(0, 50);
}

// A group / conversation name bounded by the app's 50-char name limit.
export function groupName(rng: Rng, index: number, min: number, max: number): string {
  const words = rng.int(1, 4);
  const parts: string[] = [];
  for (let i = 0; i < words; i++) parts.push(randomWord(rng));
  let name = parts.join(' ');
  name = name.charAt(0).toUpperCase() + name.slice(1);
  // Ensure uniqueness for readability in the app while respecting the cap.
  const suffix = ` #${index}`;
  const budget = Math.min(max, 50) - suffix.length;
  if (name.length > budget) name = name.slice(0, Math.max(min, budget));
  return name + suffix;
}
