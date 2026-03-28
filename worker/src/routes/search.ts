/**
 * Message search — keyword + filter search across message history
 * Consolidated from PR #28
 */
import { Env } from "../types";
import { getIndex } from "../kv-index";

export async function handleGetSearch(request: Request, env: Env): Promise<Response> {
  // Authenticate
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return Response.json({ error: "Unauthorized", code: "UNAUTHORIZED" }, { status: 401 });
  }

  const url = new URL(request.url);
  const query = url.searchParams.get("q") || "";
  const fromFilter = url.searchParams.get("from");
  const toFilter = url.searchParams.get("to");
  const topicFilter = url.searchParams.get("topic");
  const since = url.searchParams.get("since");
  const limit = Math.min(parseInt(url.searchParams.get("limit") || "50"), 100);

  if (!query && !fromFilter && !toFilter && !topicFilter) {
    return Response.json(
      { error: "At least one filter required: q, from, to, or topic", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  try {
    const messageIds = await getIndex(env.MESSAGES, "_index:messages");
    const results: unknown[] = [];
    const queryLower = query.toLowerCase();

    // Scan messages (newest first for relevance)
    for (const msgId of [...messageIds].reverse()) {
      if (results.length >= limit) break;

      try {
        const raw = await env.MESSAGES.get(`msg:${msgId}`);
        if (!raw) continue;
        const msg = JSON.parse(raw);

        // Apply filters
        if (fromFilter && msg.from !== fromFilter) continue;
        if (toFilter && msg.to !== toFilter) continue;
        if (topicFilter && msg.topic !== topicFilter) continue;
        if (since && msg.ts < since) continue;

        // Text search in payload
        if (query) {
          const text = typeof msg.payload === "string" 
            ? msg.payload 
            : JSON.stringify(msg.payload);
          if (!text.toLowerCase().includes(queryLower)) continue;
        }

        results.push({
          id: msg.id,
          from: msg.from,
          to: msg.to,
          topic: msg.topic,
          ts: msg.ts,
          preview: extractPreview(msg.payload, query),
        });
      } catch {
        // Skip bad messages
      }
    }

    return Response.json({
      query,
      filters: { from: fromFilter, to: toFilter, topic: topicFilter, since },
      results,
      total: results.length,
      ts: new Date().toISOString(),
    });
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : "Search error", code: "INTERNAL_ERROR" },
      { status: 500 }
    );
  }
}

function extractPreview(payload: unknown, query: string): string {
  const text = typeof payload === "string" 
    ? payload 
    : (payload as any)?.text || JSON.stringify(payload);
  
  if (!query) return text.slice(0, 200);
  
  const idx = text.toLowerCase().indexOf(query.toLowerCase());
  if (idx < 0) return text.slice(0, 200);
  
  const start = Math.max(0, idx - 50);
  const end = Math.min(text.length, idx + query.length + 50);
  return (start > 0 ? "..." : "") + text.slice(start, end) + (end < text.length ? "..." : "");
}
