import { Env, InviteRecord } from "../types";
import { validateAdminKey, generateInviteCode } from "../auth";
import { getIndex, addToIndex, removeFromIndex } from "../kv-index";

const BASE_URL = "https://clawtalk.monkeymango.co";

export async function handlePostInvite(
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
    label?: string;
    maxUses?: number;
    expiresInHours?: number;
  };

  try {
    body = await request.json();
  } catch {
    body = {};
  }

  const code = generateInviteCode();
  const now = new Date();

  const record: InviteRecord = {
    code,
    createdBy: "admin",
    createdAt: now.toISOString(),
    uses: 0,
  };

  if (body.label) record.label = body.label;
  if (body.maxUses !== undefined) record.maxUses = body.maxUses;
  if (body.expiresInHours) {
    const expires = new Date(now.getTime() + body.expiresInHours * 3600_000);
    record.expiresAt = expires.toISOString();
  }

  await env.AGENTS.put(`invite:${code}`, JSON.stringify(record));
  await addToIndex(env.AGENTS, "_index:invites", code);

  return Response.json(
    {
      code,
      url: `${BASE_URL}/signup?invite=${code}`,
      label: record.label,
      maxUses: record.maxUses,
      expiresAt: record.expiresAt,
    },
    { status: 201 }
  );
}

export async function handleGetInvites(
  request: Request,
  env: Env
): Promise<Response> {
  if (!(await validateAdminKey(request, env))) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const codes = await getIndex(env.AGENTS, "_index:invites", false);
  const invites: InviteRecord[] = [];

  for (const code of codes) {
    const raw = await env.AGENTS.get(`invite:${code}`);
    if (!raw) continue;
    invites.push(JSON.parse(raw));
  }

  return Response.json(invites);
}

export async function handleDeleteInvite(
  request: Request,
  env: Env,
  code: string
): Promise<Response> {
  if (!(await validateAdminKey(request, env))) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const raw = await env.AGENTS.get(`invite:${code}`);
  if (!raw) {
    return Response.json(
      { error: "Invite not found", code: "NOT_FOUND" },
      { status: 404 }
    );
  }

  await env.AGENTS.delete(`invite:${code}`);
  await removeFromIndex(env.AGENTS, "_index:invites", code);

  return Response.json({ deleted: true, code });
}
