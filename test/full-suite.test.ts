/**
 * ClawTalk Full Test Suite
 * 
 * Comprehensive tests covering core functionality, security, edge cases, crypto, and stress.
 * Run: CLAWTALK_URL=http://localhost:8787 ADMIN_KEY=test-admin-key npx ts-node test/full-suite.test.ts
 */

import nacl from "tweetnacl";
import { encodeBase64, decodeBase64 } from "tweetnacl-util";
import { ClawTalkClient } from "../client/clawtalk-client";

const BASE_URL = process.env.CLAWTALK_URL || "http://localhost:8787";
const ADMIN_KEY = process.env.ADMIN_KEY || "test-admin-key";

let passed = 0;
let failed = 0;
let skipped = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    console.log(`  ✓ ${message}`);
    passed++;
  } else {
    console.error(`  ✗ ${message}`);
    failed++;
  }
}

function skip(message: string): void {
  console.log(`  ⊘ ${message} (skipped)`);
  skipped++;
}

function section(name: string): void {
  console.log(`\n━━━ ${name} ━━━`);
}

// KV is eventually consistent in production — retry reads until data appears
const IS_PROD = !BASE_URL.includes("localhost");
const KV_DELAY = IS_PROD ? 500 : 0;
const RETRY_DELAY = IS_PROD ? 3000 : 0;
const KV_RETRIES = IS_PROD ? 8 : 1;

async function kvWait(): Promise<void> {
  if (KV_DELAY > 0) await new Promise(r => setTimeout(r, KV_DELAY));
}

// Retry wrapper for eventual consistency — keeps trying until predicate passes
async function retry<T>(
  fn: () => Promise<T>,
  check: (result: T) => boolean,
): Promise<T> {
  for (let i = 0; i < KV_RETRIES; i++) {
    const result = await fn();
    if (check(result)) return result;
    if (i < KV_RETRIES - 1 && RETRY_DELAY > 0) {
      await new Promise(r => setTimeout(r, RETRY_DELAY));
    }
  }
  return fn(); // final attempt
}

// Helper: register agent with generated keys
async function createAgent(name: string): Promise<{
  name: string;
  apiKey: string;
  encryptKeys: nacl.BoxKeyPair;
  signKeys: nacl.SignKeyPair;
}> {
  const encryptKeys = nacl.box.keyPair();
  const signKeys = nacl.sign.keyPair();

  const res = await fetch(`${BASE_URL}/agents`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${ADMIN_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name,
      owner: "test",
      publicKey: encodeBase64(encryptKeys.publicKey),
      signingKey: encodeBase64(signKeys.publicKey),
    }),
  });

  if (!res.ok) {
    const err = await res.json();
    throw new Error(`Registration failed for ${name}: ${JSON.stringify(err)}`);
  }

  const data = (await res.json()) as { name: string; apiKey: string };
  return { ...data, encryptKeys, signKeys };
}

function makeClient(agent: { name: string; apiKey: string; encryptKeys: nacl.BoxKeyPair; signKeys: nacl.SignKeyPair }): ClawTalkClient {
  return new ClawTalkClient({
    baseUrl: BASE_URL,
    apiKey: agent.apiKey,
    agentName: agent.name,
    privateKey: agent.encryptKeys.secretKey,
    signingKey: agent.signKeys.secretKey,
  });
}

// Raw fetch helpers for low-level tests
async function rawSend(apiKey: string, body: object): Promise<Response> {
  const res = await fetch(`${BASE_URL}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  await kvWait();
  return res;
}

async function rawGet(apiKey: string, params = ""): Promise<Response> {
  return fetch(`${BASE_URL}/messages${params ? `?${params}` : ""}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
}

async function rawDelete(apiKey: string, msgId: string): Promise<Response> {
  return fetch(`${BASE_URL}/messages/${msgId}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${apiKey}` },
  });
}

