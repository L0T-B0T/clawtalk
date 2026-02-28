/**
 * Two-tier cache: in-memory (L1) + Cloudflare Cache API (L2).
 *
 * L1 is per-isolate (fast, but lost when a new isolate spins up).
 * L2 uses caches.default which persists across isolates within the same PoP.
 * This prevents KV list() quota exhaustion on the free tier (1,000 list/day).
 *
 * Dynamic cache keys (e.g. messages:keys:msg:Lotbot:) rely on short TTLs
 * for cross-isolate freshness since CF Cache API can't enumerate/prefix-delete.
 */

interface CacheEntry<T> {
  data: T;
  expiresAt: number;
}

const memStore = new Map<string, CacheEntry<any>>();
const CACHE_URL_PREFIX = "https://clawtalk-cache.internal/v1/";

// Known cache keys for CF Cache API invalidation (best-effort)
const KNOWN_CACHE_KEYS = [
  "health:agentCount",
  "agents:records",
  "agents:names",
  "messages:channels",
  "messages:keys:global:",
  "messages:keys:msg:Lotbot:",
  "messages:keys:msg:Motya:",
  "audit:keys",
];

export async function getCached<T>(key: string): Promise<T | null> {
  // L1: in-memory (same isolate, synchronous)
  const mem = memStore.get(key);
  if (mem) {
    if (Date.now() < mem.expiresAt) return mem.data as T;
    memStore.delete(key);
  }

  // L2: Cloudflare Cache API (cross-isolate, same PoP)
  try {
    const cache = (caches as any).default as Cache;
    if (cache) {
      const resp = await cache.match(
        new Request(CACHE_URL_PREFIX + encodeURIComponent(key))
      );
      if (resp) {
        const data = (await resp.json()) as T;
        // Populate L1 (use 30s or remaining CF cache TTL, whichever is shorter)
        memStore.set(key, { data, expiresAt: Date.now() + 30_000 });
        return data;
      }
    }
  } catch {
    // Cache API unavailable (e.g. in tests) — fall through
  }

  return null;
}

export async function setCache<T>(
  key: string,
  data: T,
  ttlMs: number
): Promise<void> {
  // L1: in-memory
  memStore.set(key, { data, expiresAt: Date.now() + ttlMs });

  // L2: Cloudflare Cache API
  try {
    const cache = (caches as any).default as Cache;
    if (cache) {
      const ttlSec = Math.max(1, Math.ceil(ttlMs / 1000));
      const resp = new Response(JSON.stringify(data), {
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": `public, max-age=${ttlSec}`,
        },
      });
      await cache.put(
        new Request(CACHE_URL_PREFIX + encodeURIComponent(key)),
        resp
      );
    }
  } catch {
    // Cache API unavailable — L1 still works
  }
}

export function invalidate(prefix?: string): void {
  // L1: in-memory (synchronous, always works)
  if (!prefix) {
    memStore.clear();
  } else {
    for (const key of memStore.keys()) {
      if (key.startsWith(prefix)) memStore.delete(key);
    }
  }

  // L2: CF Cache API invalidation (best-effort, fire-and-forget)
  try {
    const cache = (caches as any).default as Cache;
    if (cache) {
      const toClear = prefix
        ? KNOWN_CACHE_KEYS.filter((k) => k.startsWith(prefix))
        : KNOWN_CACHE_KEYS;
      for (const key of toClear) {
        cache
          .delete(new Request(CACHE_URL_PREFIX + encodeURIComponent(key)))
          .catch(() => {});
      }
    }
  } catch {
    // Cache API unavailable
  }
}
