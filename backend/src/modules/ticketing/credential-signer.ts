/**
 * QR credential signing and verification — implements architecture.md I4.
 *
 * Design constraints:
 *  - Ed25519. Used rather than RSA/ECDSA because verification keys are embedded
 *    in staff handhelds: a 32-byte key fits anywhere, and verification is fast
 *    enough for a low-end device when online.
 *  - The signed payload contains NO commercial data. No fare, no user id, no
 *    route, no name — a reference plus time bounds and a nonce. A photo of
 *    someone's QR reveals nothing about them and cannot be replayed for a
 *    different fare.
 *  - Canonical serialisation is explicit and versioned. JSON.stringify key order
 *    is not contractually stable across engines, so the payload is flattened
 *    into a fixed field order before signing.
 */

import {
  createPrivateKey,
  createPublicKey,
  sign as cryptoSign,
  verify as cryptoVerify,
  randomBytes,
  KeyObject,
} from 'node:crypto';

export const CREDENTIAL_VERSION = 1;

export interface CredentialPayload {
  v: number;
  ticketId: string;
  credentialId: string;
  issuedAt: number;
  expiresAt: number;
  nonce: string;
}

export interface SignedCredential {
  payload: CredentialPayload;
  keyId: string;
  signature: string;
  qrString: string;
}

export type VerifyFailureReason =
  | 'MALFORMED'
  | 'UNSUPPORTED_VERSION'
  | 'BAD_SIGNATURE'
  | 'EXPIRED'
  | 'NOT_YET_VALID'
  | 'UNKNOWN_KEY';

export interface VerifyResult {
  valid: boolean;
  reason?: VerifyFailureReason;
  payload?: CredentialPayload;
  msRemaining?: number;
}

export function generateNonce(): string {
  // 128 bits of entropy. Unguessability is what stops an attacker from
  // pre-computing valid nonces.
  return randomBytes(16).toString('hex');
}

/**
 * Deterministic, versioned field order. Never build this by stringifying an
 * object literal — key ordering is not contractually stable, and a mismatch
 * between the signing and verifying paths would reject valid tickets.
 */
export function canonicalize(payload: CredentialPayload): string {
  return [
    payload.v,
    payload.ticketId,
    payload.credentialId,
    payload.issuedAt,
    payload.expiresAt,
    payload.nonce,
  ].join('|');
}

function parsePrivateKey(privateKeyPem: string): KeyObject {
  return createPrivateKey(privateKeyPem);
}

function parsePublicKey(publicKeyPem: string): KeyObject {
  return createPublicKey(publicKeyPem);
}

export class CredentialSigner {
  constructor(
    private readonly privateKeyPem: string,
    readonly keyId: string,
  ) {}

  /**
   * The public verification keys this signer is authoritative for, keyed by keyId.
   *
   * The server holds a private key but never had a way to verify with it:
   * `CredentialSigner.verify` takes a map of public PEMs, so an inspector's scan
   * had nothing to check a signature against. Deriving the public half here keeps
   * the key material in exactly one place — the module that loads it from disk —
   * instead of having the validator re-read the private file and re-derive it,
   * which is a second path to the same secret that can drift.
   *
   * A real deployment publishes a *set* of keys so that tickets signed before a
   * rotation still validate. With one key on disk that set has one member, and the
   * shape is already correct for adding more.
   */
  publicKeys(): Record<string, string> {
    const publicKey = createPublicKey(parsePrivateKey(this.privateKeyPem));
    return {
      [this.keyId]: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    };
  }

  sign(input: {
    ticketId: string;
    credentialId: string;
    issuedAt: Date;
    expiresAt: Date;
    nonce?: string;
  }): SignedCredential {
    const payload: CredentialPayload = {
      v: CREDENTIAL_VERSION,
      ticketId: input.ticketId,
      credentialId: input.credentialId,
      issuedAt: Math.floor(input.issuedAt.getTime() / 1000),
      expiresAt: Math.floor(input.expiresAt.getTime() / 1000),
      nonce: input.nonce ?? generateNonce(),
    };

    const signature = cryptoSign(
      null,
      Buffer.from(canonicalize(payload), 'utf8'),
      parsePrivateKey(this.privateKeyPem),
    ).toString('base64');

    return {
      payload,
      keyId: this.keyId,
      signature,
      qrString: buildQrString(payload, this.keyId, signature),
    };
  }

  /** Public verification, used by the server and mirrored in the staff app. */
  static verify(qrString: string, publicKeyPems: Record<string, string>): VerifyResult {
    const parsed = parseQrString(qrString);
    if (!parsed) return { valid: false, reason: 'MALFORMED' };
    if (parsed.payload.v !== CREDENTIAL_VERSION) {
      return { valid: false, reason: 'UNSUPPORTED_VERSION' };
    }

    const publicKeyPem = publicKeyPems[parsed.keyId];
    if (!publicKeyPem) return { valid: false, reason: 'UNKNOWN_KEY' };

    let ok = false;
    try {
      ok = cryptoVerify(
        null,
        Buffer.from(canonicalize(parsed.payload), 'utf8'),
        parsePublicKey(publicKeyPem),
        Buffer.from(parsed.signature, 'base64'),
      );
    } catch {
      // A malformed key or signature must fail closed, never throw upward
      // into the scanner's hot path.
      return { valid: false, reason: 'BAD_SIGNATURE' };
    }
    if (!ok) return { valid: false, reason: 'BAD_SIGNATURE' };

    const nowSeconds = Math.floor(Date.now() / 1000);
    const msRemaining = (parsed.payload.expiresAt - nowSeconds) * 1000;
    if (nowSeconds < parsed.payload.issuedAt) {
      return { valid: false, reason: 'NOT_YET_VALID', payload: parsed.payload, msRemaining };
    }
    if (nowSeconds > parsed.payload.expiresAt) {
      return { valid: false, reason: 'EXPIRED', payload: parsed.payload, msRemaining };
    }

    return { valid: true, payload: parsed.payload, msRemaining };
  }
}

function buildQrString(
  payload: CredentialPayload,
  keyId: string,
  signature: string,
): string {
  return JSON.stringify({
    t: payload.ticketId,
    c: payload.credentialId,
    i: payload.issuedAt,
    e: payload.expiresAt,
    n: payload.nonce,
    k: keyId,
    s: signature,
  });
}

function parseQrString(
  qrString: string,
): { payload: CredentialPayload; keyId: string; signature: string } | null {
  try {
    const raw = JSON.parse(qrString);
    if (
      typeof raw?.t !== 'string' ||
      typeof raw?.c !== 'string' ||
      typeof raw?.n !== 'string' ||
      typeof raw?.k !== 'string' ||
      typeof raw?.s !== 'string' ||
      typeof raw?.i !== 'number' ||
      typeof raw?.e !== 'number'
    ) {
      return null;
    }
    return {
      payload: {
        v: CREDENTIAL_VERSION,
        ticketId: raw.t,
        credentialId: raw.c,
        issuedAt: raw.i,
        expiresAt: raw.e,
        nonce: raw.n,
      },
      keyId: raw.k,
      signature: raw.s,
    };
  } catch {
    return null;
  }
}
