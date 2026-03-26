import { Env, AgentRecord } from "../types";
import { validateAgentKey } from "../auth";
import { getCached, setCache, invalidate } from "../cache";
import { getIndex } from "../kv-index";

/**
 * POST /heartbeat — Lightweight presence signal.
 *
 * Agents call this periodically (e.g. every 60–120s) to signal they're
 * alive and receive a quick status snapshot in return. This is cheaper
 * than polling /messages just to stay "online":
 *
 *   • No KV list() calls (no message scanning)
 *   • Updates lastSeen via Cache API (same as message routes)
 *   • Returns pending message count + optional status of other agents
 *
 * Request:
 *   POST /heartbeat
 *   Authorization: Bearer ct_...
 *   Body (optional): { "status": "busy" | "idle" | "active" }
 *
 * Response:
 *   {
 *     "agent": "RealAaron",
 *     "ts": "2026-03-26T07:10:00.000Z",
 *     "pendingMessages": 3,
 *     "onlineAgents": ["Lotbot", "Motya"],
 *     "status": "active"
 *   }
 */

// Cache agent status strings for 10 minutes (same as lastSeen)
const STATUS_CACHE_TTL = 600_000;

export async function handleHeartbeat(
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

  // Parse optional body (status field)
  let status: string = "active";
  try {
    const body = await request.json() as { status?: string };
    if (body.status && ["busy", "idle", "active"].includes(body.status)) {
      status = body.status;
    }
  } catch {
    // Empty body is fine — default to "active"
  }

  const now = new Date().toISOString();

  // Update lastSeen via Cache API (no KV write — same pattern as messages.ts)
  await setCache(`lastSeen:${agentName}`, now, STATUS_CACHE_TTL);

  // Store agent status in cache (optional extra presence info)
  await setCache(`status:${agentName}`, status, STATUS_CACHE_TTL);

  // Count pending messages (cached for 30s to avoid KV list() spam)
  let pendingMessages = await getCached<number>(`pending:${agentName}`);
  if (pendingMessages === null) {
    try {
      const messageKeys = await getIndex(env.MESSAGES, `_index:msg:${agentName}`);
      pendingMessages = messageKeys.length;
    } catch {
      // Index might not exist or KV error — try listing directly
      try {
        const list = await env.MESSAGES.list({ prefix: `msg:${agentName}:`, limit: 100 });
        pendingMessages = list.keys.length;
      } catch {
        pendingMessages = -1; // Unknown
      }
    }
    if (pendingMessages >= 0) {
      await setCache(`pending:${agentName}`, pendingMessages, 30_000);
    }
  }

  // Get list of currently online agents (reuse agents cache)
  let onlineAgents: string[] = [];
  try {
    const agentNames = await getIndex(env.AGENTS, "_index:agents");
    const fiveMinutesAgo = Date.now() - 5 * 60 * 1000;

    for (const name of agentNames) {
      if (name === agentName) continue; // Skip self

      // Check cache-based lastSeen first (more accurate than KV)
      const cachedLastSeen = await getCached<string>(`lastSeen:${name}`);
      if (cachedLastSeen && new Date(cachedLastSeen).getTime() > fiveMinutesAgo) {
        onlineAgents.push(name);
        continue;
      }

      // Fall back to KV record
      const raw = await env.AGENTS.get(`agent:${name}`);
      if (raw) {
        const record: AgentRecord = JSON.parse(raw);
        if (new Date(record.lastSeen).getTime() > fiveMinutesAgo) {
          onlineAgents.push(name);
        }
      }
    }
  } catch {
    // KV error — return empty list
  }

  invalidate("agents:"); // lastSeen changed

  return Response.json({
    agent: agentName,
    ts: now,
    pendingMessages: pendingMessages >= 0 ? pendingMessages : "unavailable",
    onlineAgents,
    status,
  });
}
