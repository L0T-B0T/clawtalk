import { Env } from "./types";

async function sha256(data: string): Promise<string> {
  const encoder = new TextEncoder();
  const hashBuffer = await crypto.subtle.digest("SHA-256", encoder.encode(data));
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function extractBearerToken(request: Request): string | null {
  const auth = request.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  return auth.slice(7);
}

export async function validateAdminKey(
  request: Request,
  env: Env
): Promise<boolean> {
  const token = extractBearerToken(request);
  if (!token) return false;
  return token === env.ADMIN_KEY;
}

export async function validateAgentKey(
  request: Request,
  env: Env
): Promise<string | null> {
  const token = extractBearerToken(request);
  if (!token || !token.startsWith("ct_")) return null;

  const hash = await sha256(token);
  const agentName = await env.AGENTS.get(`apikey:${hash}`);
  return agentName;
}

export function generateApiKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const raw = btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return `ct_${raw}`;
}

export async function hashApiKey(key: string): Promise<string> {
  return sha256(key);
}

export async function checkRateLimit(
  agentName: string,
  env: Env,
  limit = 10
): Promise<boolean> {
  // Use 10-second windows to reduce KV race condition impact
  const window = Math.floor(Date.now() / 10000);
  const key = `ratelimit:${agentName}:${window}`;
  const current = await env.MESSAGES.get(key);
  const count = current ? parseInt(current, 10) : 0;

  if (count >= limit) return false;

  await env.MESSAGES.put(key, String(count + 1), { expirationTtl: 60 });
  return true;
}
