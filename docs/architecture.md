# Addis One — System Architecture

> Status: **Living document.** Authoritative source for how the platform is
> structured, and why.

---

## 1. Purpose

Addis One is a **citywide transport operating and assurance platform** for Addis
Ababa. It is *not* a ticketing app — ticketing is one capability of the system.

| Concern | Summary |
| --- | --- |
| **Experience** | Citizen journey planning, purchase, travel |
| **Mobility** | Routes, stops, vehicles, trips, scheduling, live tracking |
| **Fare & Payment** | Versioned fare rules, payment orchestration, settlement |
| **Integration** | Operators, Telebirr, CBE Birr, banks, USSD/SMS |
| **Data & Assurance** | Audit trail, reconciliation, fraud analytics |
| **Infrastructure** | Identity, devices, key management, observability |
| **Governance** | Control tower, operator portal, policy authority |

---

## 2. The most important architectural rule

> **Flutter is the client/application layer. It is not the system.**

A ticket is not valid because a phone said so. A fare is not 25 ETB because an
`if` statement in Dart said so. A payment is not successful because the user
came back from a redirect screen.

Every authoritative decision — fare calculation, ticket issuance, QR signature,
validation outcome — happens on the server. The client renders server truth, and
may be offline only in a strictly constrained, later-reconciled way (staff
validation only).

The alternative fails catastrophically: a modified client could mint valid
tickets and forge payments. For a public transport revenue system that is a
revenue-integrity failure.

---

## 3. Layer view

