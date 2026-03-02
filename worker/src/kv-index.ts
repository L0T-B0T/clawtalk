import { getCached, setCache } from "./cache";

const MAX_INDEX_SIZE = 1000;

/**
 * Read an index key, returns string[]. Falls back to [] if not found.
 * Uses cache by default; pass useCache=false for fresh reads.
 */
export async function getIndex(
  ns: KVNamespace,
  indexKey: string,
  useCache = true
): Promise<string[]> {
  const cacheKey = `idx:${indexKey}`;
  if (useCache) {
    const cached = await getCached<string[]>(cacheKey);
    if (cached !== null) return cached;
  }

  const raw = await ns.get(indexKey);
  if (!raw) return [];

  try {
    const arr = JSON.parse(raw) as string[];
    if (useCache) await setCache(cacheKey, arr, 30_000);
    return arr;
  } catch {
    return [];
  }
}

/**
 * Add a value to an index. Caps at MAX_INDEX_SIZE (trims oldest).
 */
export async function addToIndex(
  ns: KVNamespace,
  indexKey: string,
  value: string
): Promise<void> {
  const arr = await getIndex(ns, indexKey, false);
  if (!arr.includes(value)) {
    arr.push(value);
    // Trim oldest if over cap
    while (arr.length > MAX_INDEX_SIZE) arr.shift();
  }
  await ns.put(indexKey, JSON.stringify(arr));
  // Update cache
  await setCache(`idx:${indexKey}`, arr, 30_000);
}

/**
 * Remove a value from an index.
 */
export async function removeFromIndex(
  ns: KVNamespace,
  indexKey: string,
  value: string
): Promise<void> {
  const arr = await getIndex(ns, indexKey, false);
  const filtered = arr.filter((v) => v !== value);
  await ns.put(indexKey, JSON.stringify(filtered));
  await setCache(`idx:${indexKey}`, filtered, 30_000);
}
