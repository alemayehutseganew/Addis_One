# ADR 0001 — Modular monolith, not microservices

- **Status:** Accepted
- **Date:** 2026-10-01

## Context

The design brief describes a layered platform with an API gateway over separate
Identity, Mobility, Fare, Ticket, Payment, Validation, Audit, and Notification
services, plus per-provider payment adapters (Telebirr, CBE Birr, banks).

That target architecture is sound, but it is a *destination*, not a starting
point. Splitting into network services on day one adds distributed-transaction
and partial-failure modes to a system whose correctness depends on transactional
integrity — specifically on the guarantee that a ticket and its confirming
payment commit atomically.

## Decision

Start as a **modular monolith**: a single deployable NestJS application
organised into modules with:

- explicit boundaries — one module owns each table set;
- no cross-module table writes — modules communicate through exported services;
- all database access inside a single transaction where invariants demand it.

Modules are shaped so that extraction into a separate service later is a
deployment change, not a rewrite.

## Consequences

**Good**
- Ticket issuance and payment confirmation commit in one transaction, which is
  what makes invariant I1 (a ticket exists only against a confirmed payment)
  actually enforceable rather than merely hopeful.
- No network partitions between the fare engine and the ticket writer.
- One deployment, one migration history, trivial local development.

**Accepted costs**
- A single scaling unit. The fleet-GPS write path is already carved out into a
  separate time-series store precisely so this does not become a problem.
- Shared database. Module boundaries are enforced by convention and review, not
  by infrastructure, so discipline matters.

## Revisit when

Any of these become true: a module needs independent scaling; a module needs a
different release cadence; a team boundary requires hard isolation; or the
deployment target becomes genuinely distributed.
