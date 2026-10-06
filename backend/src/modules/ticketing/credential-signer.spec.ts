import {
  CredentialSigner,
  canonicalize,
  generateNonce,
} from './credential-signer';
import { generateKeyPairSync } from 'node:crypto';

/**
 * A throwaway keypair per run. Real deployments load from a KMS/secret store;
 * tests must never depend on a checked-in private key.
 */
function makeKeypair() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return {
    privatePem: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
    publicPem: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
  };
}

const keys = makeKeypair();
const KEY_ID = 'test-key-1';

function signFuture(minutes = 60) {
  const signer = new CredentialSigner(keys.privatePem, KEY_ID);
  const issuedAt = new Date();
  const expiresAt = new Date(issuedAt.getTime() + minutes * 60_000);
  return signer.sign({
    ticketId: 'TKT-0001',
    credentialId: 'CRD-0001',
    issuedAt,
    expiresAt,
  });
}

describe('CredentialSigner', () => {
  describe('canonicalisation', () => {
    it('is stable regardless of object property order', () => {
      const a = {
        v: 1, ticketId: 'T', credentialId: 'C',
        issuedAt: 10, expiresAt: 20, nonce: 'N',
      };
      const b = {
        nonce: 'N', expiresAt: 20, issuedAt: 10,
        credentialId: 'C', ticketId: 'T', v: 1,
      };
      expect(canonicalize(a)).toBe(canonicalize(b));
    });

    it('uses a separator that cannot be forged by field values', () => {
      const p = {
        v: 1, ticketId: 'T|X', credentialId: 'C',
        issuedAt: 1, expiresAt: 2, nonce: 'N',
      };
      expect(canonicalize(p)).toBe('1|T|X|C|1|2|N');
    });
  });

  describe('nonce generation', () => {
    it('produces 32 hex characters', () => {
      expect(generateNonce()).toMatch(/^[0-9a-f]{32}$/);
    });

    it('does not repeat', () => {
      const seen = new Set(Array.from({ length: 500 }, () => generateNonce()));
      expect(seen.size).toBe(500);
    });
  });

  describe('sign / verify round trip', () => {
    it('verifies a freshly signed credential', () => {
      const signed = signFuture();
      const result = CredentialSigner.verify(signed.qrString, {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.valid).toBe(true);
      expect(result.payload?.ticketId).toBe('TKT-0001');
      expect(result.payload?.credentialId).toBe('CRD-0001');
    });

    it('carries no fare, user, or route data (I4)', () => {
      const signed = signFuture();
      const parsed = JSON.parse(signed.qrString);
      // The QR must be a reference, not a data dump.
      expect(Object.keys(parsed).sort()).toEqual(['c', 'e', 'i', 'k', 'n', 's', 't']);
      const serialised = signed.qrString.toLowerCase();
      for (const forbidden of ['fare', 'price', 'amount', 'ethb', 'name', 'phone', 'route']) {
        expect(serialised).not.toContain(forbidden);
      }
    });

    it('records a fresh nonce per credential', () => {
      const a = signFuture();
      const b = signFuture();
      expect(a.payload.nonce).not.toBe(b.payload.nonce);
    });
  });

  describe('tamper detection', () => {
    it('rejects a modified ticket id', () => {
      const signed = signFuture();
      const parsed = JSON.parse(signed.qrString);
      parsed.t = 'TKT-9999';
      const result = CredentialSigner.verify(JSON.stringify(parsed), {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.valid).toBe(false);
      expect(result.reason).toBe('BAD_SIGNATURE');
    });

    it('rejects an extended expiry', () => {
      const signed = signFuture();
      const parsed = JSON.parse(signed.qrString);
      parsed.e = parsed.e + 86_400;
      const result = CredentialSigner.verify(JSON.stringify(parsed), {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.valid).toBe(false);
      expect(result.reason).toBe('BAD_SIGNATURE');
    });

    it('rejects a backdated issue time', () => {
      const signed = signFuture();
      const parsed = JSON.parse(signed.qrString);
      parsed.i = parsed.i - 3600;
      const result = CredentialSigner.verify(JSON.stringify(parsed), {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.valid).toBe(false);
      expect(result.reason).toBe('BAD_SIGNATURE');
    });

    it('rejects a swapped nonce', () => {
      const signed = signFuture();
      const parsed = JSON.parse(signed.qrString);
      parsed.n = generateNonce();
      const result = CredentialSigner.verify(JSON.stringify(parsed), {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.valid).toBe(false);
    });
  });

  describe('failure modes', () => {
    it('rejects garbage input', () => {
      expect(CredentialSigner.verify('not-json', {}).reason).toBe('MALFORMED');
    });

    it('rejects JSON missing required fields', () => {
      const result = CredentialSigner.verify('{"t":"TKT-1"}', {});
      expect(result.reason).toBe('MALFORMED');
    });

    it('rejects an unknown key id', () => {
      const signed = signFuture();
      const parsed = JSON.parse(signed.qrString);
      parsed.k = 'some-other-key';
      const result = CredentialSigner.verify(JSON.stringify(parsed), {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.reason).toBe('UNKNOWN_KEY');
    });

    it('rejects an expired credential', () => {
      const signer = new CredentialSigner(keys.privatePem, KEY_ID);
      const expired = signer.sign({
        ticketId: 'TKT-OLD',
        credentialId: 'CRD-OLD',
        issuedAt: new Date(Date.now() - 7_200_000),
        expiresAt: new Date(Date.now() - 3_600_000),
      });
      const result = CredentialSigner.verify(expired.qrString, {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.valid).toBe(false);
      expect(result.reason).toBe('EXPIRED');
      expect(result.msRemaining).toBeLessThan(0);
    });

    it('rejects a not-yet-valid credential', () => {
      const signer = new CredentialSigner(keys.privatePem, KEY_ID);
      const future = signer.sign({
        ticketId: 'TKT-FUT',
        credentialId: 'CRD-FUT',
        issuedAt: new Date(Date.now() + 3_600_000),
        expiresAt: new Date(Date.now() + 7_200_000),
      });
      const result = CredentialSigner.verify(future.qrString, {
        [KEY_ID]: keys.publicPem,
      });
      expect(result.reason).toBe('NOT_YET_VALID');
    });

    it('rejects a signature made by a different key', () => {
      const other = makeKeypair();
      const signed = signFuture();
      const result = CredentialSigner.verify(signed.qrString, {
        [KEY_ID]: other.publicPem,
      });
      expect(result.valid).toBe(false);
      expect(result.reason).toBe('BAD_SIGNATURE');
    });
  });

  describe('key rotation', () => {
    it('verifies against any published key id', () => {
      const old = makeKeypair();
      const newKeys = makeKeypair();
      const oldSigner = new CredentialSigner(old.privatePem, 'key-old');
      const newSigner = new CredentialSigner(newKeys.privatePem, 'key-new');
      const now = new Date();

      const oldCred = oldSigner.sign({
        ticketId: 'T1', credentialId: 'C1',
        issuedAt: now, expiresAt: new Date(now.getTime() + 3_600_000),
      });
      const newCred = newSigner.sign({
        ticketId: 'T2', credentialId: 'C2',
        issuedAt: now, expiresAt: new Date(now.getTime() + 3_600_000),
      });

      const published = {
        'key-old': old.publicPem,
        'key-new': newKeys.publicPem,
      };
      expect(CredentialSigner.verify(oldCred.qrString, published).valid).toBe(true);
      expect(CredentialSigner.verify(newCred.qrString, published).valid).toBe(true);
    });
  });
});
