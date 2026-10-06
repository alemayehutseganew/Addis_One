/**
 * Emits cross-language test vectors for the QR credential format.
 *
 * These come from the REAL backend signer, not a hand-written copy, so the Dart
 * test asserts against what the server actually produces. If the two
 * implementations ever drift, this fixture changes and the Dart test fails —
 * which is the point.
 *
 * Run from backend/: npx ts-node --transpile-only src/tools/emit-vectors.ts
 */
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { generateKeyPairSync } from 'node:crypto';
import {
  CredentialSigner,
  canonicalize,
} from '../modules/ticketing/credential-signer';

const { privateKey, publicKey } = generateKeyPairSync('ed25519');
const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const publicPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();

const signer = new CredentialSigner(privatePem, 'dev-key-1');

const cases = [
  {
    ticketId: 'TKT-0001',
    credentialId: 'CRD-0001',
    issuedAt: new Date('2026-10-01T00:00:00Z'),
    expiresAt: new Date('2026-10-01T01:00:00Z'),
  },
  {
    ticketId: 'TKT-0002',
    credentialId: 'CRD-0002',
    issuedAt: new Date('2026-06-15T08:30:00Z'),
    expiresAt: new Date('2026-06-15T09:45:00Z'),
  },
];

const vectors = cases.map((c) => {
  const signed = signer.sign(c);
  return {
    ticketId: c.ticketId,
    credentialId: c.credentialId,
    issuedAt: signed.payload.issuedAt,
    expiresAt: signed.payload.expiresAt,
    nonce: signed.payload.nonce,
    keyId: signed.keyId,
    signature: signed.signature,
    canonicalPayload: canonicalize(signed.payload),
    qrString: signed.qrString,
  };
});

const out = {
  note:
    'Generated from the backend CredentialSigner. The Dart QrCredential test ' +
    'must reproduce canonicalPayload exactly.',
  publicKeyPem: publicPem,
  vectors,
};

const path = resolve(
  __dirname,
  '../../../apps/passenger/test/vectors/qr_credential_vectors.json',
);
writeFileSync(path, JSON.stringify(out, null, 2), 'utf8');
console.log(`wrote ${path} with ${vectors.length} vectors`);
