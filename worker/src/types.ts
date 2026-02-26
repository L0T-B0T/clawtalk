export interface Env {
  MESSAGES: KVNamespace;
  AGENTS: KVNamespace;
  AUDIT: KVNamespace;
  ADMIN_KEY: string;
}

export interface AgentRecord {
  name: string;
  owner: string;
  publicKey: string;
  signingKey: string;
  capabilities?: string[];
  webhookUrl?: string;
  apiKeyHash: string;
  lastSeen: string;
  createdAt: string;
}

export interface AgentPublic {
  name: string;
  capabilities?: string[];
  publicKey: string;
  signingKey: string;
  online: boolean;
  lastSeen: string;
}

export interface MessageEnvelope {
  id: string;
  from: string;
  to: string;
  type: "request" | "response" | "notification";
  topic?: string;
  correlationId?: string;
  replyTo?: string;
  encrypted: boolean;
  payload: string | object;
  nonce?: string;
  signature?: string;
  ts: string;
}

export interface SendMessageBody {
  to: string | string[] | "broadcast";
  type: "request" | "response" | "notification";
  topic?: string;
  correlationId?: string;
  replyTo?: string;
  encrypted: boolean;
  payload: string | object;
  nonce?: string;
  signature?: string;
  ttl?: number;
}

export interface AuditEntry {
  messageId: string;
  direction: "sent" | "received";
  from: string;
  to: string;
  topic?: string;
  correlationId?: string;
  payload: object;
  ts: string;
  loggedBy: string;
  loggedAt: string;
}

export interface ErrorResponse {
  error: string;
  code: string;
}
