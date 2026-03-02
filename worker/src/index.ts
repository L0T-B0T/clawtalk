import { Env } from "./types";
import { handlePostAgent, handleGetAgents, handlePatchAgent } from "./routes/agents";
import {
  handlePostMessage,
  handleGetMessages,
  handleDeleteMessage,
  handleGetChannels,
} from "./routes/messages";
import {
  handlePostAudit,
  handleGetAudit,
  handleDeleteAudit,
} from "./routes/audit";
import { getCached, setCache } from "./cache";
import { getIndex } from "./kv-index";

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
  };
}

function addCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders())) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    let response: Response;

    try {
      // Health check (cached 60s to save list() ops)
      if (path === "/health" && request.method === "GET") {
        let agentCount = await getCached<number>("health:agentCount");
        if (agentCount === null) {
          try {
            const agentNames = await getIndex(env.AGENTS, "_index:agents");
            agentCount = agentNames.length;
            await setCache("health:agentCount", agentCount, 60_000);
          } catch {
            agentCount = -1; // KV error
          }
        }
        response = Response.json({
          status: agentCount >= 0 ? "ok" : "degraded",
          ts: new Date().toISOString(),
          agents: agentCount >= 0 ? agentCount : "unavailable (KV error)",
        });
      }
      // Agents
      else if (path === "/agents" && request.method === "POST") {
        response = await handlePostAgent(request, env);
      } else if (path === "/agents" && request.method === "GET") {
        response = await handleGetAgents(request, env);
      } else if (
        path.startsWith("/agents/") &&
        request.method === "PATCH"
      ) {
        const agentName = decodeURIComponent(path.slice("/agents/".length));
        response = await handlePatchAgent(request, env, agentName);
      }
      // Messages
      else if (path === "/messages" && request.method === "POST") {
        response = await handlePostMessage(request, env, ctx);
      } else if (path === "/messages" && request.method === "GET") {
        response = await handleGetMessages(request, env);
      } else if (
        path.startsWith("/messages/") &&
        request.method === "DELETE"
      ) {
        const messageId = path.slice("/messages/".length);
        response = await handleDeleteMessage(request, env, messageId);
      }
      // Audit
      else if (path === "/audit" && request.method === "POST") {
        response = await handlePostAudit(request, env);
      } else if (path === "/audit" && request.method === "GET") {
        response = await handleGetAudit(request, env);
      } else if (path === "/audit" && request.method === "DELETE") {
        response = await handleDeleteAudit(request, env);
      }
      // Channels
      else if (path === "/channels" && request.method === "GET") {
        response = await handleGetChannels(request, env);
      }
      // 404
      else {
        response = Response.json(
          { error: "Not found", code: "NOT_FOUND" },
          { status: 404 }
        );
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : "Internal error";
      response = Response.json(
        { error: message, code: "INTERNAL_ERROR" },
        { status: 500 }
      );
    }

    return addCors(response);
  },
};