async function main() {
  console.log(`\n🔬 ClawTalk Full Test Suite`);
  console.log(`Target: ${BASE_URL}\n`);

  // Setup: create test agents
  const ts = Date.now();
  const alice = await createAgent(`alice-${ts}`);
  const bob = await createAgent(`bob-${ts}`);
  const charlie = await createAgent(`charlie-${ts}`);
  await kvWait(); // let agent registrations propagate

  const aliceClient = makeClient(alice);
  const bobClient = makeClient(bob);
  const charlieClient = makeClient(charlie);

  // Populate key caches
  await aliceClient.discover();
  await bobClient.discover();
  await charlieClient.discover();

  // ═══════════════════════════════════════════════════════
  // CORE FUNCTIONALITY
  // ═══════════════════════════════════════════════════════

  section("Core: Multicast");
  {
    const res = await rawSend(alice.apiKey, {
      to: [bob.name, charlie.name],
      type: "notification",
      topic: "multicast-test",
      encrypted: false,
      payload: { text: "Hello both of you!" },
    });
    const data = (await res.json()) as { id: string };
    assert(res.status === 201, "Multicast send returns 201");

    const bobMsgs = await retry(() => bobClient.receive({ topic: "multicast-test" }), m => m.length >= 1);
    const charlieMsgs = await retry(() => charlieClient.receive({ topic: "multicast-test" }), m => m.length >= 1);
    assert(bobMsgs.some(m => m.id === data.id), "Bob received multicast message");
    assert(charlieMsgs.some(m => m.id === data.id), "Charlie received multicast message");

    // Cleanup
    for (const m of bobMsgs) await bobClient.ack(m.id);
    for (const m of charlieMsgs) await charlieClient.ack(m.id);
  }

  section("Core: Broadcast");
  {
    const res = await rawSend(alice.apiKey, {
      to: "broadcast",
      type: "notification",
      topic: "broadcast-test",
      encrypted: false,
      payload: { text: "Attention everyone!" },
    });
    const data = (await res.json()) as { id: string };
    assert(res.status === 201, "Broadcast send returns 201");

    const bobMsgs = await retry(
      () => bobClient.receive({ topic: "broadcast-test" }),
      msgs => msgs.some(m => m.id === data.id),
    );
    const charlieMsgs = await retry(
      () => charlieClient.receive({ topic: "broadcast-test" }),
      msgs => msgs.some(m => m.id === data.id),
    );
    const aliceMsgs = await aliceClient.receive({ topic: "broadcast-test" });

    assert(bobMsgs.some(m => m.id === data.id), "Bob received broadcast");
    assert(charlieMsgs.some(m => m.id === data.id), "Charlie received broadcast");
    assert(!aliceMsgs.some(m => m.id === data.id), "Sender (Alice) did NOT receive own broadcast");

    for (const m of bobMsgs) await bobClient.ack(m.id);
    for (const m of charlieMsgs) await charlieClient.ack(m.id);
  }

  section("Core: Unencrypted messages");
  {
    const res = await rawSend(alice.apiKey, {
      to: bob.name,
      type: "notification",
      topic: "plain-test",
      encrypted: false,
      payload: { hello: "world", number: 123 },
    });
    assert(res.status === 201, "Unencrypted message accepted");

    const msgs = await retry(
      () => bobClient.receive({ topic: "plain-test" }),
      m => m.length >= 1,
    );
    assert(msgs.length >= 1, "Bob received unencrypted message");
    const msg = msgs.find(m => (m.payload as any)?.hello === "world");
    assert(!!msg, "Payload preserved as plain object");
    assert((msg?.payload as any)?.number === 123, "Numeric value preserved");

    for (const m of msgs) await bobClient.ack(m.id);
  }

  section("Core: Topic filtering");
  {
    await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "topicA", encrypted: false, payload: { t: "A" },
    });
    await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "topicB", encrypted: false, payload: { t: "B" },
    });
    await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "topicA", encrypted: false, payload: { t: "A2" },
    });

    const topicA = await retry(() => bobClient.receive({ topic: "topicA" }), m => m.length === 2);
    const topicB = await retry(() => bobClient.receive({ topic: "topicB" }), m => m.length === 1);
    assert(topicA.length === 2, `Topic A returned 2 messages (got ${topicA.length})`);
    assert(topicB.length === 1, `Topic B returned 1 message (got ${topicB.length})`);
    assert(topicA.every(m => m.topic === "topicA"), "All topic A messages have correct topic");

    // Cleanup
    const all = await bobClient.receive();
    for (const m of all) await bobClient.ack(m.id);
  }

  section("Core: Since filtering");
  {
    const send1 = await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "since-test", encrypted: false, payload: { seq: 1 },
    });
    const data1 = (await send1.json()) as { id: string; ts: string };

    // Small delay to ensure different timestamps
    await new Promise(r => setTimeout(r, 50));

    await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "since-test", encrypted: false, payload: { seq: 2 },
    });

    const afterFirst = await retry(() => bobClient.receive({ since: data1.ts, topic: "since-test" }), m => m.length >= 1);
    assert(afterFirst.length === 1, `Since filter returned 1 message (got ${afterFirst.length})`);
    assert((afterFirst[0]?.payload as any).seq === 2, "Since filter returned only the newer message");

    const all = await bobClient.receive();
    for (const m of all) await bobClient.ack(m.id);
  }

  section("Core: Pagination (limit)");
  {
    for (let i = 0; i < 5; i++) {
      await rawSend(alice.apiKey, {
        to: bob.name, type: "notification", topic: "page-test", encrypted: false, payload: { seq: i },
      });
    }

    // Wait for all 5 messages to propagate before paginating
    await retry(() => bobClient.receive({ topic: "page-test" }), m => m.length === 5);
    const page1Res = await rawGet(bob.apiKey, "topic=page-test&limit=2");
    const page1 = (await page1Res.json()) as { messages: any[]; cursor: string };
    assert(page1.messages.length === 2, `Limit=2 returned 2 messages (got ${page1.messages.length})`);
    assert(!!page1.cursor, "Cursor returned for pagination");

    const page2Res = await rawGet(bob.apiKey, `topic=page-test&limit=2&since=${page1.cursor}`);
    const page2 = (await page2Res.json()) as { messages: any[] };
    assert(page2.messages.length === 2, `Page 2 returned 2 messages (got ${page2.messages.length})`);

    const page3Res = await rawGet(bob.apiKey, `topic=page-test&limit=2&since=${(page2 as any).cursor}`);
    const page3 = (await page3Res.json()) as { messages: any[] };
    assert(page3.messages.length === 1, `Page 3 returned 1 remaining message (got ${page3.messages.length})`);

    const all = await bobClient.receive();
    for (const m of all) await bobClient.ack(m.id);
  }

  section("Core: Channels endpoint");
  {
    await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "channel-alpha", encrypted: false, payload: {},
    });
    await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", topic: "channel-beta", encrypted: false, payload: {},
    });

    const channelRes = await fetch(`${BASE_URL}/channels`, {
      headers: { Authorization: `Bearer ${bob.apiKey}` },
    });
    const channels = (await channelRes.json()) as string[];
    assert(channels.includes("channel-alpha"), "Channels includes alpha");
    assert(channels.includes("channel-beta"), "Channels includes beta");

    const all = await bobClient.receive();
    for (const m of all) await bobClient.ack(m.id);
  }

  section("Core: Request-Response pattern (correlationId)");
  {
    const corrId = `corr-${Date.now()}`;
    // Alice sends request
    const reqResult = await aliceClient.send(bob.name, { question: "What's 2+2?" }, {
      type: "request", topic: "math", correlationId: corrId,
    });
    await kvWait();
    assert(!!reqResult.id, "Request sent with correlationId");

    // Bob receives and responds
    const incoming = await retry(() => bobClient.receive({ topic: "math" }), m => m.length >= 1);
    const request = incoming.find(m => m.correlationId === corrId);
    assert(!!request, "Bob found message by correlationId");

    await bobClient.send(alice.name, { answer: 4 }, {
      type: "response", topic: "math", correlationId: corrId,
    });
    await kvWait();

    // Alice receives response
    const responses = await retry(() => aliceClient.receive({ topic: "math" }), m => m.length >= 1);
    const response = responses.find(m => m.correlationId === corrId);
    assert(!!response, "Alice received response with matching correlationId");
    assert((response?.payload as any).answer === 4, "Response payload correct");
    assert(response?.type === "response", "Message type is response");

    // Cleanup
    for (const m of incoming) await bobClient.ack(m.id);
    for (const m of responses) await aliceClient.ack(m.id);
  }

  // ═══════════════════════════════════════════════════════
  // SECURITY & EDGE CASES
  // ═══════════════════════════════════════════════════════

  section("Security: Invalid API key");
  {
    const res = await fetch(`${BASE_URL}/messages`, {
      headers: { Authorization: "Bearer ct_bogus_key_that_doesnt_exist" },
    });
    assert(res.status === 401, `Invalid API key returns 401 (got ${res.status})`);
  }

  section("Security: Missing auth header");
  {
    const res = await fetch(`${BASE_URL}/messages`);
    assert(res.status === 401, `No auth header returns 401 (got ${res.status})`);
  }

  section("Security: Bad admin key for registration");
  {
    const res = await fetch(`${BASE_URL}/agents`, {
      method: "POST",
      headers: { Authorization: "Bearer wrong-admin-key", "Content-Type": "application/json" },
      body: JSON.stringify({ name: "hacker", owner: "evil", publicKey: "x", signingKey: "x" }),
    });
    assert(res.status === 401, `Wrong admin key returns 401 (got ${res.status})`);
  }

  section("Security: Message isolation (Alice can't read Bob's messages)");
  {
    await rawSend(charlie.apiKey, {
      to: bob.name, type: "notification", topic: "secret", encrypted: false, payload: { secret: "for bob only" },
    });

    const aliceMsgs = await aliceClient.receive({ topic: "secret" });
    const bobMsgs = await retry(() => bobClient.receive({ topic: "secret" }), m => m.length >= 1);
    assert(aliceMsgs.length === 0, "Alice sees 0 of Bob's messages");
    assert(bobMsgs.length >= 1, "Bob sees his own messages");

    for (const m of bobMsgs) await bobClient.ack(m.id);
  }

  section("Security: Alice can't delete Bob's messages");
  {
    const sendRes = await rawSend(charlie.apiKey, {
      to: bob.name, type: "notification", topic: "nodelete", encrypted: false, payload: { data: "protected" },
    });
    const { id } = (await sendRes.json()) as { id: string };

    const deleteRes = await rawDelete(alice.apiKey, id);
    assert(deleteRes.status === 404, `Alice deleting Bob's message returns 404 (got ${deleteRes.status})`);

    // Verify message still exists for Bob
    const bobMsgs = await retry(() => bobClient.receive({ topic: "nodelete" }), m => m.length >= 1);
    assert(bobMsgs.some(m => m.id === id), "Message still exists for Bob after Alice's delete attempt");

    for (const m of bobMsgs) await bobClient.ack(m.id);
  }

  section("Security: Message size cap (>64KB rejected)");
  {
    const bigPayload = "x".repeat(70000);
    const res = await rawSend(alice.apiKey, {
      to: bob.name, type: "notification", encrypted: false, payload: bigPayload,
    });
    assert(res.status === 400, `Oversized message returns 400 (got ${res.status})`);
    if (res.status === 400) {
      const err = (await res.json()) as { code: string };
      assert(err.code === "PAYLOAD_TOO_LARGE", "Error code is PAYLOAD_TOO_LARGE");
    }
  }

  section("Security: Bad JSON body");
  {
    const res = await fetch(`${BASE_URL}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${alice.apiKey}`, "Content-Type": "application/json" },
      body: "this is not json {{{",
    });
    assert(res.status === 400, `Malformed JSON returns 400 (got ${res.status})`);
  }

  section("Security: Missing required fields");
  {
    const res = await rawSend(alice.apiKey, {
      to: bob.name,
      // missing: type, encrypted, payload
    } as any);
    assert(res.status === 400, `Missing fields returns 400 (got ${res.status})`);
  }

  section("Security: Invalid message type");
  {
    const res = await rawSend(alice.apiKey, {
      to: bob.name, type: "banana", encrypted: false, payload: {},
    });
    assert(res.status === 400, `Invalid type returns 400 (got ${res.status})`);
  }

  section("Security: Rate limiting");
  {
    // Create fresh agents for rate limit test (clean counters, isolated from other tests)
    const rlSender = await createAgent(`rl-sender-${ts}`);
    const rlReceiver = await createAgent(`rl-receiver-${ts}`);

    let hitLimit = false;
    let sentCount = 0;
    for (let i = 0; i < 35; i++) {
      const res = await rawSend(rlSender.apiKey, {
        to: rlReceiver.name, type: "notification", encrypted: false, payload: { i },
      });
      if (res.status === 429) {
        hitLimit = true;
        sentCount = i;
        break;
      }
    }
    assert(hitLimit, `Rate limit hit after ${sentCount} messages (limit: 30/min)`);
  }

  // ═══════════════════════════════════════════════════════
  // CRYPTO EDGE CASES
  // ═══════════════════════════════════════════════════════

  section("Crypto: Wrong key decryption fails gracefully");
  {
    // Alice sends encrypted to Bob
    const sendResult = await aliceClient.send(bob.name, { secret: "for bob" }, { topic: "crypto-test" });
    await kvWait();

    // Charlie tries to read Bob's raw message (he can't via API, but let's verify the crypto)
    // Actually, Charlie can't even GET Bob's messages due to isolation.
    // Instead: verify that if we manually try to decrypt with wrong key, it fails
    const bobMsgs = await retry(() => bobClient.receive({ topic: "crypto-test" }), m => m.length >= 1);
    assert(bobMsgs.length >= 1, "Bob received encrypted message");
    assert(bobMsgs[0].verified === true, "Signature verified with correct keys");

    // For the actual wrong-key test, we need raw message data
    // We'll test via raw API + manual crypto
    const rawRes = await rawGet(bob.apiKey, "topic=crypto-test");
    const rawData = (await rawRes.json()) as { messages: any[] };
    const rawMsg = rawData.messages.find((m: any) => m.id === sendResult.id);

    if (rawMsg && rawMsg.encrypted && rawMsg.nonce) {
      const wrongKey = nacl.box.keyPair(); // random wrong key
      const decrypted = nacl.box.open(
        decodeBase64(rawMsg.payload),
        decodeBase64(rawMsg.nonce),
        alice.encryptKeys.publicKey, // sender's public key
        wrongKey.secretKey, // WRONG private key
      );
      assert(decrypted === null, "Decryption with wrong private key returns null");
    } else {
      skip("Could not get raw encrypted message for wrong-key test");
    }

    for (const m of bobMsgs) await bobClient.ack(m.id);
  }

  section("Crypto: Tampered signature detection");
  {
    // Build a message manually with a tampered signature
    const recipientKeys = {
      publicKey: bob.encryptKeys.publicKey,
    };
    const nonce = nacl.randomBytes(nacl.box.nonceLength);
    const payload = JSON.stringify({ tampered: true });
    const encrypted = nacl.box(
      new TextEncoder().encode(payload),
      nonce,
      recipientKeys.publicKey,
      alice.encryptKeys.secretKey,
    );

    const envelope: Record<string, unknown> = {
      to: bob.name,
      type: "request" as const,
      topic: "tamper-test",
      correlationId: undefined,
      ttl: undefined,
      encrypted: true,
      payload: encodeBase64(encrypted),
      nonce: encodeBase64(nonce),
    };

    // Sign it correctly first
    const canonical = JSON.stringify(envelope);
    const realSig = nacl.sign.detached(
      new TextEncoder().encode(canonical),
      alice.signKeys.secretKey,
    );

    // Now tamper: flip a byte in the signature
    const tamperedSig = new Uint8Array(realSig);
    tamperedSig[0] = tamperedSig[0] ^ 0xFF;

    const res = await rawSend(alice.apiKey, {
      ...envelope,
      signature: encodeBase64(tamperedSig),
    });
    assert(res.status === 201, "Tampered message still accepted by relay (relay is blind)");

    // Bob receives it — signature verification should fail
    await retry(
      async () => { const r = await rawGet(bob.apiKey, "topic=tamper-test"); return (await r.clone().json() as any).messages; },
      m => m.length >= 1,
    );
    const rawRes = await rawGet(bob.apiKey, "topic=tamper-test");
    const rawData = (await rawRes.json()) as { messages: any[] };
    const rawMsg = rawData.messages[0];

    if (rawMsg && rawMsg.signature) {
      const senderSignKey = decodeBase64(
        ((await (await fetch(`${BASE_URL}/agents`, {
          headers: { Authorization: `Bearer ${bob.apiKey}` },
        })).json()) as any[]).find((a: any) => a.name === alice.name)?.signingKey
      );

      const verifyEnvelope: Record<string, unknown> = {
        to: rawMsg.to,
        type: rawMsg.type,
        topic: rawMsg.topic,
        correlationId: rawMsg.correlationId,
        ttl: undefined,
        encrypted: rawMsg.encrypted,
        payload: rawMsg.payload,
        nonce: rawMsg.nonce,
      };
      const verifyCanonical = JSON.stringify(verifyEnvelope);
      const verified = nacl.sign.detached.verify(
        new TextEncoder().encode(verifyCanonical),
        decodeBase64(rawMsg.signature),
        senderSignKey,
      );
      assert(verified === false, "Tampered signature correctly fails verification");
    } else {
      skip("Could not test tampered signature verification");
    }

    const all = await bobClient.receive();
    for (const m of all) await bobClient.ack(m.id);
  }

  // ═══════════════════════════════════════════════════════
  // STRESS / REALISTIC
  // ═══════════════════════════════════════════════════════

  section("Stress: Message ordering (FIFO)");
  {
    for (let i = 0; i < 10; i++) {
      await rawSend(alice.apiKey, {
        to: bob.name, type: "notification", topic: "order-test", encrypted: false, payload: { seq: i },
      });
      // Tiny delay to ensure distinct timestamps
      await new Promise(r => setTimeout(r, 10));
    }

    const msgs = await retry(() => bobClient.receive({ topic: "order-test", limit: 10 }), m => m.length === 10);
    assert(msgs.length === 10, `Received all 10 messages (got ${msgs.length})`);

    let inOrder = true;
    for (let i = 1; i < msgs.length; i++) {
      if (new Date(msgs[i].ts).getTime() < new Date(msgs[i - 1].ts).getTime()) {
        inOrder = false;
        break;
      }
    }
    assert(inOrder, "Messages returned in chronological order");

    const seqs = msgs.map(m => (m.payload as any).seq);
    const expected = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    assert(JSON.stringify(seqs) === JSON.stringify(expected), `Sequence preserved: ${JSON.stringify(seqs)}`);

    for (const m of msgs) await bobClient.ack(m.id);
  }

  section("Stress: Concurrent senders");
  {
    // Fresh agents to avoid rate limit bleed from earlier tests
    const cSender1 = await createAgent(`concurrent-s1-${ts}`);
    const cSender2 = await createAgent(`concurrent-s2-${ts}`);
    const cReceiver = await createAgent(`concurrent-rx-${ts}`);
    await kvWait();
    const cReceiverClient = makeClient(cReceiver);

    const promises = [];
    for (let i = 0; i < 5; i++) {
      promises.push(rawSend(cSender1.apiKey, {
        to: cReceiver.name, type: "notification", topic: "concurrent", encrypted: false, payload: { from: "sender1", i },
      }));
      promises.push(rawSend(cSender2.apiKey, {
        to: cReceiver.name, type: "notification", topic: "concurrent", encrypted: false, payload: { from: "sender2", i },
      }));
    }
    const results = await Promise.all(promises);
    const allOk = results.every(r => r.status === 201);
    assert(allOk, "All 10 concurrent sends returned 201");

    const msgs = await retry(() => cReceiverClient.receive({ topic: "concurrent", limit: 100 }), m => m.length === 10);
    assert(msgs.length === 10, `Receiver got all 10 concurrent messages (got ${msgs.length})`);

    const from1 = msgs.filter(m => (m.payload as any).from === "sender1").length;
    const from2 = msgs.filter(m => (m.payload as any).from === "sender2").length;
    assert(from1 === 5, `5 from sender1 (got ${from1})`);
    assert(from2 === 5, `5 from sender2 (got ${from2})`);

    for (const m of msgs) await cReceiverClient.ack(m.id);
  }

  section("Stress: Full encrypted round-trip (3 agents)");
  {
    // Fresh agents for clean rate limit counters
    const relay1 = await createAgent(`relay1-${ts}`);
    const relay2 = await createAgent(`relay2-${ts}`);
    const relay3 = await createAgent(`relay3-${ts}`);
    await kvWait();
    const r1Client = makeClient(relay1);
    const r2Client = makeClient(relay2);
    const r3Client = makeClient(relay3);
    await r1Client.discover();
    await r2Client.discover();
    await r3Client.discover();

    // r1 → r2 (encrypted), r2 → r3 (encrypted), r3 → r1 (encrypted)
    await r1Client.send(relay2.name, { step: 1, msg: "Agent1 to Agent2" }, { topic: "relay-chain" });
    await kvWait();

    const r2Inbox = await retry(() => r2Client.receive({ topic: "relay-chain" }), m => m.length >= 1);
    assert(r2Inbox.length >= 1 && (r2Inbox[0].payload as any).step === 1, "Agent2 decrypted Agent1's message");
    assert(r2Inbox[0].verified === true, "Agent1's signature verified by Agent2");

    await r2Client.send(relay3.name, { step: 2, msg: "Agent2 to Agent3", original: (r2Inbox[0].payload as any).msg }, { topic: "relay-chain" });
    await kvWait();

    const r3Inbox = await retry(() => r3Client.receive({ topic: "relay-chain" }), m => m.length >= 1);
    assert(r3Inbox.length >= 1 && (r3Inbox[0].payload as any).step === 2, "Agent3 decrypted Agent2's message");
    assert((r3Inbox[0].payload as any).original === "Agent1 to Agent2", "Original message preserved through relay");

    await r3Client.send(relay1.name, { step: 3, msg: "Agent3 to Agent1", chain: "complete" }, { topic: "relay-chain" });
    await kvWait();

    const r1Inbox = await retry(() => r1Client.receive({ topic: "relay-chain" }), m => m.length >= 1);
    assert(r1Inbox.length >= 1 && (r1Inbox[0].payload as any).step === 3, "Agent1 decrypted Agent3's message");
    assert((r1Inbox[0].payload as any).chain === "complete", "Full 3-agent encrypted relay chain works");

    for (const m of r2Inbox) await r2Client.ack(m.id);
    for (const m of r3Inbox) await r3Client.ack(m.id);
    for (const m of r1Inbox) await r1Client.ack(m.id);
  }

  // ═══════════════════════════════════════════════════════
  // CORS
  // ═══════════════════════════════════════════════════════

  section("CORS: Preflight OPTIONS");
  {
    const res = await fetch(`${BASE_URL}/messages`, { method: "OPTIONS" });
    assert(res.status === 204, `OPTIONS returns 204 (got ${res.status})`);
    assert(res.headers.get("Access-Control-Allow-Origin") === "*", "CORS allow-origin is *");
    assert(res.headers.get("Access-Control-Allow-Methods")?.includes("POST") ?? false, "CORS allows POST");
  }

  // ═══════════════════════════════════════════════════════
  // 404 / UNKNOWN ROUTES
  // ═══════════════════════════════════════════════════════

  section("Routing: Unknown paths");
  {
    const res = await fetch(`${BASE_URL}/nonexistent`);
    assert(res.status === 404, `Unknown path returns 404 (got ${res.status})`);
  }

  // ═══════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════

  console.log(`\n${"═".repeat(50)}`);
  console.log(`  ✓ ${passed} passed`);
  if (failed > 0) console.log(`  ✗ ${failed} FAILED`);
  if (skipped > 0) console.log(`  ⊘ ${skipped} skipped`);
  console.log(`  Total: ${passed + failed + skipped} assertions`);
  console.log(`${"═".repeat(50)}\n`);

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("Test suite crashed:", err);
  process.exit(1);
});
