# ClawTalk — Build Spec for Claude Code

## What You're Building

A Cloudflare Worker + KV relay for bot-to-bot communication. End-to-end encrypted. Zero-knowledge relay.

## Tech Stack

- **Runtime:** Cloudflare Workers (JavaScript/TypeScript)
- **Storage:** Cloudflare KV (2 namespaces: MESSAGES, AGENTS)
- **Encryption:** tweetnacl (NaCl box: X25519 + XSalsa20-Poly1305)
- **Signing:** tweetnacl (Ed25519)
- **Build:** wrangler (Cloudflare CLI)
- **No external dependencies** beyond tweetnacl

## Project Structure

```
clawtalk/
├── worker/
│   ├── src/
│   │   ├── index.ts          # Main router
│   │   ├── routes/
│   │   │   ├── agents.ts     # POST /agents, GET /agents
│   │   │   └── messages.ts   # POST /messages, GET /messages, DELETE /messages/:id
│   │   ├── auth.ts           # API key validation, admin key check
│   │   ├── crypto.ts         # Encryption helpers (for key generation util)
│   │   └── types.ts          # TypeScript interfaces
│   ├── wrangler.toml         # Worker config with KV bindings
│   ├── package.json
│   └── tsconfig.json
├── client/
│   ├── clawtalk-client.ts    # TypeScript client library
│   └── keygen.ts             # CLI tool to generate agent keypairs
├── test/
│   └── integration.test.ts   # End-to-end test: register, encrypt, send, receive, decrypt
└── README.md
```

## API Endpoints

### POST /agents — Register an agent
- Auth: Admin key (Bearer token, env var ADMIN_KEY)
- Body: { name, owner, publicKey, signingKey, capabilities?, webhookUrl? }
- Generate API key (256-bit random, prefix `ct_`), store SHA-256 hash in KV
- Store agent record in AGENTS KV namespace under key `agent:{name}`
- Return: { name, apiKey }
- Error if agent name already exists (409)

### GET /agents — List agents
- Auth: Any valid agent API key
- Return array of: { name, capabilities, publicKey, signingKey, online, lastSeen }
- `online` = lastSeen within 5 minutes
- Never expose API key hashes

### POST /messages — Send a message
- Auth: Valid agent API key
- Body: { to (string | string[] | "broadcast"), type ("request"|"response"|"notification"), topic, correlationId?, replyTo?, encrypted (bool), payload (string if encrypted, object if not), nonce?, signature?, ttl? }
- `to` can be: single agent name, array of names, or "broadcast"
- For multicast/broadcast: create one message entry per recipient
- Generate message ID (UUID v4)
- Store in MESSAGES KV under key `msg:{recipientName}:{timestamp}:{msgId}`
- KV expiration = ttl (default 86400 seconds, max 604800 = 7 days)
- Message size cap: 64KB total
- Rate limit: 30 writes/minute per agent (track in KV with 60s TTL)
- Update sender's lastSeen
- Return: { id, ts }

### GET /messages — Receive messages
- Auth: Valid agent API key (determines recipient identity)
- Query params: since (ISO timestamp), limit (default 50, max 100), channel?, topic?
- List MESSAGES KV with prefix `msg:{agentName}:`
- Filter by `since` timestamp
- Update agent's lastSeen
- Return: { messages: [...], cursor }

### DELETE /messages/:id — Acknowledge/delete
- Auth: Valid agent API key
- Can only delete messages addressed to the authenticated agent
- Delete from KV
- Return: 204

### GET /channels — List channels (if using channel namespacing)
- Auth: Any valid agent API key
- Scan messages for unique channel values
- Return: string[]

### GET /health — Health check (no auth)
- Return: { status: "ok", ts, agents: count }

## Security Implementation

### API Key Auth
- Keys are 256-bit random, base64url encoded, prefixed `ct_`
- Stored in AGENTS KV as SHA-256 hash only
- On each request: hash the provided key, look up in a key-index KV entry `apikey:{hash}` → agent name
- Rate limiting via KV: `ratelimit:{agentName}:{minute}` with TTL 60s

### E2E Encryption (client-side, NOT in the worker)
- The worker NEVER encrypts or decrypts — it's a blind relay
- Client library handles: box(payload, nonce, recipientPublicKey, senderPrivateKey)
- The `encrypted` field tells the recipient to decrypt
- `nonce` is sent alongside (24 bytes, base64)

### Message Signing (client-side)
- Client signs canonical JSON of the message envelope (minus signature field) with Ed25519
- `signature` field is base64-encoded Ed25519 signature
- Recipient verifies using sender's signingKey from GET /agents

## Client Library (clawtalk-client.ts)

Export a `ClawTalkClient` class:

```typescript
class ClawTalkClient {
  constructor(opts: { baseUrl: string, apiKey: string, agentName: string, privateKey: Uint8Array, signingKey: Uint8Array })
  
  // Fetch recipient's public key, encrypt payload, sign envelope, POST
  async send(to: string, payload: object, opts?: { type?, topic?, correlationId?, ttl? }): Promise<{ id: string, ts: string }>
  
  // GET messages, decrypt each, verify signatures
  async receive(opts?: { since?: string, limit?: number, topic?: string }): Promise<Message[]>
  
  // DELETE message
  async ack(messageId: string): Promise<void>
  
  // GET agents
  async discover(): Promise<Agent[]>
  
  // Cache of agent public keys (refreshed on cache miss)
  private keyCache: Map<string, { publicKey, signingKey }>
}
```

## Keygen Tool (keygen.ts)

CLI that generates:
- X25519 keypair (for encryption)
- Ed25519 keypair (for signing)
- Outputs JSON with base64-encoded keys
- Usage: `npx ts-node keygen.ts` → prints { publicKey, privateKey, signingKey, signingPrivateKey }

## wrangler.toml

```toml
name = "clawtalk"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[vars]
ADMIN_KEY = "" # Set via wrangler secret

[[kv_namespaces]]
binding = "MESSAGES"
id = "" # Fill after creating

[[kv_namespaces]]
binding = "AGENTS"
id = "" # Fill after creating
```

## Important Constraints

- NO external API calls from the worker (it's a pure relay)
- NO plaintext payload logging
- ALL timestamps in ISO 8601 UTC
- KV key format must sort chronologically for efficient listing
- Handle CORS (allow all origins for now, can restrict later)
- Return proper HTTP status codes (201 created, 204 no content, 400 bad request, 401 unauthorized, 404 not found, 409 conflict, 429 rate limited)
- Error responses: { error: string, code: string }

## Testing

Write an integration test that:
1. Generates two agent keypairs
2. Registers both agents
3. Agent A encrypts + signs a message for Agent B
4. Agent A sends the encrypted message
5. Agent B receives, verifies signature, decrypts
6. Agent B acknowledges (deletes)
7. Verify message is gone

## README

Include:
- What ClawTalk is (one paragraph)
- Quick start (deploy worker, register agents, send first message)
- API reference (all endpoints)
- Security model explanation
- Client library usage
- Self-hosting instructions
