/**
 * Message threading — threadId auto-resolution
 * Consolidated from PR #26
 */
import { Env } from "../types";
import { getIndex } from "../kv-index";

export async function handleGetThread(request: Request, env: Env, threadId: string): Promise<Response> {
  // Authenticate
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return Response.json({ error: "Unauthorized", code: "UNAUTHORIZED" }, { status: 401 });
  }

  try {
    const messageIds = await getIndex(env.MESSAGES, "_index:messages");
    const threadMessages: unknown[] = [];

    // Find messages in this thread
    for (const msgId of messageIds) {
      try {
        const raw = await env.MESSAGES.get(`msg:${msgId}`);
        if (raw) {
          const msg = JSON.parse(raw);
          if (msg.threadId === threadId || msg.id === threadId || msg.replyTo === threadId) {
            threadMessages.push(msg);
          }
        }
      } catch {
        // Skip bad messages
      }
    }

    // Sort by timestamp
    threadMessages.sort((a: any, b: any) => 
      new Date(a.ts).getTime() - new Date(b.ts).getTime()
    );

    // Build thread summary
    const participants = [...new Set(threadMessages.map((m: any) => m.from))];

    return Response.json({
      threadId,
      messageCount: threadMessages.length,
      participants,
      messages: threadMessages,
      createdAt: threadMessages.length > 0 ? (threadMessages[0] as any).ts : null,
      lastMessage: threadMessages.length > 0 ? (threadMessages[threadMessages.length - 1] as any).ts : null,
    });
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : "Thread error", code: "INTERNAL_ERROR" },
      { status: 500 }
    );
  }
}

export async function handleGetThreads(request: Request, env: Env): Promise<Response> {
  // Authenticate
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return Response.json({ error: "Unauthorized", code: "UNAUTHORIZED" }, { status: 401 });
  }

  try {
    const messageIds = await getIndex(env.MESSAGES, "_index:messages");
    const threadMap = new Map<string, { count: number; participants: Set<string>; lastTs: string }>();

    // Scan last 500 messages for threads
    for (const msgId of messageIds.slice(-500)) {
      try {
        const raw = await env.MESSAGES.get(`msg:${msgId}`);
        if (raw) {
          const msg = JSON.parse(raw);
          const tid = msg.threadId || msg.replyTo;
          if (tid) {
            if (!threadMap.has(tid)) {
              threadMap.set(tid, { count: 0, participants: new Set(), lastTs: msg.ts });
            }
            const thread = threadMap.get(tid)!;
            thread.count++;
            thread.participants.add(msg.from);
            if (msg.ts > thread.lastTs) thread.lastTs = msg.ts;
          }
        }
      } catch {
        // Skip
      }
    }

    const threads = Array.from(threadMap.entries()).map(([id, t]) => ({
      threadId: id,
      messageCount: t.count,
      participants: [...t.participants],
      lastMessage: t.lastTs,
    }));

    // Sort by most recent
    threads.sort((a, b) => b.lastMessage.localeCompare(a.lastMessage));

    return Response.json({ threads, total: threads.length });
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : "Threads error", code: "INTERNAL_ERROR" },
      { status: 500 }
    );
  }
}
