/**
 * Platform-wide messaging analytics
 * Consolidated from PR #22
 */
import { Env } from "../types";
import { getIndex } from "../kv-index";

export async function handleGetStats(request: Request, env: Env): Promise<Response> {
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

  const url = new URL(request.url);
  const scope = url.searchParams.get("scope") || "platform";

  try {
    // Get all agent names
    const agentNames = await getIndex(env.AGENTS, "_index:agents");

    // Get message count from index
    const messageIndex = await getIndex(env.MESSAGES, "_index:messages");

    // Basic platform stats
    const stats: Record<string, unknown> = {
      platform: {
        totalAgents: agentNames.length,
        totalMessages: messageIndex.length,
        activeAgents: 0,
        ts: new Date().toISOString(),
      },
    };

    // Count active agents (lastSeen within 24h)
    const now = Date.now();
    const dayMs = 24 * 60 * 60 * 1000;
    let activeCount = 0;

    for (const name of agentNames) {
      try {
        const raw = await env.AGENTS.get(`agent:${name}`);
        if (raw) {
          const agent = JSON.parse(raw);
          if (agent.lastSeen && now - new Date(agent.lastSeen).getTime() < dayMs) {
            activeCount++;
          }
        }
      } catch {
        // Skip agents with bad data
      }
    }

    stats.platform = { ...stats.platform as object, activeAgents: activeCount };

    // Per-agent stats if requested
    if (scope === "agent") {
      const targetAgent = url.searchParams.get("agent") || agentName;
      const messages = await getIndex(env.MESSAGES, "_index:messages");
      let sent = 0;
      let received = 0;

      for (const msgId of messages.slice(-500)) {
        try {
          const raw = await env.MESSAGES.get(`msg:${msgId}`);
          if (raw) {
            const msg = JSON.parse(raw);
            if (msg.from === targetAgent) sent++;
            if (msg.to === targetAgent) received++;
          }
        } catch {
          // Skip bad messages
        }
      }

      stats.agent = {
        name: targetAgent,
        messagesSent: sent,
        messagesReceived: received,
        total: sent + received,
      };
    }

    return Response.json(stats);
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : "Stats error", code: "INTERNAL_ERROR" },
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
        // Simple hash comparison
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
