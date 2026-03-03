import { Env, AgentRecord, InviteRecord } from "../types";
import { generateApiKey, hashApiKey } from "../auth";
import { invalidate } from "../cache";
import { addToIndex } from "../kv-index";

const NAME_REGEX = /^[a-zA-Z0-9_-]{2,32}$/;

export async function handleRegister(
  request: Request,
  env: Env
): Promise<Response> {
  let body: {
    invite?: string;
    name?: string;
    owner?: string;
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

  // Validate required fields
  if (!body.invite) {
    return Response.json(
      { error: "Missing invite code", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  if (!body.name) {
    return Response.json(
      { error: "Missing agent name", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  if (!NAME_REGEX.test(body.name)) {
    return Response.json(
      {
        error:
          "Invalid agent name. Use 2-32 characters: letters, numbers, hyphens, underscores.",
        code: "BAD_REQUEST",
      },
      { status: 400 }
    );
  }

  // Validate invite
  const inviteRaw = await env.AGENTS.get(`invite:${body.invite}`);
  if (!inviteRaw) {
    return Response.json(
      { error: "Invalid or expired invite code", code: "FORBIDDEN" },
      { status: 403 }
    );
  }

  const invite: InviteRecord = JSON.parse(inviteRaw);

  // Check expiry
  if (invite.expiresAt && new Date(invite.expiresAt) < new Date()) {
    return Response.json(
      { error: "Invite code has expired", code: "FORBIDDEN" },
      { status: 403 }
    );
  }

  // Check max uses
  if (invite.maxUses !== undefined && invite.uses >= invite.maxUses) {
    return Response.json(
      { error: "Invite code has reached its usage limit", code: "FORBIDDEN" },
      { status: 403 }
    );
  }

  // Check if agent name already taken
  const existing = await env.AGENTS.get(`agent:${body.name}`);
  if (existing) {
    return Response.json(
      { error: "Agent name already taken", code: "CONFLICT" },
      { status: 409 }
    );
  }

  // Create the agent
  const apiKey = generateApiKey();
  const apiKeyHash = await hashApiKey(apiKey);

  const record: AgentRecord = {
    name: body.name,
    owner: body.owner || "invited",
    publicKey: "",
    signingKey: "",
    webhookUrl: body.webhookUrl,
    apiKeyHash,
    lastSeen: new Date().toISOString(),
    createdAt: new Date().toISOString(),
  };

  await env.AGENTS.put(`agent:${body.name}`, JSON.stringify(record));
  await env.AGENTS.put(`apikey:${apiKeyHash}`, body.name);
  await addToIndex(env.AGENTS, "_index:agents", body.name);

  // Increment invite usage
  invite.uses += 1;
  await env.AGENTS.put(`invite:${body.invite}`, JSON.stringify(invite));

  // Invalidate caches
  invalidate("agents:");
  invalidate("health:");

  return Response.json({ name: body.name, apiKey }, { status: 201 });
}
