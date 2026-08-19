import { McpServer } from "@modelcontextprotocol/server";
import { createMcpHandler } from "agents/mcp/server";
import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { constantTimeEqual, isValidRequestId, isValidReturnToken } from "./capabilities";

const REQUEST_LIFETIME_MS = 60 * 60 * 1_000;

type RequestStatus = "pending" | "completed" | "expired";

export interface ResultLink {
  title?: string;
  url: string;
}

export interface TownResult {
  message: string;
  links: ResultLink[];
  completedAt: string;
}

interface StoredMailbox {
  tokenHash: string;
  expiresAt: number;
  result?: TownResult;
}

interface MailboxRead {
  status: RequestStatus;
  expiresAt: number;
  result?: TownResult;
}

interface RegisterBody {
  requestId: string;
  returnToken: string;
}

interface CompleteBody {
  requestId: string;
  returnToken: string;
  message: string;
  links: ResultLink[];
}

export class ResultMailbox extends DurableObject<Env> {
  async register(tokenHash: string, expiresAt: number): Promise<void> {
    const existing = await this.ctx.storage.get<StoredMailbox>("mailbox");
    if (existing && existing.expiresAt > Date.now()) {
      throw new Error("REQUEST_ALREADY_EXISTS");
    }

    await this.ctx.storage.put<StoredMailbox>("mailbox", { tokenHash, expiresAt });
    await this.ctx.storage.setAlarm(expiresAt + 60_000);
  }

  async complete(tokenHash: string, result: TownResult): Promise<MailboxRead> {
    const mailbox = await this.ctx.storage.get<StoredMailbox>("mailbox");
    if (!mailbox) {
      throw new Error("REQUEST_NOT_FOUND");
    }
    if (!constantTimeEqual(mailbox.tokenHash, tokenHash)) {
      throw new Error("INVALID_RETURN_TOKEN");
    }
    if (mailbox.expiresAt <= Date.now()) {
      return { status: "expired", expiresAt: mailbox.expiresAt };
    }
    if (mailbox.result) {
      return {
        status: "completed",
        expiresAt: mailbox.expiresAt,
        result: mailbox.result,
      };
    }

    const completed: StoredMailbox = { ...mailbox, result };
    await this.ctx.storage.put("mailbox", completed);
    return { status: "completed", expiresAt: mailbox.expiresAt, result };
  }

