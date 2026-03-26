import { Env, MessageEnvelope } from "../types";
import { validateAgentKey, validateAdminKey } from "../auth";
import { getIndex } from "../kv-index";

const MAX_RESULTS = 50;

/**
 * GET /messages/search — Full-text keyword search across message history.
 *
 * Query params:
 *   q        — keyword(s) to search for in payload text (required)
 *   from     — filter by sender agent name (optional)
 *   topic    — filter by topic (optional)
 *   before   — ISO-8601 timestamp upper bound (optional)
 *   after    — ISO-8601 timestamp lower bound (optional)
 *   limit    — max results, default 20, max 50 (optional)
 *
 * Search is case-insensitive and matches substrings within
 * the payload text (for unencrypted messages only).
 * Encrypted messages are excluded from keyword matching but
 * can still be found via from/topic/date filters when q is omitted.
 *
 * Returns: { results: MessageEnvelope[], count: number, query: object }
 */
export async function handleSearchMessages(
  request: Request,
  env: Env
): Promise<Response> {
  // Auth: agent sees own messages, admin sees all
  const isAdmin = await validateAdminKey(request, env);
  const agentName = isAdmin ? null : await validateAgentKey(request, env);
  if (!isAdmin && !agentName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const url = new URL(request.url);
  const q = url.searchParams.get("q")?.trim() || "";
  const fromFilter = url.searchParams.get("from")?.trim() || "";
  const topicFilter = url.searchParams.get("topic")?.trim() || "";
  const beforeParam = url.searchParams.get("before") || "";
  const afterParam = url.searchParams.get("after") || "";
  const limit = Math.min(
    Math.max(parseInt(url.searchParams.get("limit") || "20", 10), 1),
    MAX_RESULTS
  );

  // Must have at least one filter
  if (!q && !fromFilter && !topicFilter && !beforeParam && !afterParam) {
    return Response.json(
      {
        error: "At least one search parameter required (q, from, topic, before, after)",
        code: "BAD_REQUEST",
      },
      { status: 400 }
    );
  }

  const beforeTime = beforeParam ? new Date(beforeParam).getTime() : Infinity;
  const afterTime = afterParam ? new Date(afterParam).getTime() : 0;

  if (beforeParam && isNaN(beforeTime)) {
    return Response.json(
      { error: "Invalid 'before' timestamp", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }
  if (afterParam && isNaN(afterTime)) {
    return Response.json(
      { error: "Invalid 'after' timestamp", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  // Determine which index to scan
  const indexKey = isAdmin
    ? "_index:messages:global"
    : `_index:messages:${agentName}`;
  const keyNames = await getIndex(env.MESSAGES, indexKey);

  // Scan newest first (keys are chronological, reverse for newest-first)
  const reversed = [...keyNames].reverse();
  const qLower = q.toLowerCase();
  const results: MessageEnvelope[] = [];

  for (const keyName of reversed) {
    if (results.length >= limit) break;

    const raw = await env.MESSAGES.get(keyName);
    if (!raw) continue;

    const msg: MessageEnvelope = JSON.parse(raw);
    const msgTime = new Date(msg.ts).getTime();

    // Date filters
    if (msgTime >= beforeTime) continue;
    if (msgTime <= afterTime) continue;

    // Sender filter
    if (fromFilter && msg.from.toLowerCase() !== fromFilter.toLowerCase()) {
      continue;
    }

    // Topic filter
    if (topicFilter && (!msg.topic || msg.topic.toLowerCase() !== topicFilter.toLowerCase())) {
      continue;
    }

    // Keyword search in payload text
    if (q) {
      if (msg.encrypted) continue; // can't search encrypted content

      const payloadText = extractPayloadText(msg.payload);
      if (!payloadText.toLowerCase().includes(qLower)) continue;
    }

    results.push(msg);
  }

  return Response.json({
    results,
    count: results.length,
    query: {
      q: q || undefined,
      from: fromFilter || undefined,
      topic: topicFilter || undefined,
      before: beforeParam || undefined,
      after: afterParam || undefined,
      limit,
    },
  });
}

/**
 * Extract searchable text from a message payload.
 * Handles both string payloads and { text: string } objects.
 */
function extractPayloadText(payload: string | object): string {
  if (typeof payload === "string") return payload;
  if (typeof payload === "object" && payload !== null) {
    // Check common text fields
    const obj = payload as Record<string, unknown>;
    if (typeof obj.text === "string") return obj.text;
    if (typeof obj.message === "string") return obj.message;
    if (typeof obj.body === "string") return obj.body;
    // Fallback: stringify the whole thing
    return JSON.stringify(payload);
  }
  return "";
}