```
                        ADDIS ONE
                            │
       ┌────────────────────┼────────────────────┐
       │                    │                    │
  PASSENGER APP       STAFF/INSPECTOR       GOVERNANCE
     Flutter              Flutter             Web
       │                    │                    │
       └────────────────────┼────────────────────┘
                            │
                     ADDIS ONE API
                    (API Gateway)
                            │

---

## 4. Deployment shape

**Modular monolith.** One deployable API, organised into modules with explicit
boundaries and no cross-module table writes.

A microservice split is a *later* refactor, enabled by those boundaries.
Premature distribution would add network failure modes to a system whose
correctness already depends on transactional integrity. Recorded in
`adr/0001-modular-monolith.md`.

```
┌─────────────────────────────────────────────────┐
│  API Gateway  (TLS, JWT validation, rate limit) │
├─────────────────────────────────────────────────┤
│  Identity │ Mobility │ Fare │ Ticketing │        │
│  Payments │ Validation │ Audit │ Notification   │
├─────────────────────────────────────────────────┤
│  PostgreSQL (transactional)   Redis (cache/lock)│
│  Object storage (credentials) Event bus          │
└─────────────────────────────────────────────────┘
```

Traffic split at the edge:

- **REST + SSE/WebSocket** for command/query and live vehicle positions
- **Never** long-polled fleet positions per client — that is a database
  stampede. Vehicle GPS flows to a streaming/topic layer; clients subscribe.

---

## 5. The five load-bearing invariants

The rules the system must never violate. Each is enforced at the **database or
cryptographic** layer wherever possible, because application-layer checks are
bypassable and this is a revenue system.

**I1 — A ticket exists only against a confirmed payment.**
Issuance is triggered by the `PAYMENT_CONFIRMED` transition inside the payments
domain. Never by a client redirect, never by a client return value, never by a
"user pressed Pay" event.

**I2 — Idempotency is a database constraint.**
`payments.idempotency_key` is `UNIQUE`. A repeated request returns the original
payment. Double-tap, retry, and network replay cannot produce a second charge.

**I3 — Fares are versioned and tickets pin their version.**
Every ticket stores the `fare_rule_version` used. Fare policy changes never
mutate historical pricing, so an old ticket stays explicable years later.

**I4 — QR payloads carry no commercial data.**
The QR holds identifiers, timestamps, a nonce, and a signature — not the fare,

---

## 5.1 How I1 and I2 are enforced in code

The invariants in §5 are not documentation. They are structural properties of
the code in `src/modules/payments` and `src/modules/ticketing`.

### I1 — a ticket exists only against a confirmed payment

Enforced from three directions, so removing any one still leaves a barrier:

1. **The orchestrator cannot issue tickets.** `PaymentOrchestratorService`
   returns payment state only. There is no method that mints a ticket, so
   "payment succeeded" and "ticket issued" are not conflated by construction.
2. **The state machine has exactly one edge into `TICKET_ISSUED`**, from
   `PAYMENT_CONFIRMED`. A test iterates every status and asserts none other can
   reach it.
3. **`assertIssuable(ticketStatus, paymentStatus)`** takes the observed payment
   status and refuses anything that is not `CONFIRMED`, with an error message
   naming the I1 violation.

The failure this prevents is specific: treating a client returning from a
payment redirect as proof of payment. `REQUIRES_ACTION` carries a redirect URL
and is explicitly *not* confirmation; there is a test for exactly that.

### I2 — idempotency is a database constraint

The guarantee is the unique index `Payment_idempotencyKey_key`. Everything else
is an optimisation layered on top:

- `createPayment` checks for an existing key first (fast path).
- If the check misses but a concurrent request wins the race, the insert raises
  a unique violation, which is caught and the **winning** payment is returned.
  Parallel double-taps therefore converge on one charge rather than surfacing
  an error to a passenger who tapped twice.
- `initiate` never re-opens a payment in a terminal state, so a replayed
  request cannot restart a settled or failed payment.
- `capture` and `refund` return early when already applied.

`InMemoryPaymentRepository` deliberately reproduces the unique violation, so
the tests exercise the same race the database enforces rather than assuming it.

### Failure paths that are modelled, not hand-waved

- **Stale webhooks** cannot undo a settled payment — terminal states are
  immutable on webhook application.
- **Non-authoritative webhook states** (`PENDING`, `AUTHORIZED`) are ignored;
  only a terminal webhook advances the payment.
- **Over-capture and over-refund** are rejected outright, not clamped.
- **Unknown providers** raise rather than silently no-op, so a missing adapter
  is a loud failure rather than a free ticket.

### Assisted (cash/agent) sales

Cash flows through the same orchestrator and produces the same core records,
with `collectedByStaffId` and `shiftId` attached. This is what makes shift
reconciliation possible — an agent sale that bypassed the core would be revenue
with no audit trail.

---

## 6. Cross-cutting concerns

| Concern | Approach |
| --- | --- |
| Authentication | Phone OTP for citizens; password + MFA for staff |
| Authorization | Role-based, 12 roles, permission strings, dual control on high-risk ops |
| Money | Integer minor units (fils). **Never** floating point. |
| Time | UTC everywhere; rendered `Africa/Addis_Ababa` at the edge |
| IDs | Prefixed, sortable, non-enumerable (`TKT-…`, `PAY-…`, `CRD-…`) |
| Freshness | Every live reading carries REAL_TIME / ESTIMATED / SCHEDULED / STALE / UNKNOWN |

---

## 7. Repository layout

```
AddisTransport/
├─ docs/           architecture, data model, API spec, ADRs
├─ backend/        NestJS + TypeScript + Prisma + PostgreSQL + Redis
├─ apps/
│  ├─ passenger/   Flutter passenger app
│  └─ staff/       Flutter staff/inspector app (offline-capable)
├─ packages/       shared Dart package (models, api client, crypto verifier)
└─ infra/          Docker Compose, configs
```

Related: `data-model.md`, `api-spec.md`, `adr/`.

not the user, not the route. It is a *reference*, resolved by the validator.
Signatures are **Ed25519**; the public key is embedded in staff devices at
enrolment so offline validation is cryptographically real.

**I5 — Every privileged action is audited.**
Refunds, overrides, voids, fare changes, cash declarations, device lifecycle.
Append-only, with actor, device, IP, before/after, and a reason.

       ┌────────────────────┼────────────────────┐
       │                    │                    │
  MOBILITY ENGINE       FARE ENGINE   PAYMENT ORCHESTRATOR
       │                    │                    │
       └────────────────────┼────────────────────┘
                            │
                    INTEGRATION LAYER
   ┌──────────┬──────────┬───┴────┬──────────┐
   │          │          │        │          │
  BUS       TAXI       RAIL  TELEBIRR     BANKS
   └──────────┴──────────┴────────┴──────────┘
                            │
                     DATA + AUDIT
                            │
                 GOVERNMENT CONTROL TOWER
```
