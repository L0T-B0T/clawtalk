import { Env, AgentRecord, AgentPublic } from "../types";
import {
  validateAdminKey,
  validateAgentKey,
  generateApiKey,
  hashApiKey,
} from "../auth";
import { getCached, setCache, invalidate } from "../cache";
import { getIndex, addToIndex } from "../kv-index";

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
    webhookToken?: string;
    webhookSecret?: string;
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
    webhookToken: body.webhookToken,
    webhookSecret: body.webhookSecret,
    apiKeyHash,
    lastSeen: new Date().toISOString(),
    createdAt: new Date().toISOString(),
  };

  await env.AGENTS.put(`agent:${body.name}`, JSON.stringify(record));
  await env.AGENTS.put(`apikey:${apiKeyHash}`, body.name);
  await addToIndex(env.AGENTS, "_index:agents", body.name);
  invalidate("agents:");
  invalidate("health:");

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
    webhookToken?: string | null;
    webhookSecret?: string | null;
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
  if (body.webhookToken !== undefined) {
    record.webhookToken = body.webhookToken === null ? undefined : body.webhookToken;
  }
  if (body.webhookSecret !== undefined) {
    record.webhookSecret = body.webhookSecret === null ? undefined : body.webhookSecret;
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

  // Cache agent list for 30s (online status recalculated from cached records)
  let agentRecords = await getCached<AgentRecord[]>("agents:records");
  if (!agentRecords) {
    try {
      const agentNames = await getIndex(env.AGENTS, "_index:agents");
      agentRecords = [];
      for (const name of agentNames) {
        const raw = await env.AGENTS.get(`agent:${name}`);
        if (!raw) continue;
        agentRecords.push(JSON.parse(raw));
      }
      await setCache("agents:records", agentRecords, 30_000);
    } catch {
      agentRecords = []; // KV quota exceeded — return empty
    }
  }

  // Overlay cached lastSeen (from Cache API) on top of KV records.
  // This ensures "online" status reflects real-time activity even when
  // agent records are cached, without burning KV writes on every poll.
  const agents: AgentPublic[] = [];
  const fiveMinutesAgo = Date.now() - 5 * 60 * 1000;

  for (const record of agentRecords) {
    const cachedLastSeen = await getCached<string>(`lastSeen:${record.name}`);
    let effectiveLastSeen = record.lastSeen;

    if (cachedLastSeen) {
      const cachedTime = new Date(cachedLastSeen).getTime();
      const kvTime = new Date(record.lastSeen).getTime();
      if (cachedTime > kvTime) {
        effectiveLastSeen = cachedLastSeen;
      }
    }

    agents.push({
      name: record.name,
      capabilities: record.capabilities,
      publicKey: record.publicKey,
      signingKey: record.signingKey,
      online: new Date(effectiveLastSeen).getTime() > fiveMinutesAgo,
      lastSeen: effectiveLastSeen,
    });
  }

  return Response.json(agents);
}
