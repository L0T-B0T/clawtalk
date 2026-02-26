import { Env, AgentRecord, AgentPublic } from "../types";
import {
  validateAdminKey,
  validateAgentKey,
  generateApiKey,
  hashApiKey,
} from "../auth";

export async function handlePostAgent(
  request: Request,
  env: Env
): Promise<Response> {
  if (!(await validateAdminKey(request, env))) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  let body: {
    name?: string;
    owner?: string;
    publicKey?: string;
    signingKey?: string;
    capabilities?: string[];
    webhookUrl?: string;
  };

  try {
    body = await request.json();
  } catch {
    return Response.json(
      { error: "Invalid JSON body", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  if (!body.name || !body.owner || !body.publicKey || !body.signingKey) {
    return Response.json(
      {
        error: "Missing required fields: name, owner, publicKey, signingKey",
        code: "BAD_REQUEST",
      },
      { status: 400 }
    );
  }

  const existing = await env.AGENTS.get(`agent:${body.name}`);
  if (existing) {
    return Response.json(
      { error: "Agent already exists", code: "CONFLICT" },
      { status: 409 }
    );
  }

  const apiKey = generateApiKey();
  const apiKeyHash = await hashApiKey(apiKey);

  const record: AgentRecord = {
    name: body.name,
    owner: body.owner,
    publicKey: body.publicKey,
    signingKey: body.signingKey,
    capabilities: body.capabilities,
    webhookUrl: body.webhookUrl,
    apiKeyHash,
    lastSeen: new Date().toISOString(),
    createdAt: new Date().toISOString(),
  };

  await env.AGENTS.put(`agent:${body.name}`, JSON.stringify(record));
  await env.AGENTS.put(`apikey:${apiKeyHash}`, body.name);

  return Response.json({ name: body.name, apiKey }, { status: 201 });
}

export async function handlePatchAgent(
  request: Request,
  env: Env,
  agentName: string
): Promise<Response> {
  // Agent can update own record, or admin can update any
  const callerName = await validateAgentKey(request, env);
  const isAdmin = await validateAdminKey(request, env);

  if (!callerName && !isAdmin) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  // Non-admin can only update their own record
  if (!isAdmin && callerName !== agentName) {
    return Response.json(
      { error: "Forbidden: can only update own agent", code: "FORBIDDEN" },
      { status: 403 }
    );
  }

  const raw = await env.AGENTS.get(`agent:${agentName}`);
  if (!raw) {
    return Response.json(
      { error: "Agent not found", code: "NOT_FOUND" },
      { status: 404 }
    );
  }

  let body: {
    webhookUrl?: string | null;
    capabilities?: string[];
    publicKey?: string;
    signingKey?: string;
  };

  try {
    body = await request.json();
  } catch {
    return Response.json(
      { error: "Invalid JSON body", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  const record: AgentRecord = JSON.parse(raw);

  // Update allowed fields
  if (body.webhookUrl !== undefined) {
    record.webhookUrl = body.webhookUrl === null ? undefined : body.webhookUrl;
  }
  if (body.capabilities !== undefined) {
    record.capabilities = body.capabilities;
  }
  if (body.publicKey !== undefined) {
    record.publicKey = body.publicKey;
  }
  if (body.signingKey !== undefined) {
    record.signingKey = body.signingKey;
  }

  record.lastSeen = new Date().toISOString();

  await env.AGENTS.put(`agent:${agentName}`, JSON.stringify(record));

  return Response.json({ name: agentName, updated: true });
}

export async function handleGetAgents(
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

  const list = await env.AGENTS.list({ prefix: "agent:" });
  const agents: AgentPublic[] = [];

  for (const key of list.keys) {
    const raw = await env.AGENTS.get(key.name);
    if (!raw) continue;

    const record: AgentRecord = JSON.parse(raw);
    const lastSeenTime = new Date(record.lastSeen).getTime();
    const fiveMinutesAgo = Date.now() - 5 * 60 * 1000;

    agents.push({
      name: record.name,
      capabilities: record.capabilities,
      publicKey: record.publicKey,
      signingKey: record.signingKey,
      online: lastSeenTime > fiveMinutesAgo,
      lastSeen: record.lastSeen,
    });
  }

  return Response.json(agents);
}
