/**
 * ClawTalk Integration Test
 *
 * Tests the full flow: register agents, encrypt+sign, send, receive, decrypt+verify, ack.
 * Run against a local wrangler dev server: CLAWTALK_URL=http://localhost:8787 ADMIN_KEY=test-admin-key npx ts-node test/integration.test.ts
 */

import nacl from "tweetnacl";
import { encodeBase64 } from "tweetnacl-util";
import { ClawTalkClient } from "../client/clawtalk-client";

const BASE_URL = process.env.CLAWTALK_URL || "http://localhost:8787";
const ADMIN_KEY = process.env.ADMIN_KEY || "test-admin-key";

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    console.log(`  ✓ ${message}`);
    passed++;
  } else {
    console.error(`  ✗ ${message}`);
    failed++;
  }
}

async function registerAgent(
  name: string,
  owner: string,
  publicKey: string,
  signingKey: string
): Promise<{ name: string; apiKey: string }> {
  const res = await fetch(`${BASE_URL}/agents`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${ADMIN_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ name, owner, publicKey, signingKey }),
  });

  if (!res.ok) {
    const err = await res.json();
    throw new Error(`Registration failed: ${JSON.stringify(err)}`);
  }

  return res.json() as Promise<{ name: string; apiKey: string }>;
}

