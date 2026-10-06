/**
 * Ticket issuance — implements architecture.md I1 and I3.
 *
 * I1 (no ticket without payment) is enforced structurally, not by convention.
 * Three independent barriers, any one of which is sufficient:
 *
 *   1. `assertIssuable` refuses any payment status that is not CONFIRMED.
 *   2. The ticket and its signed credential are written in the SAME transaction
 *      as the payment status change, so there is no committed state in which a
 *      payment is confirmed but no ticket exists, or a ticket exists without a
 *      confirmed payment.
 *   3. `Ticket.paymentId` is unique, so a second attempt to issue for the same
 *      payment fails at the database rather than minting a duplicate.
 *
 * I3 (fare version stays auditable): the fare rule version used is copied onto
 * the ticket row, so when the bureau changes fares next year a ticket issued
 * today still points at the rule that was in force today.
 *
 * The credential payload deliberately carries no fare, user, or route data — see
 * credential-signer.ts. A photographed QR reveals nothing about the passenger.
 */

import { Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';
import { CredentialSigner } from './credential-signer';
import { assertIssuable, TicketStatus } from './ticket-state-machine';

export interface IssueTicketInput {
  paymentId: string;
  /** Owner of the ticket — the `User` the auth guard resolved. */
  userId: string;
  /** From the FareCalculation written at quote time. Null only for cash sales. */
  fareCalculationId: string | null;
  journeyId: string | null;
  /** Mirrors the Prisma `TransportMode` enum — no extra members. */
  mode: 'BUS' | 'TAXI' | 'TRAIN';
  /**
   * How long the QR stays valid. A single-trip ticket is only useful shortly
   * after boarding, so a short window limits the value of a stolen screenshot.
   */
  validForMinutes: number;

  /** Vehicle-code issuance: the vehicle this ticket is for. */
  vehicleId?: string | null;

  /** Vehicle-code issuance: the operator this vehicle belongs to. */
  operatorId?: string | null;
}

export interface IssuedTicket {
  ticketId: string;
  ticketReference: string;
  status: TicketStatus;
  qrString: string;
  issuedAt: Date;
  expiresAt: Date;
  /** I3: the rule version this ticket was priced against. */
  fareRuleVersion: number | null;
}

@Injectable()
export class TicketIssuanceService {
  private readonly log = new Logger(TicketIssuanceService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly signer: CredentialSigner,
  ) {}

  /**
   * Issues a ticket for a CONFIRMED payment.
   *
   * Idempotent per payment: if a ticket already exists it is returned unchanged
   * rather than a second ticket being minted. A passenger who taps "Pay" twice,
   * or whose request is retried after a dropped response, must end up with one.
   */
  async issueForPayment(input: IssueTicketInput): Promise<IssuedTicket> {
    const payment = await this.prisma.payment.findUnique({
      where: { id: input.paymentId },
    });
    if (!payment) throw new Error(`Payment ${input.paymentId} not found`);

    const existing = await this.loadExisting(input.paymentId);
    if (existing) return existing;

    // Barrier 1 — refuse anything that is not a settled payment.
    assertIssuable('PAYMENT_CONFIRMED', payment.status);

    const issuedAt = new Date();
    const expiresAt = new Date(issuedAt.getTime() + input.validForMinutes * 60_000);
    const ticketId = randomUUID();
    const credentialId = randomUUID();

    // I3: snapshot which rule version priced this ticket, read from the
    // calculation the passenger agreed to. Copied onto the ticket so a future
    // fare change cannot rewrite history.
    const fareRuleVersion = input.fareCalculationId
      ? (await this.prisma.fareCalculation.findUnique({
          where: { id: input.fareCalculationId },
          select: { ruleVersion: true },
        }))?.ruleVersion ?? null
      : null;

    const signed = this.signer.sign({ ticketId, credentialId, issuedAt, expiresAt });

    // Barrier 2 — ticket and credential commit together or not at all.
    const created = await this.prisma.$transaction(async (tx) => {
      const ticket = await tx.ticket.create({
        data: {
          id: ticketId,
          reference:
            `TKT-${Date.now().toString(36).toUpperCase()}-` +
            ticketId.slice(0, 6).toUpperCase(),
          userId: input.userId,
          paymentId: input.paymentId,
          mode: input.mode,
          fareCalculationId: input.fareCalculationId,
          fareRuleVersion,
          journeyId: input.journeyId,
          vehicleId: input.vehicleId ?? null,
          // Landing on VALID, not TICKET_ISSUED.
          //
          // The machine's happy path is PAYMENT_CONFIRMED -> TICKET_ISSUED ->
          // VALID -> VALIDATED, and the scanner boards a ticket only from VALID
          // (`checkTransition(status, 'VALIDATED')`). This used to stop at
          // TICKET_ISSUED, and because *nothing anywhere performed the
          // TICKET_ISSUED -> VALID edge*, every ticket this service issued was
          // refused at the door with NOT_ISSUED: the passenger paid, received a
          // signed credential, and was turned away by the officer. The chain was
          // broken at its last step and nothing failed loudly enough to notice.
          //
          // Activation belongs here rather than at first scan because the
          // credential's own `expiresAt` is set a couple of lines below — a ticket
          // that is "not yet valid" while already inside the validity window it
          // was issued with is incoherent. Trip binding is still enforced at scan
          // time (WRONG_TRIP), so this does not loosen who may board what.
          //
          // TICKET_ISSUED stays in the machine: it remains the state a payment
          // moves through, and the state any row stranded in it — from an older
          // build, say — is still reported as NOT_ISSUED rather than waved in.
          status: 'VALID',
          issuedAt,
          expiresAt,
        },
      });

      await tx.qrCredential.create({
        data: {
          // The credential id doubles as the row's primary key. It is generated
          // here rather than defaulted so the value signed into the payload is
          // provably the same value stored — a server-defaulted id would risk the
          // two diverging, producing credentials that verify against nothing.
          id: credentialId,
          ticketId: ticket.id,
          keyId: this.signer.keyId,
          signature: signed.signature,
          nonce: signed.payload.nonce,
          issuedAt,
          expiresAt,
        },
      });

      return ticket;
    });

    this.log.log(
      `Issued ticket ${created.reference} for payment ${input.paymentId} ` +
        `(rule version ${fareRuleVersion ?? 'n/a'})`,
    );

    return {
      ticketId: created.id,
      ticketReference: created.reference,
      status: created.status as TicketStatus,
      qrString: signed.qrString,
      issuedAt,
      expiresAt,
      fareRuleVersion,
    };
  }

  /**
   * The QR wire string for a stored credential.
   *
   * Public because several endpoints return the same credential and the exact
   * field order is a contract, not an implementation detail — duplicating this
   * JSON literal in a controller is how the passenger app and the staff scanner
   * slowly drift apart.
   */
  buildQrString(credential: {
    ticketId: string;
    id: string;
    issuedAt: Date;
    expiresAt: Date;
    nonce: string;
    keyId: string;
    signature: string;
  }): string {
    return JSON.stringify({
      t: credential.ticketId,
      c: credential.id,
      i: Math.floor(credential.issuedAt.getTime() / 1000),
      e: Math.floor(credential.expiresAt.getTime() / 1000),
      n: credential.nonce,
      k: credential.keyId,
      s: credential.signature,
    });
  }

  /**
   * Returns an already-issued ticket, rebuilding the QR string from stored
   * columns rather than re-signing.
   *
   * Re-signing would produce a different nonce, so a passenger reopening the app
   * would invalidate the screenshot they already had — and on a validator that
   * tracks consumed nonces, could be mistaken for a replay.
   */
  private async loadExisting(paymentId: string): Promise<IssuedTicket | null> {
    const ticket = await this.prisma.ticket.findUnique({
      where: { paymentId },
      include: { credential: true },
    });
    if (!ticket?.credential) return null;

    return {
      ticketId: ticket.id,
      ticketReference: ticket.reference,
      status: ticket.status as TicketStatus,
      qrString: this.buildQrString(ticket.credential),
      issuedAt: ticket.credential.issuedAt,
      expiresAt: ticket.credential.expiresAt,
      fareRuleVersion: ticket.fareRuleVersion,
    };
  }
}
