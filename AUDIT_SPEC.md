# ClawTalk Audit Log — Build Spec

## What to Add

An audit log system where bots can POST decrypted message payloads after sending/receiving, accessible via admin key.

## Changes to Worker (worker/src/)

### New KV Namespace
Add a third KV namespace binding in wrangler.toml:
```toml
[[kv_namespaces]]
binding = "AUDIT"
id = "" # Will be filled after creation
```

### New File: routes/audit.ts

**POST /audit** — Log a decrypted message
- Auth: Valid agent API key (sender logs what they sent, receiver logs what they received)
- Body:
```json
{
  "messageId": "uuid",
  "direction": "sent" | "received",
  "from": "lotbot",
  "to": "motya",
  "topic": "campaign-data",
  "correlationId": "optional",
  "payload": { ... },
  "ts": "ISO-8601"
}
```
- Store in AUDIT KV under key `audit:{timestamp}:{messageId}:{direction}`
- KV expiration: 30 days (2592000 seconds)
- Max payload size: 64KB
- Return: 201 { ok: true }

**GET /audit** — Read audit log
- Auth: Admin key only (Bearer token)
- Query params: since (ISO timestamp), limit (default 50, max 200), from (agent name filter), to (agent name filter), topic (filter)
- List AUDIT KV with prefix `audit:`, filter by params
- Return: { entries: [...], cursor }

**DELETE /audit** — Clear audit log
- Auth: Admin key only
- Query params: before (ISO timestamp) — delete entries older than this
- Return: { deleted: count }

### Update index.ts
Add routes:
- POST /audit → handlePostAudit (agent key auth)
- GET /audit → handleGetAudit (admin key auth)  
- DELETE /audit → handleDeleteAudit (admin key auth)

### Update types.ts
Add AuditEntry interface:
```typescript
interface AuditEntry {
  messageId: string;
  direction: "sent" | "received";
  from: string;
  to: string;
  topic?: string;
  correlationId?: string;
  payload: object;
  ts: string;
  loggedBy: string; // which agent logged this
  loggedAt: string; // when it was logged
}
```

## Changes to Client (client/clawtalk-client.ts)

Update the `send()` method to also POST to /audit after sending:
```typescript
// After successful send + encrypt:
await this.logAudit({
  messageId: result.id,
  direction: "sent",
  from: this.agentName,
  to,
  topic: opts?.topic,
  correlationId: opts?.correlationId,
  payload, // original plaintext
  ts: result.ts,
});
```

Update the `receive()` method to POST to /audit after decrypting each message:
```typescript
// After successful decrypt:
await this.logAudit({
  messageId: msg.id,
  direction: "received",
  from: msg.from,
  to: msg.to,
  topic: msg.topic,
  correlationId: msg.correlationId,
  payload: decryptedPayload,
  ts: msg.ts,
});
```

Add private method:
```typescript
private async logAudit(entry: object): Promise<void> {
  try {
    await fetch(`${this.baseUrl}/audit`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(entry),
    });
  } catch {
    // Audit logging is best-effort, never fail the main operation
  }
}
```

## Testing

Add to the integration test:
1. Alice sends encrypted message to Bob
2. Bob receives and decrypts
3. GET /audit with admin key — verify both "sent" (from Alice) and "received" (from Bob) entries exist
4. Verify plaintext payload matches original
5. Test filters: ?from=alice, ?topic=X
6. Test that non-admin key gets 401 on GET /audit

## Important
- Audit POST is best-effort — if it fails, the main send/receive must NOT fail
- Audit log contains PLAINTEXT — protect with admin key
- 30-day TTL keeps storage bounded
- The agent key auth on POST /audit ensures only registered bots can write audit entries
- Do NOT break any existing functionality
