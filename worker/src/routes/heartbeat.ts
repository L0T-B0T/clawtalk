/**
 * Lightweight presence heartbeat
 * Consolidated from PR #23
 */
import { Env } from "../types";
import { getIndex } from "../kv-index";

export async function handlePostHeartbeat(request: Request, env: Env): Promise<Response> {
  // Authenticate
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return Response.json({ error: "Unauthorized", code: "UNAUTHORIZED" }, { status: 401 });
  }
  const apiKey = authHeader.slice(7);
  const agentName = await resolveAgent(env, apiKey);
  if (!agentName) {
    return Response.json({ error: "Invalid API key", code: "UNAUTHORIZED" }, { status: 401 });
  }

  try {
    // Update agent's lastSeen
    const raw = await env.AGENTS.get(`agent:${agentName}`);
    if (!raw) {
      return Response.json({ error: "Agent not found", code: "NOT_FOUND" }, { status: 404 });
    }

    const agent = JSON.parse(raw);
    agent.lastSeen = new Date().toISOString();
    await env.AGENTS.put(`agent:${agentName}`, JSON.stringify(agent));

    // Count pending messages
    const messageIds = await getIndex(env.MESSAGES, "_index:messages");
    let pending = 0;

    // Check last 100 messages for unread ones to this agent
    for (const msgId of messageIds.slice(-100)) {
      try {
        const msgRaw = await env.MESSAGES.get(`msg:${msgId}`);
        if (msgRaw) {
          const msg = JSON.parse(msgRaw);
          if (msg.to === agentName && !msg.readAt) {
            pending++;
          }
        }
      } catch {
        // Skip bad messages
      }
    }

    return Response.json({
      status: "alive",
      agent: agentName,
      lastSeen: agent.lastSeen,
      pendingMessages: pending,
      ts: new Date().toISOString(),
    });
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : "Heartbeat error", code: "INTERNAL_ERROR" },
      { status: 500 }
    );
  }
}

async function resolveAgent(env: Env, apiKey: string): Promise<string | null> {
  const agentNames = await getIndex(env.AGENTS, "_index:agents");
  for (const name of agentNames) {
    try {
      const raw = await env.AGENTS.get(`agent:${name}`);
      if (raw) {
        const agent = JSON.parse(raw);
        const encoder = new TextEncoder();
        const data = encoder.encode(apiKey);
        const hashBuffer = await crypto.subtle.digest("SHA-256", data);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const hash = hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
        if (agent.apiKeyHash === hash) return name;
      }
    } catch {
      // Skip
    }
  }
  return null;
}