async function main() {
  console.log(`\nClawTalk Integration Test`);
  console.log(`Target: ${BASE_URL}\n`);

  // Step 0: Health check
  console.log("Step 0: Health check");
  const healthRes = await fetch(`${BASE_URL}/health`);
  const health = (await healthRes.json()) as { status: string; ts: string; agents: number };
  assert(health.status === "ok", "Health endpoint returns ok");

  // Step 1: Generate two agent keypairs
  console.log("\nStep 1: Generate keypairs");
  const aliceEncrypt = nacl.box.keyPair();
  const aliceSign = nacl.sign.keyPair();
  const bobEncrypt = nacl.box.keyPair();
  const bobSign = nacl.sign.keyPair();
  assert(aliceEncrypt.publicKey.length === 32, "Alice encryption keypair generated");
  assert(bobSign.publicKey.length === 32, "Bob signing keypair generated");

  // Step 2: Register both agents
  console.log("\nStep 2: Register agents");
  const aliceReg = await registerAgent(
    `alice-${Date.now()}`,
    "test",
    encodeBase64(aliceEncrypt.publicKey),
    encodeBase64(aliceSign.publicKey)
  );
  assert(aliceReg.apiKey.startsWith("ct_"), "Alice registered with ct_ prefixed key");

  const bobReg = await registerAgent(
    `bob-${Date.now()}`,
    "test",
    encodeBase64(bobEncrypt.publicKey),
    encodeBase64(bobSign.publicKey)
  );
  assert(bobReg.apiKey.startsWith("ct_"), "Bob registered with ct_ prefixed key");

  // Step 2b: Verify duplicate registration fails
  console.log("\nStep 2b: Verify duplicate registration rejected");
  const dupRes = await fetch(`${BASE_URL}/agents`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${ADMIN_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: aliceReg.name,
      owner: "test",
      publicKey: encodeBase64(aliceEncrypt.publicKey),
      signingKey: encodeBase64(aliceSign.publicKey),
    }),
  });
  assert(dupRes.status === 409, "Duplicate agent registration returns 409");

  // Step 3: Create clients
  console.log("\nStep 3: Create clients");
  const alice = new ClawTalkClient({
    baseUrl: BASE_URL,
    apiKey: aliceReg.apiKey,
    agentName: aliceReg.name,
    privateKey: aliceEncrypt.secretKey,
    signingKey: aliceSign.secretKey,
  });

  const bob = new ClawTalkClient({
    baseUrl: BASE_URL,
    apiKey: bobReg.apiKey,
    agentName: bobReg.name,
    privateKey: bobEncrypt.secretKey,
    signingKey: bobSign.secretKey,
  });

  // Step 4: Alice discovers agents (populates key cache)
  console.log("\nStep 4: Discover agents");
  const agents = await alice.discover();
  assert(agents.length >= 2, `Discovered ${agents.length} agents`);
  const bobEntry = agents.find((a) => a.name === bobReg.name);
  assert(!!bobEntry, "Bob found in agent list");
  assert(!!bobEntry?.publicKey, "Bob's public key available");

  // Step 5: Alice sends encrypted+signed message to Bob
  console.log("\nStep 5: Alice sends encrypted message to Bob");
  const testPayload = { text: "Hello Bob, this is a secret message!", code: 42 };
  const sendResult = await alice.send(bobReg.name, testPayload, {
    type: "request",
    topic: "greeting",
  });
  assert(!!sendResult.id, `Message sent with id: ${sendResult.id}`);
  assert(!!sendResult.ts, `Message timestamp: ${sendResult.ts}`);

  // Step 6: Bob receives, decrypts, and verifies
  console.log("\nStep 6: Bob receives and decrypts");
  const messages = await bob.receive({ topic: "greeting" });
  assert(messages.length >= 1, `Bob received ${messages.length} message(s)`);

  const received = messages.find((m) => m.id === sendResult.id);
  assert(!!received, "Found the sent message");
  assert(received?.verified === true, "Signature verified");
  assert(
    (received?.payload as { text: string }).text === testPayload.text,
    "Decrypted payload matches original"
  );
  assert(
    (received?.payload as { code: number }).code === testPayload.code,
    "Decrypted payload code matches"
  );
  assert(received?.from === aliceReg.name, "Sender is Alice");
  assert(received?.topic === "greeting", "Topic preserved");

  // Step 7: Bob acknowledges (deletes) the message
  console.log("\nStep 7: Bob acknowledges message");
  await bob.ack(sendResult.id);
  assert(true, "Message acknowledged without error");

  // Step 8: Verify message is gone
  console.log("\nStep 8: Verify message deleted");
  const afterAck = await bob.receive();
  const stillThere = afterAck.find((m) => m.id === sendResult.id);
  assert(!stillThere, "Message no longer in inbox after ack");

  // Step 9: Verify audit log has both sent and received entries
  console.log("\nStep 9: Verify audit log entries");
  const auditRes = await fetch(`${BASE_URL}/audit`, {
    headers: { Authorization: `Bearer ${ADMIN_KEY}` },
  });
  assert(auditRes.status === 200, "GET /audit returns 200 with admin key");
  const auditData = (await auditRes.json()) as {
    entries: Array<{
      messageId: string;
      direction: string;
      from: string;
      to: string;
      topic?: string;
      payload: object;
      loggedBy: string;
      loggedAt: string;
      ts: string;
    }>;
    cursor?: string;
  };

  const sentEntry = auditData.entries.find(
    (e) => e.messageId === sendResult.id && e.direction === "sent"
  );
  const receivedEntry = auditData.entries.find(
    (e) => e.messageId === sendResult.id && e.direction === "received"
  );
  assert(!!sentEntry, "Audit log contains 'sent' entry from Alice");
  assert(!!receivedEntry, "Audit log contains 'received' entry from Bob");
  assert(
    sentEntry?.loggedBy === aliceReg.name,
    "Sent entry loggedBy is Alice"
  );
  assert(
    receivedEntry?.loggedBy === bobReg.name,
    "Received entry loggedBy is Bob"
  );
  assert(
    (sentEntry?.payload as { text: string }).text === testPayload.text,
    "Audit sent payload matches original plaintext"
  );
  assert(
    (receivedEntry?.payload as { text: string }).text === testPayload.text,
    "Audit received payload matches original plaintext"
  );
  assert(sentEntry?.topic === "greeting", "Audit sent entry has correct topic");

  // Step 10: Test audit filters
  console.log("\nStep 10: Test audit filters");
  const fromFilterRes = await fetch(
    `${BASE_URL}/audit?from=${encodeURIComponent(aliceReg.name)}`,
    { headers: { Authorization: `Bearer ${ADMIN_KEY}` } }
  );
  const fromFiltered = (await fromFilterRes.json()) as { entries: Array<{ from: string }> };
  assert(
    fromFiltered.entries.length > 0 &&
      fromFiltered.entries.every((e) => e.from === aliceReg.name),
    "Filter by from=alice returns only Alice's entries"
  );

  const topicFilterRes = await fetch(`${BASE_URL}/audit?topic=greeting`, {
    headers: { Authorization: `Bearer ${ADMIN_KEY}` },
  });
  const topicFiltered = (await topicFilterRes.json()) as {
    entries: Array<{ topic?: string }>;
  };
  assert(
    topicFiltered.entries.length > 0 &&
      topicFiltered.entries.every((e) => e.topic === "greeting"),
    "Filter by topic=greeting returns only matching entries"
  );

  // Step 11: Non-admin key gets 401 on GET /audit
  console.log("\nStep 11: Non-admin key rejected for GET /audit");
  const nonAdminAuditRes = await fetch(`${BASE_URL}/audit`, {
    headers: { Authorization: `Bearer ${aliceReg.apiKey}` },
  });
  assert(
    nonAdminAuditRes.status === 401,
    "GET /audit with agent key returns 401"
  );

  // Step 12: Test DELETE /audit
  console.log("\nStep 12: Test DELETE /audit");
  const futureDate = new Date(Date.now() + 86400000).toISOString();
  const deleteRes = await fetch(
    `${BASE_URL}/audit?before=${encodeURIComponent(futureDate)}`,
    {
      method: "DELETE",
      headers: { Authorization: `Bearer ${ADMIN_KEY}` },
    }
  );
  assert(deleteRes.status === 200, "DELETE /audit returns 200");
  const deleteData = (await deleteRes.json()) as { deleted: number };
  assert(deleteData.deleted >= 2, `Deleted ${deleteData.deleted} audit entries`);

  // Verify audit is now empty
  const afterDeleteRes = await fetch(`${BASE_URL}/audit`, {
    headers: { Authorization: `Bearer ${ADMIN_KEY}` },
  });
  const afterDeleteData = (await afterDeleteRes.json()) as {
    entries: Array<object>;
  };
  assert(
    afterDeleteData.entries.length === 0,
    "Audit log is empty after delete"
  );

  // Summary
  console.log(`\n${"=".repeat(40)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);
  console.log(`${"=".repeat(40)}\n`);

  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error("Test failed:", err);
  process.exit(1);
});
