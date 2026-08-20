export const MAXIMUM_GROKBOT_AGENTS = 200;

export interface GrokBotAgent {
  id: string;
  name: string;
  title?: string;
  description?: string;
}

export function isValidGrokBotSessionToken(value: string): boolean {
  return /^grok_session_[A-Za-z0-9_-]{40,160}$/.test(value);
}

export function normalizedGrokBotAgents(value: unknown): GrokBotAgent[] | null {
  if (!Array.isArray(value) || value.length > MAXIMUM_GROKBOT_AGENTS) {
    return null;
  }
  const agents: GrokBotAgent[] = [];
  const ids = new Set<string>();
  for (const candidate of value) {
    if (!candidate || typeof candidate !== "object") {
      return null;
    }
    const record = candidate as Record<string, unknown>;
    const id = normalizedString(record.id, 200);
    const name = normalizedString(record.name, 200);
    if (!id || !name || ids.has(id)) {
      return null;
    }
    ids.add(id);
    agents.push({
      id,
      name,
      title: normalizedOptionalString(record.title, 300),
      description: normalizedOptionalString(record.description, 2_000),
    });
  }
  return agents;
}

function normalizedString(value: unknown, maximumLength: number): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim();
  return normalized.length > 0 && normalized.length <= maximumLength ? normalized : null;
}

function normalizedOptionalString(value: unknown, maximumLength: number): string | undefined {
  if (value === undefined || value === null || value === "") {
    return undefined;
  }
  return normalizedString(value, maximumLength) ?? undefined;
}
