import nacl from "tweetnacl";
import { encodeBase64, decodeBase64 } from "tweetnacl-util";

export interface Agent {
  name: string;
  capabilities?: string[];
  publicKey: string;
  signingKey: string;
  online: boolean;
  lastSeen: string;
}

export interface Message {
  id: string;
  from: string;
  to: string;
  type: "request" | "response" | "notification";
  topic?: string;
  correlationId?: string;
  replyTo?: string;
  encrypted: boolean;
  payload: object;
  nonce?: string;
  signature?: string;
  ts: string;
  verified?: boolean;
}

export interface ClawTalkClientOpts {
  baseUrl: string;
  apiKey: string;
  agentName: string;
  privateKey: Uint8Array;
  signingKey: Uint8Array;
}

export interface SendOpts {
  type?: "request" | "response" | "notification";
  topic?: string;
  correlationId?: string;
  ttl?: number;
}

export interface ReceiveOpts {
  since?: string;
  limit?: number;
  topic?: string;
}

export class ClawTalkClient {
  private baseUrl: string;
  private apiKey: string;
  private agentName: string;
  private privateKey: Uint8Array;
  private signingKeyPrivate: Uint8Array;
  private keyCache: Map<string, { publicKey: Uint8Array; signingKey: Uint8Array }> =
    new Map();

  constructor(opts: ClawTalkClientOpts) {
    this.baseUrl = opts.baseUrl.replace(/\/$/, "");
    this.apiKey = opts.apiKey;
    this.agentName = opts.agentName;
    this.privateKey = opts.privateKey;
    this.signingKeyPrivate = opts.signingKey;
  }

  private headers(): Record<string, string> {
    return {
      Authorization: `Bearer ${this.apiKey}`,
      "Content-Type": "application/json",
    };
  }

  async discover(): Promise<Agent[]> {
    const res = await fetch(`${this.baseUrl}/agents`, {
      headers: this.headers(),
    });
    if (!res.ok) {
      throw new Error(`Failed to discover agents: ${res.status}`);
    }
    const agents = (await res.json()) as Agent[];

    // Update key cache
    for (const agent of agents) {
      this.keyCache.set(agent.name, {
        publicKey: decodeBase64(agent.publicKey),
        signingKey: decodeBase64(agent.signingKey),
      });
    }

    return agents;
  }

  private async getRecipientKeys(
    name: string
  ): Promise<{ publicKey: Uint8Array; signingKey: Uint8Array }> {
    const cached = this.keyCache.get(name);
    if (cached) return cached;

    // Refresh cache
    await this.discover();
    const keys = this.keyCache.get(name);
    if (!keys) throw new Error(`Agent "${name}" not found`);
    return keys;
  }

  async send(
    to: string,
    payload: object,
    opts?: SendOpts
  ): Promise<{ id: string; ts: string }> {
    const recipientKeys = await this.getRecipientKeys(to);

    // Encrypt payload
    const nonce = nacl.randomBytes(nacl.box.nonceLength);
    const messageBytes = new TextEncoder().encode(JSON.stringify(payload));
    const encrypted = nacl.box(
      messageBytes,
      nonce,
      recipientKeys.publicKey,
      this.privateKey
    );

    // Build envelope (without signature for signing)
    const envelope: Record<string, unknown> = {
      to,
      type: opts?.type || "request",
      topic: opts?.topic,
      correlationId: opts?.correlationId,
      ttl: opts?.ttl,
      encrypted: true,
      payload: encodeBase64(encrypted),
      nonce: encodeBase64(nonce),
    };

    // Sign the canonical envelope
    const canonical = JSON.stringify(envelope);
    const signatureBytes = nacl.sign.detached(
      new TextEncoder().encode(canonical),
      this.signingKeyPrivate
    );
    envelope.signature = encodeBase64(signatureBytes);

    const res = await fetch(`${this.baseUrl}/messages`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(envelope),
    });

    if (!res.ok) {
      const err = await res.json();
      throw new Error(`Failed to send message: ${(err as { error: string }).error}`);
    }

    const result = await (res.json() as Promise<{ id: string; ts: string }>);

    // Audit log the sent message (best-effort)
    await this.logAudit({
      messageId: result.id,
      direction: "sent",
      from: this.agentName,
      to,
      topic: opts?.topic,
      correlationId: opts?.correlationId,
      payload,
      ts: result.ts,
    });

    return result;
  }

  async receive(opts?: ReceiveOpts): Promise<Message[]> {
    const params = new URLSearchParams();
    if (opts?.since) params.set("since", opts.since);
    if (opts?.limit) params.set("limit", String(opts.limit));
    if (opts?.topic) params.set("topic", opts.topic);

    const qs = params.toString();
    const url = `${this.baseUrl}/messages${qs ? `?${qs}` : ""}`;

    const res = await fetch(url, { headers: this.headers() });
    if (!res.ok) {
      throw new Error(`Failed to receive messages: ${res.status}`);
    }

    const { messages } = (await res.json()) as {
      messages: Array<{
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
      }>;
    };
    const result: Message[] = [];

    for (const msg of messages) {
      let decryptedPayload: object;
      let verified: boolean | undefined;

      if (msg.encrypted && typeof msg.payload === "string" && msg.nonce) {
        // Get sender's keys for decryption and verification
        const senderKeys = await this.getRecipientKeys(msg.from);

        // Verify signature if present
        if (msg.signature) {
          const envelopeForVerify: Record<string, unknown> = {
            to: msg.to,
            type: msg.type,
            topic: msg.topic,
            correlationId: msg.correlationId,
            ttl: undefined,
            encrypted: msg.encrypted,
            payload: msg.payload,
            nonce: msg.nonce,
          };
          const canonical = JSON.stringify(envelopeForVerify);
          verified = nacl.sign.detached.verify(
            new TextEncoder().encode(canonical),
            decodeBase64(msg.signature),
            senderKeys.signingKey
          );
        }

        // Decrypt
        const decrypted = nacl.box.open(
          decodeBase64(msg.payload),
          decodeBase64(msg.nonce),
          senderKeys.publicKey,
          this.privateKey
        );

        if (!decrypted) {
          throw new Error(`Failed to decrypt message ${msg.id} from ${msg.from}`);
        }

        decryptedPayload = JSON.parse(new TextDecoder().decode(decrypted));
      } else {
        decryptedPayload = msg.payload as object;
      }

      // Audit log the received message (best-effort)
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

      result.push({
        id: msg.id,
        from: msg.from,
        to: msg.to,
        type: msg.type,
        topic: msg.topic,
        correlationId: msg.correlationId,
        replyTo: msg.replyTo,
        encrypted: msg.encrypted,
        payload: decryptedPayload,
        nonce: msg.nonce,
        signature: msg.signature,
        ts: msg.ts,
        verified,
      });
    }

    return result;
  }

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

  async ack(messageId: string): Promise<void> {
    const res = await fetch(`${this.baseUrl}/messages/${messageId}`, {
      method: "DELETE",
      headers: this.headers(),
    });

    if (!res.ok && res.status !== 204) {
      throw new Error(`Failed to ack message: ${res.status}`);
    }
  }
}
