import { Env, MessageEnvelope, SendMessageBody, AgentRecord } from "../types";
import { validateAgentKey, validateAdminKey, checkRateLimit } from "../auth";
import { getCached, setCache, invalidate } from "../cache";
import { getIndex, addToIndex, removeFromIndex } from "../kv-index";

/**
 * 64KB envelope limit. Note: NaCl box + base64 encoding adds ~35-40%
 * overhead, so effective plaintext limit is ~42KB when using E2E encryption.
 */
const MAX_MESSAGE_SIZE = 64 * 1024; // 64KB envelope
const DEFAULT_TTL = 2592000; // 30 days
const MAX_TTL = 7776000; // 90 days
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;

async function updateLastSeen(agentName: string, env: Env): Promise<void> {
  const raw = await env.AGENTS.get(`agent:${agentName}`);
  if (!raw) return;
  const record: AgentRecord = JSON.parse(raw);
  record.lastSeen = new Date().toISOString();
  await env.AGENTS.put(`agent:${agentName}`, JSON.stringify(record));
}

export async function handlePostMessage(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  const senderName = await validateAgentKey(request, env);
  if (!senderName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const bodyText = await request.text();
  if (bodyText.length > MAX_MESSAGE_SIZE) {
    return Response.json(
      { error: "Message exceeds 64KB limit", code: "PAYLOAD_TOO_LARGE" },
      { status: 400 }
    );
  }

  let body: SendMessageBody;
  try {
    body = JSON.parse(bodyText);
  } catch {
    return Response.json(
      { error: "Invalid JSON body", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  if (!body.to || !body.type || body.encrypted === undefined || body.payload === undefined) {
    return Response.json(
      {
        error: "Missing required fields: to, type, encrypted, payload",
        code: "BAD_REQUEST",
      },
      { status: 400 }
    );
  }

  if (!["request", "response", "notification"].includes(body.type)) {
    return Response.json(
      { error: "Invalid message type", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  if (!(await checkRateLimit(senderName, env))) {
    return Response.json(
      { error: "Rate limit exceeded (30/min)", code: "RATE_LIMITED" },
      { status: 429 }
    );
  }

  // Resolve recipients (cache agent names for broadcast)
  let recipients: string[];
  if (body.to === "broadcast") {
    let agentNames = await getCached<string[]>("agents:names");
    if (!agentNames) {
      agentNames = await getIndex(env.AGENTS, "_index:agents");
      await setCache("agents:names", agentNames, 60_000);
    }
    recipients = agentNames.filter((n) => n !== senderName);
  } else if (Array.isArray(body.to)) {
    recipients = body.to;
  } else {
    recipients = [body.to];
  }

  if (recipients.length === 0) {
    return Response.json(
      { error: "No recipients found", code: "BAD_REQUEST" },
      { status: 400 }
    );
  }

  const msgId = crypto.randomUUID();
  const ts = new Date().toISOString();
  const ttl = Math.min(body.ttl || DEFAULT_TTL, MAX_TTL);

  const baseEnvelope = {
    id: msgId,
    from: senderName,
    type: body.type,
    topic: body.topic,
    correlationId: body.correlationId,
    replyTo: body.replyTo,
    encrypted: body.encrypted,
    payload: body.payload,
    nonce: body.nonce,
    signature: body.signature,
    ts,
  };

  // Store one message per recipient
  for (let recipient of recipients) {
    // Case-insensitive recipient lookup: try exact, then scan agents
    let recipientRecord = await env.AGENTS.get(`agent:${recipient}`);
    if (!recipientRecord) {
      // Try case-insensitive match (cached agent names)
      let agentNames = await getCached<string[]>("agents:names");
      if (!agentNames) {
        agentNames = await getIndex(env.AGENTS, "_index:agents");
        await setCache("agents:names", agentNames, 60_000);
      }
      const match = agentNames.find(
        (n) => n.toLowerCase() === recipient.toLowerCase()
      );
      if (match) {
        recipient = match;
        recipientRecord = await env.AGENTS.get(`agent:${match}`);
      }
      if (!recipientRecord) continue;
    }
    // Always normalize to canonical name from agent record
    const parsed: AgentRecord = JSON.parse(recipientRecord);
    if (parsed.name && parsed.name !== recipient) {
      recipient = parsed.name;
    }

    const msgEnvelope: MessageEnvelope = { ...baseEnvelope, to: recipient };
    // Pad timestamp for sorting: use millisecond epoch for lexicographic sort
    const sortableTs = new Date(ts).getTime().toString().padStart(15, "0");
    const key = `msg:${recipient}:${sortableTs}:${msgId}`;

    await env.MESSAGES.put(key, JSON.stringify(msgEnvelope), {
      expirationTtl: ttl,
    });
    await addToIndex(env.MESSAGES, `_index:messages:${recipient}`, key);

    // Also store in global log for admin monitoring
    const globalKey = `global:${sortableTs}:${msgId}:${recipient}`;
    await env.MESSAGES.put(globalKey, JSON.stringify(msgEnvelope), {
      expirationTtl: ttl,
    });
    await addToIndex(env.MESSAGES, "_index:messages:global", globalKey);

    // Webhook delivery (fire-and-forget, no retry).
    // Messages persist in KV regardless of webhook success — agents
    // should poll as fallback if webhook delivery is unreliable.
    const recipientRaw = await env.AGENTS.get(`agent:${recipient}`);
    if (recipientRaw) {
      const recipientAgent: AgentRecord = JSON.parse(recipientRaw);
      if (recipientAgent.webhookUrl) {
        ctx.waitUntil(
          fetch(recipientAgent.webhookUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(msgEnvelope),
          }).catch(() => {}) // silently ignore webhook failures
        );
      }
    }
  }

  await updateLastSeen(senderName, env);
  invalidate("messages:");
  invalidate("agents:"); // lastSeen changed

  return Response.json({ id: msgId, ts }, { status: 201 });
}

export async function handleGetMessages(
  request: Request,
  env: Env
): Promise<Response> {
  // Support both agent key (inbox only) and admin key (global view)
  const isAdmin = await validateAdminKey(request, env);
  const agentName = isAdmin ? null : await validateAgentKey(request, env);
  if (!isAdmin && !agentName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  const url = new URL(request.url);
  const since = url.searchParams.get("since");
  const limit = Math.min(
    parseInt(url.searchParams.get("limit") || String(DEFAULT_LIMIT), 10),
    MAX_LIMIT
  );
  const topic = url.searchParams.get("topic");

  // Admin sees all messages via global log; agents see their inbox
  const indexKey = isAdmin ? "_index:messages:global" : `_index:messages:${agentName}`;
  const cacheKey = `messages:keys:${indexKey}`;
  let allKeys: { name: string }[];
  const cachedKeys = await getCached<{ name: string }[]>(cacheKey);
  if (cachedKeys) {
    allKeys = cachedKeys;
  } else {
    const keyNames = await getIndex(env.MESSAGES, indexKey);
    allKeys = keyNames.reverse().map((name) => ({ name }));
    await setCache(cacheKey, allKeys, 15_000);
  }

  const messages: MessageEnvelope[] = [];
  const sinceTime = since ? new Date(since).getTime() : 0;

  for (const key of allKeys) {
    if (messages.length >= limit) break;

    const raw = await env.MESSAGES.get(key.name);
    if (!raw) continue;

    const msg: MessageEnvelope = JSON.parse(raw);

    if (sinceTime && new Date(msg.ts).getTime() <= sinceTime) continue;
    if (topic && msg.topic !== topic) continue;

    messages.push(msg);
  }

  if (agentName) await updateLastSeen(agentName, env);

  const cursor =
    messages.length > 0 ? messages[messages.length - 1].ts : undefined;

  return Response.json({ messages, cursor });
}

export async function handleDeleteMessage(
  request: Request,
  env: Env,
  messageId: string
): Promise<Response> {
  const agentName = await validateAgentKey(request, env);
  if (!agentName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  // Find the message key belonging to this agent (from index)
  const indexKey = `_index:messages:${agentName}`;
  const keyNames = await getIndex(env.MESSAGES, indexKey);

  let found = false;
  for (const keyName of keyNames) {
    if (keyName.endsWith(`:${messageId}`)) {
      await env.MESSAGES.delete(keyName);
      await removeFromIndex(env.MESSAGES, indexKey, keyName);
      // Also remove from global index
      // Global key format: global:{ts}:{msgId}:{recipient}
      // Extract ts from msg key: msg:{agent}:{ts}:{msgId}
      const parts = keyName.split(":");
      const ts = parts[2];
      // Try to remove matching global key (best effort — may have any recipient suffix)
      const globalPrefix = `global:${ts}:${messageId}:`;
      const globalKeys = await getIndex(env.MESSAGES, "_index:messages:global");
      const globalMatch = globalKeys.find((k) => k.startsWith(globalPrefix));
      if (globalMatch) {
        await env.MESSAGES.delete(globalMatch);
        await removeFromIndex(env.MESSAGES, "_index:messages:global", globalMatch);
      }
      invalidate("messages:");
      found = true;
      break;
    }
  }

  if (!found) {
    return Response.json(
      { error: "Message not found", code: "NOT_FOUND" },
      { status: 404 }
    );
  }

  return new Response(null, { status: 204 });
}

export async function handleGetChannels(
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

  // Scan messages for unique topics/channels (cached 60s)
  let channelList = await getCached<string[]>("messages:channels");
  if (!channelList) {
    const globalKeys = await getIndex(env.MESSAGES, "_index:messages:global");
    const channels = new Set<string>();
    // Read recent messages to extract topics
    for (const keyName of globalKeys.slice(-200)) {
      const raw = await env.MESSAGES.get(keyName);
      if (!raw) continue;
      const msg: MessageEnvelope = JSON.parse(raw);
      if (msg.topic) channels.add(msg.topic);
    }
    channelList = [...channels];
    await setCache("messages:channels", channelList, 60_000);
  }

  return Response.json(channelList);
}
