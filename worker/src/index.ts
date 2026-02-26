import { Env } from "./types";
import { handlePostAgent, handleGetAgents } from "./routes/agents";
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

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
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
      // Health check
      if (path === "/health" && request.method === "GET") {
        const list = await env.AGENTS.list({ prefix: "agent:" });
        response = Response.json({
          status: "ok",
          ts: new Date().toISOString(),
          agents: list.keys.length,
        });
      }
      // Agents
      else if (path === "/agents" && request.method === "POST") {
        response = await handlePostAgent(request, env);
      } else if (path === "/agents" && request.method === "GET") {
        response = await handleGetAgents(request, env);
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
