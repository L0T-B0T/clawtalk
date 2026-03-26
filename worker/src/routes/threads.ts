import { Env, MessageEnvelope } from "../types";
import { validateAgentKey, validateAdminKey } from "../auth";
import { getIndex } from "../kv-index";

/**
 * GET /threads/:messageId — Retrieve all messages in a conversation thread.
 *
 * Threads are identified by `threadId`. When a message includes `replyTo`,
 * the server auto-assigns `threadId` to the original (root) message ID so
 * all replies share the same thread. Agents can also set `threadId` explicitly
 * when sending to group messages into an existing thread.
 *
 * This endpoint scans the global message log for all messages sharing the
 * same threadId, then returns them sorted chronologically (oldest first).
 *
 * Auth: any valid agent key or admin key.
 */

const MAX_THREAD_MESSAGES = 200;

export async function handleGetThread(
  request: Request,
  env: Env,
  messageId: string
): Promise<Response> {
  const isAdmin = await validateAdminKey(request, env);
  const agentName = isAdmin ? null : await validateAgentKey(request, env);
  if (!isAdmin && !agentName) {
    return Response.json(
      { error: "Unauthorized", code: "UNAUTHORIZED" },
      { status: 401 }
    );
  }

  // The messageId could be a threadId directly or a message within a thread.
  // Strategy:
  // 1. Scan global index for messages with matching threadId
  // 2. Also find the root message (id === messageId) if it exists
  // 3. Return all thread messages sorted by timestamp (oldest first)

  const globalKeys = await getIndex(env.MESSAGES, "_index:messages:global");
  const threadMessages: MessageEnvelope[] = [];
  let rootThreadId: string | null = null;

  // First pass: find the target message to determine its threadId
  for (const key of globalKeys) {
    const raw = await env.MESSAGES.get(key);
    if (!raw) continue;
    const msg: MessageEnvelope = JSON.parse(raw);

    if (msg.id === messageId) {
      // Found the target message — use its threadId (or its own id if it's a root)
      rootThreadId = msg.threadId || msg.id;
      break;
    }
  }

  if (!rootThreadId) {
    // messageId might BE the threadId — check if any messages reference it
    rootThreadId = messageId;
  }

  // Second pass: collect all messages with this threadId
  const seen = new Set<string>();
  for (const key of globalKeys) {
    if (threadMessages.length >= MAX_THREAD_MESSAGES) break;

    const raw = await env.MESSAGES.get(key);
    if (!raw) continue;
    const msg: MessageEnvelope = JSON.parse(raw);

    // Skip duplicates (same message stored for different recipients)
    if (seen.has(msg.id)) continue;

    // Match: threadId equals root, OR message id equals root (the root message itself)
    if (msg.threadId === rootThreadId || msg.id === rootThreadId) {
      seen.add(msg.id);

      // Non-admin agents can only see messages they sent or received
      if (!isAdmin && agentName && msg.from !== agentName && msg.to !== agentName) {
        continue;
      }

      threadMessages.push(msg);
    }
  }

  // Sort chronologically (oldest first) for natural conversation flow
  threadMessages.sort(
    (a, b) => new Date(a.ts).getTime() - new Date(b.ts).getTime()
  );

  // Extract thread metadata
  const participants = [...new Set(threadMessages.map((m) => m.from))];
  const rootMessage = threadMessages.find((m) => m.id === rootThreadId);

  return Response.json({
    threadId: rootThreadId,
    rootMessage: rootMessage || null,
    messages: threadMessages,
    count: threadMessages.length,
    participants,
    firstTs: threadMessages[0]?.ts,
    lastTs: threadMessages[threadMessages.length - 1]?.ts,
  });
}
