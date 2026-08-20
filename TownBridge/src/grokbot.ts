import { DurableObject } from "cloudflare:workers";
import { constantTimeEqual } from "./capabilities";
import { MAXIMUM_GROKBOT_AGENTS, type GrokBotAgent } from "./grokbot-input";

const LONG_POLL_MILLISECONDS = 25_000;
const REQUEST_RETENTION_MILLISECONDS = 60 * 60 * 1_000;

export type { GrokBotAgent } from "./grokbot-input";

export type GrokBotJSONValue =
  | null
  | string
  | number
  | boolean
  | GrokBotJSONValue[]
  | { [key: string]: GrokBotJSONValue };

export interface GrokBotCommand {
  type: "list_agents" | "send";
  agentId?: string;
  requestId?: string;
  returnToken?: string;
  prompt?: string;
  homeContext?: GrokBotJSONValue;
}

export interface GrokBotPullResult {
  authorized: boolean;
  payload: string | null;
}

export interface GrokBotAgentsResult {
  authorized: boolean;
  agents: GrokBotAgent[] | null;
}

export class GrokBotSession extends DurableObject<Env> {
  private readonly commandWaiters = new Set<() => void>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS session_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS commands (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS outstanding_requests (
        request_id TEXT PRIMARY KEY,
        return_token TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    `);
  }

  initialize(sessionId: string, tokenHash: string): boolean {
    const existing = this.stateValue("token_hash");
    if (existing) {
      return false;
    }
    this.ctx.storage.sql.exec(
      "INSERT INTO session_state (key, value) VALUES (?, ?), (?, ?)",
      "session_id",
      sessionId,
      "token_hash",
      tokenHash,
    );
    this.insertCommand({ type: "list_agents" });
    return true;
  }

  isAuthenticated(tokenHash: string): boolean {
    const storedHash = this.stateValue("token_hash");
    return storedHash !== null && constantTimeEqual(storedHash, tokenHash);
  }

  agents(tokenHash: string): GrokBotAgentsResult {
    if (!this.isAuthenticated(tokenHash)) {
      return { authorized: false, agents: null };
    }
    const storedAgents = this.stateValue("agents");
    return {
      authorized: true,
      agents: storedAgents ? (JSON.parse(storedAgents) as GrokBotAgent[]) : null,
    };
  }

  enqueue(tokenHash: string, command: GrokBotCommand): boolean {
    if (!this.isAuthenticated(tokenHash)) {
      return false;
    }
    this.ctx.storage.sql.exec(
      "DELETE FROM outstanding_requests WHERE created_at < ?",
      Date.now() - REQUEST_RETENTION_MILLISECONDS,
    );
    if (command.type === "send" && command.requestId && command.returnToken) {
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO outstanding_requests (request_id, return_token, created_at) VALUES (?, ?, ?)",
        command.requestId,
        command.returnToken,
        Date.now(),
      );
    }
    this.insertCommand(command);
    return true;
  }

  returnToken(tokenHash: string, requestId: string): string | null {
    if (!this.isAuthenticated(tokenHash)) {
      return null;
    }
    const row = this.ctx.storage.sql
      .exec<{ return_token: string }>(
        "SELECT return_token FROM outstanding_requests WHERE request_id = ?",
        requestId,
      )
      .toArray()[0];
    return row?.return_token ?? null;
  }

  acknowledgeRequest(tokenHash: string, requestId: string): boolean {
    if (!this.isAuthenticated(tokenHash)) {
      return false;
    }
    this.ctx.storage.sql.exec("DELETE FROM outstanding_requests WHERE request_id = ?", requestId);
    return true;
  }

  async pull(tokenHash: string): Promise<GrokBotPullResult> {
    if (!this.isAuthenticated(tokenHash)) {
      return { authorized: false, payload: null };
    }

    const immediate = this.takeCommand();
    if (immediate) {
      return { authorized: true, payload: JSON.stringify(immediate) };
    }

    await this.waitForCommand();
    const command = this.takeCommand();
    return { authorized: true, payload: command ? JSON.stringify(command) : null };
  }

  reportAgents(tokenHash: string, agents: GrokBotAgent[]): boolean {
    if (!this.isAuthenticated(tokenHash)) {
      return false;
    }
    if (agents.length > MAXIMUM_GROKBOT_AGENTS) {
      throw new Error("TOO_MANY_AGENTS");
    }
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO session_state (key, value) VALUES (?, ?), (?, ?)",
      "agents",
      JSON.stringify(agents),
      "agents_updated_at",
      new Date().toISOString(),
    );
    return true;
  }

  private stateValue(key: string): string | null {
    const row = this.ctx.storage.sql
      .exec<{ value: string }>("SELECT value FROM session_state WHERE key = ?", key)
      .toArray()[0];
    return row?.value ?? null;
  }

  private insertCommand(command: GrokBotCommand): void {
    this.ctx.storage.sql.exec(
      "INSERT INTO commands (payload, created_at) VALUES (?, ?)",
      JSON.stringify(command),
      Date.now(),
    );
    for (const notify of this.commandWaiters) {
      notify();
    }
  }

  private takeCommand(): GrokBotCommand | null {
    const row = this.ctx.storage.sql
      .exec<{ sequence: number; payload: string }>(
        "SELECT sequence, payload FROM commands ORDER BY sequence ASC LIMIT 1",
      )
      .toArray()[0];
    if (!row) {
      return null;
    }
    this.ctx.storage.sql.exec("DELETE FROM commands WHERE sequence = ?", row.sequence);
    return JSON.parse(row.payload) as GrokBotCommand;
  }

  private waitForCommand(): Promise<void> {
    return new Promise((resolve) => {
      let timeout: ReturnType<typeof setTimeout> | undefined;
      const finish = (): void => {
        if (timeout !== undefined) {
          clearTimeout(timeout);
        }
        this.commandWaiters.delete(finish);
        resolve();
      };
      this.commandWaiters.add(finish);
      timeout = setTimeout(finish, LONG_POLL_MILLISECONDS);
    });
  }
}
