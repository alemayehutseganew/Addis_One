# Addis One

Citywide transport operating and assurance platform for Addis Ababa.

> **Flutter is the client layer, not the system.** Every authoritative decision
> — fare calculation, ticket issuance, QR signature, validation outcome — happens
> on the server. See `docs/architecture.md` §2 for why.

## Status

| Area | State |
| --- | --- |
| Architecture + ADRs | Done |
| Database schema (42 models, 16 enums) | Done, migration applied |
| Fare engine | Done, unit tested |
| QR credential signer (Ed25519) | Done, unit tested |
| Payment orchestrator + provider abstraction | Done, unit tested |
| Ticket state machine (I1 gate) | Done, unit tested |
| **Passenger app scaffold** | Done — Flutter 3.47.5 / Dart 3.13.4, Android SDK 36 |
| **Money type (integer fils)** | Done, unit tested |
| **QR credential Dart mirror** | Done, cross-language contract tested |
| **Theme + Amharic/English localization** | Done |
| **Home screen** | Done |
| **Journey planner domain** | Done — sealed purchase states, server-fare only |
| **Journey results screen** | Done — cheapest/fastest/simplest |
| **Payment sheet + QR ticket screen** | Done |
| PostgreSQL / Redis | Running (`at-postgres`, `at-redis`) |
| Dio API client + Riverpod wiring + GoRouter | Not started |
| Auth/OTP screens | Not started |
| Staff app | Not started |

**86 backend tests + 41 Flutter tests passing. `flutter analyze` clean.**

### The client enforces I1 and I2 too

`PurchaseController` (client side) mirrors the server invariants, because a
correct backend still needs a client that cannot shortcut it:

- **`PurchaseState` is a sealed union.** Only `PurchaseSuccess` carries a
  ticket — an impossible combination such as "ticket without payment" cannot
  be represented, let alone rendered.
- **Only `PaymentStatus.confirmed` unlocks issuance.** `requiresAction`
  deliberately does not qualify: it carries a redirect URL and means the payer
  was *sent* to pay, not that they paid.
- **The idempotency key is generated once, before the first attempt**, and
  reused for every retry of the same purchase — so a double-tap or a network
  retry converges on one charge. A fresh key is issued only after `reset()`.
- **The pay button locks while a purchase is in flight**, preventing a second
  concurrent attempt from the UI side.

There are tests for the exact failure the blueprint warns about: a provider
that stays in `REQUIRES_ACTION` forever produces a timeout **failure**, and the
ticket endpoint is never even called.

### The cross-language contract test

The Dart `QrCredential` and the backend `CredentialSigner` must agree on the
signed payload byte-for-byte, or every ticket fails validation in production.
That agreement is enforced by a fixture generated from the *real* backend
signer (`backend/src/tools/emit-vectors.ts`) and asserted in
`apps/passenger/test/qr_credential_test.dart`. If either implementation changes,
the test fails rather than the city discovering it at a bus stop.

## Layout

```
docs/       architecture.md, adr/
backend/    NestJS + TypeScript + Prisma + PostgreSQL + Redis
  prisma/   schema + migrations
  src/
    common/ money.ts                        integer-fils helpers
    modules/fares/      fare-engine.ts       pure, unit tested
    modules/payments/   payment-provider.ts  provider interface + registry
                         payment-orchestrator.ts  I2 enforcement
                         mock-payment-adapter.ts  dev/test adapters
    modules/ticketing/  ticket-state-machine.ts   I1 enforcement
                         credential-signer.ts      Ed25519 sign/verify
    tools/      emit-vectors.ts                 cross-language test fixtures
apps/
  passenger/   Flutter passenger app (running)
  staff/       Flutter staff app (not started)
infra/     docker-compose.yml
scripts/   dev workflow helpers
packages/  addis_core/         (not started)
```

### Flutter

```powershell
cd apps\passenger
C:\src\flutter\bin\flutter.bat pub get
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test
```

Regenerating the QR contract fixture after a backend signing change:

```powershell
cd backend
npx ts-node --transpile-only src/tools/emit-vectors.ts
```

## Getting started

```bash
# 1. infrastructure (Postgres on 5433, Redis on 6380)
docker compose -f infra/docker-compose.yml up -d

# 2. install dependencies
cd backend && npm install

# 3. create the schema and generate the client
#    (use scripts/run-prisma.ps1 — see the note below)
.\scripts\run-prisma.ps1 migrate dev --name init
.\scripts\run-prisma.ps1 generate

# 4. run tests
.\scripts\run-jest.ps1
```

Copy `backend/.env.example` to `backend/.env` first.

### Note on DATABASE_URL

This machine defines a machine-level `DATABASE_URL` for an unrelated project,
using an incompatible `postgresql+psycopg2` scheme. OS environment variables
override `.env`, so Prisma fails with *"the URL must start with postgresql://"*.
`scripts/run-prisma.ps1` clears the inherited variable for the process. If you
call Prisma directly, clear it first:

```powershell
$env:DATABASE_URL = $null
```

## Ports

This project uses non-default host ports so it never collides with other stacks
on the same machine:

| Service | Host port |
| --- | --- |
| PostgreSQL | 5433 |
| TimescaleDB | 5434 |
| Redis | 6380 |

## Core invariants

These are enforced in the database and cryptography, not in application code,
because application-layer checks are bypassable in a revenue system.

- **I1** A ticket exists only against a confirmed payment.
- **I2** `Payment.idempotencyKey` is `UNIQUE` — double-tap cannot double-charge.
- **I3** Every ticket pins the fare rule version used.
- **I4** QR payloads carry no fare, user, or route data — identifiers only.
- **I5** Privileged actions are appended to an immutable audit log.

Details and rationale: `docs/architecture.md` §5.
