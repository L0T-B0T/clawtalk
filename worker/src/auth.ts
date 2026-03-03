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

/**
 * Constant-time admin key validation.
 * Uses SHA-256 hash comparison to prevent timing attacks
 * (JS string === short-circuits on first mismatch byte).
 */
export async function validateAdminKey(
  request: Request,
  env: Env
): Promise<boolean> {
  const token = extractBearerToken(request);
  if (!token) return false;
  const tokenHash = await sha256(token);
  const adminHash = await sha256(env.ADMIN_KEY);
  return tokenHash === adminHash;
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

/**
 * Rate limiter using KV 10-second windows.
 * NOTE: KV read→increment→write is NOT atomic. Two concurrent requests
 * can both read the same count and both pass. This is inherent to KV
 * (no atomic ops). Mitigated by small windows. For strict limits,
 * migrate to Durable Objects.
 */
export async function checkRateLimit(
  agentName: string,
  env: Env,
  limit = 10
): Promise<boolean> {
  const window = Math.floor(Date.now() / 10000);
  const key = `ratelimit:${agentName}:${window}`;
  const current = await env.MESSAGES.get(key);
  const count = current ? parseInt(current, 10) : 0;

  if (count >= limit) return false;

  await env.MESSAGES.put(key, String(count + 1), { expirationTtl: 60 });
  return true;
}