  async read(tokenHash: string): Promise<MailboxRead> {
    const mailbox = await this.ctx.storage.get<StoredMailbox>("mailbox");
    if (!mailbox) {
      throw new Error("REQUEST_NOT_FOUND");
    }
    if (!constantTimeEqual(mailbox.tokenHash, tokenHash)) {
      throw new Error("INVALID_RETURN_TOKEN");
    }
    if (mailbox.expiresAt <= Date.now()) {
      return { status: "expired", expiresAt: mailbox.expiresAt };
    }
    return {
      status: mailbox.result ? "completed" : "pending",
      expiresAt: mailbox.expiresAt,
      result: mailbox.result,
    };
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function mailbox(env: Env, requestId: string): DurableObjectStub<ResultMailbox> {
  return env.RESULT_MAILBOX.getByName(requestId);
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function errorResponse(error: unknown): Response {
  const message = error instanceof Error ? error.message : "UNKNOWN_ERROR";
  switch (message) {
    case "REQUEST_NOT_FOUND":
      return json({ error: "request_not_found" }, 404);
    case "INVALID_RETURN_TOKEN":
      return json({ error: "invalid_return_token" }, 403);
    case "REQUEST_ALREADY_EXISTS":
      return json({ error: "request_already_exists" }, 409);
    default:
      return json({ error: "bridge_error" }, 500);
  }
}

async function registerRequest(request: Request, env: Env): Promise<Response> {
  if ((request.headers.get("content-type") ?? "").split(";", 1)[0] !== "application/json") {
    return json({ error: "content_type_must_be_json" }, 415);
  }
  if (Number(request.headers.get("content-length") ?? "0") > 8_192) {
    return json({ error: "request_too_large" }, 413);
  }

  let body: RegisterBody;
  try {
    body = (await request.json()) as RegisterBody;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (!isValidRequestId(body.requestId) || !isValidReturnToken(body.returnToken)) {
    return json({ error: "invalid_request_capability" }, 400);
  }

  const expiresAt = Date.now() + REQUEST_LIFETIME_MS;
  try {
    await mailbox(env, body.requestId).register(await sha256(body.returnToken), expiresAt);
  } catch (error) {
    return errorResponse(error);
  }
  return json({ status: "pending", requestId: body.requestId, expiresAt: new Date(expiresAt).toISOString() }, 201);
}

async function readRequest(request: Request, env: Env, requestId: string): Promise<Response> {
  const returnToken = new URL(request.url).searchParams.get("token") ?? "";
  if (!isValidRequestId(requestId) || !isValidReturnToken(returnToken)) {
    return json({ error: "invalid_request_capability" }, 400);
  }

  try {
    const state = await mailbox(env, requestId).read(await sha256(returnToken));
    const status = state.status === "pending" ? 202 : state.status === "expired" ? 410 : 200;
    return json(
      {
        status: state.status,
        requestId,
        expiresAt: new Date(state.expiresAt).toISOString(),
        result: state.result,
      },
      status,
    );
  } catch (error) {
    return errorResponse(error);
  }
}

async function completeRequest(body: CompleteBody, env: Env): Promise<MailboxRead> {
  if (!isValidRequestId(body.requestId) || !isValidReturnToken(body.returnToken)) {
    throw new Error("INVALID_REQUEST_CAPABILITY");
  }

  const result: TownResult = {
    message: body.message,
    links: body.links,
    completedAt: new Date().toISOString(),
  };
  return mailbox(env, body.requestId).complete(await sha256(body.returnToken), result);
}

function mcpServer(env: Env): McpServer {
  const server = new McpServer({ name: "Convos Town Return Bridge", version: "0.1.0" });
  server.registerTool(
    "return_result",
    {
      description:
        "Return the final answer for a Convos webhook request. Call this exactly once after completing the task. Copy request_id and return_token exactly from the webhook payload. Never invent or reuse either value.",
      inputSchema: {
        request_id: z.string().min(20).max(100),
        return_token: z.string().min(32).max(200),
        message: z.string().min(1).max(100_000),
        links: z
          .array(
            z.object({
              title: z.string().min(1).max(200).optional(),
              url: z.url().max(2_048).refine((value) => value.startsWith("https://"), "Use an HTTPS URL"),
            }),
          )
          .max(12)
          .default([]),
      },
    },
    async ({ request_id, return_token, message, links }) => {
      try {
        const state = await completeRequest(
          {
            requestId: request_id,
            returnToken: return_token,
            message,
            links,
          },
          env,
        );
        if (state.status === "expired") {
          return {
            isError: true,
            content: [{ type: "text", text: "This Convos request expired. Ask the user to send it again." }],
          };
        }
        return {
          content: [{ type: "text", text: JSON.stringify({ accepted: true, status: state.status }) }],
        };
      } catch (error) {
        const code = error instanceof Error ? error.message : "UNKNOWN_ERROR";
        return {
          isError: true,
          content: [{ type: "text", text: JSON.stringify({ accepted: false, error: code }) }],
        };
      }
    },
  );
  return server;
}

export default {
  async fetch(request, env, context): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health" && request.method === "GET") {
      return json({ ok: true, service: "convos-town-bridge" });
    }
    if (url.pathname === "/v1/requests" && request.method === "POST") {
      return registerRequest(request, env);
    }
    const requestMatch = url.pathname.match(/^\/v1\/requests\/([A-Za-z0-9_-]+)$/);
    if (requestMatch && request.method === "GET") {
      return readRequest(request, env, requestMatch[1]);
    }
    if (url.pathname === "/mcp" || url.pathname.startsWith("/mcp/")) {
      return createMcpHandler(() => mcpServer(env), { route: "/mcp" })(request, env, context);
    }
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
