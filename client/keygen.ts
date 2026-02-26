#!/usr/bin/env ts-node

import nacl from "tweetnacl";
import { encodeBase64 } from "tweetnacl-util";

// Generate X25519 keypair for encryption
const encryptionKeypair = nacl.box.keyPair();

// Generate Ed25519 keypair for signing
const signingKeypair = nacl.sign.keyPair();

const keys = {
  publicKey: encodeBase64(encryptionKeypair.publicKey),
  privateKey: encodeBase64(encryptionKeypair.secretKey),
  signingKey: encodeBase64(signingKeypair.publicKey),
  signingPrivateKey: encodeBase64(signingKeypair.secretKey),
};

console.log(JSON.stringify(keys, null, 2));
