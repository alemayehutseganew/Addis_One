# ADR 0002 — Ed25519 for QR credential signatures

- **Status:** Accepted
- **Date:** 2026-10-01

## Context

Passenger ticket QR codes must be verifiable **offline** by staff handhelds
with intermittent connectivity (invariant I4). That constraint drives the
choice of algorithm, not preference.

The credentials are signed on the server; staff devices hold only the public
key and verify locally, queuing results for later reconciliation.

## Decision

Use **Ed25519**.

- 32-byte public keys, 64-byte signatures, 32-byte private keys.
- Verification is a handful of field operations — fast enough for a low-end
  handheld with no accelerator.
- Signature is deterministic: the same payload always yields the same
  signature, which removes an entire class of replay-with-mutation questions.

RSA is the rejected alternative: 2048-bit keys mean a ~294-byte signature,
which bloats every QR code, and verification cost scales with key size.

## Consequences

- Key material must be distributed to staff devices at enrolment. Compromised
  device keys must be revocable, hence the `OfflineKey` table with `revokedAt`.
- Key rotation is first-class: `QrCredential.keyId` records which key signed,
  so a verifier can hold several public keys and accept historical tickets
  signed by a retired key.
- Ed25519 support in Dart (`cryptography` / `pointycastle`) is well established,
  so the staff app can verify identically to the server.

## Related

- I4 in `docs/architecture.md` — QR payloads carry no commercial data.
