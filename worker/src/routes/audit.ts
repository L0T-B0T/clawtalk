import { Env, AuditEntry } from "../types";
import { validateAgentKey, validateAdminKey } from "../auth";

const MAX_PAYLOAD_SIZE = 64 * 1024; // 64KB
const AUDIT_TTL = 2592000; // 30 days
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

export async function handlePostAudit(
  request: Request,
  env: Env
): Promise<Response> {
  const agentName = await validateAgentKey(request, env);
  if (!agentName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const bodyText = await request.text();
  if (bodyText.length > MAX_PAYLOAD_SIZE) {
    return Response.json(
      { error: "Payload exceeds 64KB limit", code: "PAYLOAD_TOO_LARGE" },
      { status: 400 }
    );
  }

  let body: {
    messageId?: string;
    direction?: "sent" | "received";
    from?: string;
    to?: string;
    topic?: string;
    correlationId?: string;
    payload?: object;
    ts?: string;
  };

  try {
    body = JSON.parse(bodyText);
  } catch {
    return Response.json(
      { error: "Invalid JSON body", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  if (
    !body.messageId ||
    !body.direction ||
    !body.from ||
    !body.to ||
    !body.payload ||
    !body.ts
  ) {
    return Response.json(
      {
        error:
          "Missing required fields: messageId, direction, from, to, payload, ts",
        code: "BAD_REQUEST",
      },
      { status: 400 }
    );
  }

  if (!["sent", "received"].includes(body.direction)) {
    return Response.json(
      { error: "Invalid direction, must be 'sent' or 'received'", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  const entry: AuditEntry = {
    messageId: body.messageId,
    direction: body.direction,
    from: body.from,
    to: body.to,
    topic: body.topic,
    correlationId: body.correlationId,
    payload: body.payload,
    ts: body.ts,
    loggedBy: agentName,
    loggedAt: new Date().toISOString(),
  };

  // Key format: audit:{timestamp}:{messageId}:{direction}
  const sortableTs = new Date(body.ts).getTime().toString().padStart(15, "0");
  const key = `audit:${sortableTs}:${body.messageId}:${body.direction}`;

  await env.AUDIT.put(key, JSON.stringify(entry), {
    expirationTtl: AUDIT_TTL,
  });

  return Response.json({ ok: true }, { status: 201 });
}

export async function handleGetAudit(
  request: Request,
  env: Env
): Promise<Response> {
  if (!(await validateAdminKey(request, env))) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const url = new URL(request.url);
  const since = url.searchParams.get("since");
  const limit = Math.min(
    parseInt(url.searchParams.get("limit") || String(DEFAULT_LIMIT), 10),
    MAX_LIMIT
  );
  const fromFilter = url.searchParams.get("from");
  const toFilter = url.searchParams.get("to");
  const topicFilter = url.searchParams.get("topic");

  const list = await env.AUDIT.list({ prefix: "audit:", limit: 1000 });

  const sinceTime = since ? new Date(since).getTime() : 0;
  const entries: AuditEntry[] = [];

  for (const key of list.keys) {
    if (entries.length >= limit) break;

    const raw = await env.AUDIT.get(key.name);
    if (!raw) continue;

    const entry: AuditEntry = JSON.parse(raw);

    if (sinceTime && new Date(entry.ts).getTime() <= sinceTime) continue;
    if (fromFilter && entry.from !== fromFilter) continue;
    if (toFilter && entry.to !== toFilter) continue;
    if (topicFilter && entry.topic !== topicFilter) continue;

    entries.push(entry);
  }

  const cursor =
    entries.length > 0 ? entries[entries.length - 1].loggedAt : undefined;

  return Response.json({ entries, cursor });
}

export async function handleDeleteAudit(
  request: Request,
  env: Env
): Promise<Response> {
  if (!(await validateAdminKey(request, env))) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const url = new URL(request.url);
  const before = url.searchParams.get("before");

  if (!before) {
    return Response.json(
      { error: "Missing required query param: before", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  const beforeTime = new Date(before).getTime();
  const list = await env.AUDIT.list({ prefix: "audit:", limit: 1000 });

  let deleted = 0;
  for (const key of list.keys) {
    const raw = await env.AUDIT.get(key.name);
    if (!raw) continue;

    const entry: AuditEntry = JSON.parse(raw);
    if (new Date(entry.ts).getTime() < beforeTime) {
      await env.AUDIT.delete(key.name);
      deleted++;
    }
  }

  return Response.json({ deleted });
}
