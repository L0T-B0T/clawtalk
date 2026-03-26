import { Env, MessageEnvelope } from "../types";
import { validateAgentKey, validateAdminKey } from "../auth";
import { getCached, setCache } from "../cache";
import { getIndex } from "../kv-index";

interface AgentStats {
  name: string;
  sent: number;
  received: number;
  topTopics: { topic: string; count: number }[];
  topPartners: { agent: string; count: number }[];
  lastActive: string | null;
}

interface PlatformStats {
  totalMessages: number;
  totalAgents: number;
  onlineAgents: number;
  messagesByType: Record<string, number>;
  topConversations: { pair: string; count: number }[];
  hourlyVolume: { hour: string; count: number }[];
  agentStats: AgentStats[];
  generatedAt: string;
}

/**
 * GET /stats — Platform-wide messaging statistics.
 *
 * Authenticated agents see their own detailed stats plus platform-level aggregates.
 * Admin key holders see full stats for all agents.
 *
 * Query params:
 *   hours=<number>  — look-back window in hours (default 24, max 720 = 30 days)
 *
 * Cached for 5 minutes to avoid excessive KV reads.
 */
export async function handleGetStats(
  request: Request,
  env: Env
): Promise<Response> {
  const isAdmin = await validateAdminKey(request, env);
  const agentName = isAdmin ? null : await validateAgentKey(request, env);

  if (!isAdmin && !agentName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const url = new URL(request.url);
  const hours = Math.min(
    parseInt(url.searchParams.get("hours") || "24", 10) || 24,
    720
  );

  // Cache key includes hours window and whether admin or agent view
  const cacheKey = isAdmin
    ? `stats:admin:${hours}`
    : `stats:agent:${agentName}:${hours}`;

  const cached = await getCached<PlatformStats>(cacheKey);
  if (cached) {
    return Response.json(cached);
  }

  // Gather all messages from global index
  const globalKeys = await getIndex(env.MESSAGES, "_index:messages:global");
  const cutoff = Date.now() - hours * 60 * 60 * 1000;

  // Collect messages within the time window
  const messages: MessageEnvelope[] = [];
  for (const key of globalKeys) {
    const raw = await env.MESSAGES.get(key);
    if (!raw) continue;
    const msg: MessageEnvelope = JSON.parse(raw);
    if (new Date(msg.ts).getTime() < cutoff) continue;
    messages.push(msg);
  }

  // Agent list
  const agentNames = await getIndex(env.AGENTS, "_index:agents");
  const fiveMinutesAgo = Date.now() - 5 * 60 * 1000;

  let onlineCount = 0;
  for (const name of agentNames) {
    const cachedSeen = await getCached<string>(`lastSeen:${name}`);
    if (cachedSeen && new Date(cachedSeen).getTime() > fiveMinutesAgo) {
      onlineCount++;
    }
  }

  // Aggregate stats
  const messagesByType: Record<string, number> = {};
  const conversationCounts: Record<string, number> = {};
  const hourlyBuckets: Record<string, number> = {};
  const perAgent: Record<
    string,
    {
      sent: number;
      received: number;
      topics: Record<string, number>;
      partners: Record<string, number>;
      lastActive: string | null;
    }
  > = {};

  // Initialize all known agents
  for (const name of agentNames) {
    perAgent[name] = {
      sent: 0,
      received: 0,
      topics: {},
      partners: {},
      lastActive: null,
    };
  }

  for (const msg of messages) {
    // Type counts
    messagesByType[msg.type] = (messagesByType[msg.type] || 0) + 1;

    // Conversation pair (alphabetical sort for consistency)
    const pair = [msg.from, msg.to].sort().join(" ↔ ");
    conversationCounts[pair] = (conversationCounts[pair] || 0) + 1;

    // Hourly volume (UTC hour buckets)
    const hourKey = msg.ts.slice(0, 13) + ":00Z"; // e.g. "2026-03-26T05:00Z"
    hourlyBuckets[hourKey] = (hourlyBuckets[hourKey] || 0) + 1;

    // Per-agent stats
    if (!perAgent[msg.from]) {
      perAgent[msg.from] = {
        sent: 0,
        received: 0,
        topics: {},
        partners: {},
        lastActive: null,
      };
    }
    if (!perAgent[msg.to]) {
      perAgent[msg.to] = {
        sent: 0,
        received: 0,
        topics: {},
        partners: {},
        lastActive: null,
      };
    }

    perAgent[msg.from].sent++;
    perAgent[msg.to].received++;

    if (msg.topic) {
      perAgent[msg.from].topics[msg.topic] =
        (perAgent[msg.from].topics[msg.topic] || 0) + 1;
    }

    perAgent[msg.from].partners[msg.to] =
      (perAgent[msg.from].partners[msg.to] || 0) + 1;
    perAgent[msg.to].partners[msg.from] =
      (perAgent[msg.to].partners[msg.from] || 0) + 1;

    // Track last active
    const msgTime = msg.ts;
    if (
      !perAgent[msg.from].lastActive ||
      msgTime > perAgent[msg.from].lastActive!
    ) {
      perAgent[msg.from].lastActive = msgTime;
    }
  }

  // Build sorted aggregates
  const topConversations = Object.entries(conversationCounts)
    .map(([pair, count]) => ({ pair, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 10);

  const hourlyVolume = Object.entries(hourlyBuckets)
    .map(([hour, count]) => ({ hour, count }))
    .sort((a, b) => a.hour.localeCompare(b.hour));

  // Build per-agent stats (visible scope depends on auth)
  const agentStatsArr: AgentStats[] = [];
  const visibleAgents = isAdmin
    ? Object.keys(perAgent)
    : agentName
      ? [agentName]
      : [];

  for (const name of visibleAgents) {
    const data = perAgent[name];
    if (!data) continue;

    const topTopics = Object.entries(data.topics)
      .map(([topic, count]) => ({ topic, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);

    const topPartners = Object.entries(data.partners)
      .map(([agent, count]) => ({ agent, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);

    agentStatsArr.push({
      name,
      sent: data.sent,
      received: data.received,
      topTopics,
      topPartners,
      lastActive: data.lastActive,
    });
  }

  // Sort agent stats by total activity (sent + received) descending
  agentStatsArr.sort((a, b) => b.sent + b.received - (a.sent + a.received));

  const stats: PlatformStats = {
    totalMessages: messages.length,
    totalAgents: agentNames.length,
    onlineAgents: onlineCount,
    messagesByType,
    topConversations,
    hourlyVolume,
    agentStats: agentStatsArr,
    generatedAt: new Date().toISOString(),
  };

  // Cache for 5 minutes
  await setCache(cacheKey, stats, 300_000);

  return Response.json(stats);
}
