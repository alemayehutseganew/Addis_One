/**
 * Purchase flow: quote → pay → (only if confirmed) issue.
 *
 * This is the only place the three subsystems meet. Its job is to be boring and
 * strict:
 *
 *  - Re-derive the fare server-side and refuse a mismatch (revenue protection).
 *  - Delegate payment mechanics to the orchestrator (I2).
 *  - Delegate issuance to TicketIssuanceService (I1) — this class never signs
 *    anything itself, so there is no shortcut around the I1 gate.
 */

import { Injectable, HttpException, Logger } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { PaymentOrchestratorService, PaymentRecord } from './payment-orchestrator';
import { TicketIssuanceService } from '../ticketing/ticket-issuance.service';
import { PaymentMethodCode } from './payment-provider';
import { isUsable, TicketStatus } from '../ticketing/ticket-state-machine';

export interface PurchaseInput {
  userId: string;
  journeyId: string;
  claimedAmountFils: number;
  method: PaymentMethodCode;
  idempotencyKey: string;
  payerPhone?: string;

  /**
   * Cash/agent sale attribution.
   *
   * The orchestrator and the Payment model have carried these two fields since
   * the schema was written, but nothing ever populated them, so every payment in
   * the database recorded cash with no holder and no shift. Forwarding them here
   * is what lets a ticket officer's takings reconcile against the drawer.
   *
   * Never accepted from the passenger route — only the staff sales route sets
   * these, from the authenticated officer's own identity. A client that could
   * nominate its own collector could attribute revenue to another officer.
   */
  collectedByStaffId?: string;
  shiftId?: string;

  /** Vehicle-code purchase: the vehicle to buy tickets for. */
  vehicleId?: string;

  /** Vehicle-code purchase: optional trip context. */
  tripId?: string;

  /** Vehicle-code purchase: how many tickets to issue (one per passenger). */
  quantity?: number;
}

export interface PurchaseResult {
  paymentId: string;
  paymentReference: string;
  status: string;
  amountFils: number;
  currency: string;
  idempotentReplay: boolean;
  /**
   * The shift this payment actually belongs to, or null for a self-service
   * purchase. Reported so a caller never has to guess: on an idempotent replay the
   * payment is the ORIGINAL one and may sit against an earlier shift, in which
   * case the shift that is currently open is not the one holding the money.
   */
  shiftId: string | null;
  /**
   * Present only when the provider confirmed AND a ticket was issued. A caller
   * that sees `ticket: null` with `status: "CONFIRMED"` must poll
   * `/payments/:id/ticket` rather than assume success.
   */
  ticket: {
    ticketId: string;
    reference: string;
    /**
     * The ticket's lifecycle status.
     *
     * Present so the passenger app can tell whether the ticket it just bought is
     * boardable without a second round trip. It was omitted here, and the app's
     * `TicketStatus.fromWire` falls back to `CREATED` for an absent value — so a
     * freshly purchased ticket read as not boardable until the app happened to
     * re-fetch `/tickets/mine`.
     *
     * Deliberately not an `isBoardable` boolean as well. The client already
     * derives that from status, the QR and the expiry, and a second server
     * answer to the same question is one more thing that can disagree.
     */
    status: TicketStatus;
    qrString: string;
    issuedAt: string;
    expiresAt: string;
    fareRuleVersion: number | null;
  } | null;
  /**
   * Vehicle-code payments: multiple tickets (one per passenger).
   * Present when `quantity > 1` or when the payment was a vehicle payment.
   * A caller that sees `tickets: []` with `status: "CONFIRMED"` must poll
   * `/vehicle-payments/:id/tickets` rather than assume success.
   */
  tickets: {
    ticketId: string;
    reference: string;
    status: TicketStatus;
    qrString: string;
    issuedAt: string;
    expiresAt: string;
    fareRuleVersion: number | null;
  }[] | null;
  /**
   * Always "MOCK" while the provider adapter is the development stub, so no test
   * deployment can be mistaken for a live payment system.
   */
  providerMode: 'MOCK';
}

@Injectable()
export class PaymentsService {
  private readonly log = new Logger(PaymentsService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly orchestrator: PaymentOrchestratorService,
    private readonly issuance: TicketIssuanceService,
  ) {}

  async purchase(input: PurchaseInput): Promise<PurchaseResult> {
    const journey = await this.prisma.journey.findFirst({
      where: { id: input.journeyId, userId: input.userId },
    });
    if (!journey) throw new HttpException('Journey not found', 404);

    // ── Re-derive the fare ───────────────────────────────────────────────
    // The client's amount is a claim. Trusting it would let anyone buy a
    // 44-birr ticket for 1 fil, which the provider would accept happily.
    const calculation = await this.prisma.fareCalculation.findUnique({
      where: { journeyId: input.journeyId },
    });
    if (!calculation) {
      throw new HttpException('No fare quote for this journey', 409);
    }

    if (calculation.totalFareFils !== input.claimedAmountFils) {
      // Deliberately does not echo the authoritative price back: the client gets
      // it by replanning. Silently "correcting" it would hide tampering from logs.
      this.log.warn(
        `Fare mismatch for user ${input.userId}: claimed ${input.claimedAmountFils}, ` +
          `server ${calculation.totalFareFils}`,
      );
      throw new HttpException(
        { message: 'Fare no longer matches the quoted price', code: 'FARE_MISMATCH' },
        409,
      );
    }


    // ── Pay ──────────────────────────────────────────────────────────────
    const created = await this.orchestrator.createPayment({
      userId: input.userId,
      amountFils: calculation.totalFareFils,
      currency: calculation.currency ?? 'ETB',
      method: input.method,
      idempotencyKey: input.idempotencyKey,
      fareCalculationId: calculation.id,
      payerPhone: input.payerPhone,
      description: 'Addis One ticket',
      // Cash attribution. Null for a passenger self-service purchase, which is
      // exactly right: nobody was physically holding that money. Only the staff
      // sales route ever sets these, and it takes them from the authenticated
      // officer rather than from the request body.
      collectedByStaffId: input.collectedByStaffId ?? null,
      shiftId: input.shiftId ?? null,
    });

    let payment = created.payment;

    // A confirmed payment is terminal, so a replay has nothing left to do.
    if (payment.status === 'CONFIRMED') {
      return this.withTicket(payment, true);
    }

    const initiated = await this.orchestrator.initiate(
      payment.id,
      input.idempotencyKey,
      { payerPhone: input.payerPhone ?? '', description: 'Addis One ticket' },
    );
    payment = initiated.payment;

    // Only a confirmed payment unlocks issuance. REQUIRES_ACTION means the payer
    // was SENT to the provider, not that they paid — exactly the confusion I1
    // exists to prevent, so no ticket is returned in that case.
    if (payment.status === 'CONFIRMED') {
      return this.withTicket(payment, created.idempotentReplay);
    }

    return {
      paymentId: payment.id,
      paymentReference: payment.reference,
      status: payment.status,
      amountFils: payment.amountFils,
      currency: payment.currency,
      idempotentReplay: created.idempotentReplay,
      shiftId: payment.shiftId ?? null,
      ticket: null,
      tickets: null,
      providerMode: 'MOCK',
    };
  }

  /**
   * Vehicle-code purchase flow: vehicle fare → pay → (only if confirmed) issue multiple tickets.
   *
   * Mirrors the journey purchase but validates against a vehicle profile instead of a
   * planned journey. Issues one ticket per passenger (quantity).
   */
  async purchaseVehicle(input: PurchaseInput): Promise<PurchaseResult> {
    if (!input.vehicleId) {
      throw new HttpException('Vehicle ID is required for vehicle payment', 400);
    }

    const vehicle = await this.prisma.vehicle.findUnique({
      where: { id: input.vehicleId },
      select: { id: true, code: true, fareFils: true, operator: { select: { id: true } } },
    });
    if (!vehicle) throw new HttpException('Vehicle not found', 404);

    const quantity = input.quantity ?? 1;
    if (!vehicle.fareFils || vehicle.fareFils <= 0) {
      throw new HttpException('No fare published for this vehicle', 409);
    }

    const expectedTotalFils = vehicle.fareFils * quantity;
    if (expectedTotalFils !== input.claimedAmountFils) {
      this.log.warn(
        `Fare mismatch for vehicle ${input.vehicleId}: claimed ${input.claimedAmountFils}, ` +
          `server ${expectedTotalFils}`,
      );
      throw new HttpException(
        { message: 'Amount does not match vehicle fare × quantity', code: 'FARE_MISMATCH' },
        409,
      );
    }

    // Create payment with vehicle context
    const created = await this.orchestrator.createPayment({
      userId: input.userId,
      amountFils: expectedTotalFils,
      currency: 'ETB',
      method: input.method,
      idempotencyKey: input.idempotencyKey,
      fareCalculationId: null,
      vehicleId: input.vehicleId,
      tripId: input.tripId ?? null,
      quantity,
      payerPhone: input.payerPhone,
      description: `Vehicle ${vehicle.code} ticket × ${quantity}`,
      collectedByStaffId: input.collectedByStaffId ?? null,
      shiftId: input.shiftId ?? null,
    });

    let payment = created.payment;

    // A confirmed payment is terminal, so a replay has nothing left to do.
    if (payment.status === 'CONFIRMED') {
      return this.withVehicleTickets(payment, quantity, vehicle, true);
    }

    const initiated = await this.orchestrator.initiate(
      payment.id,
      input.idempotencyKey,
      { payerPhone: input.payerPhone ?? '', description: `Vehicle ${vehicle.code} ticket × ${quantity}` },
    );
    payment = initiated.payment;

    // Only a confirmed payment unlocks issuance.
    if (payment.status === 'CONFIRMED') {
      return this.withVehicleTickets(payment, quantity, vehicle, created.idempotentReplay);
    }

    return {
      paymentId: payment.id,
      paymentReference: payment.reference,
      status: payment.status,
      amountFils: payment.amountFils,
      currency: payment.currency,
      idempotentReplay: created.idempotentReplay,
      shiftId: payment.shiftId ?? null,
      ticket: null,
      tickets: null,
      providerMode: 'MOCK',
    };
  }

  /**
   * Returns the tickets for a vehicle payment if they have been issued.
   *
   * 409 while the payment is unconfirmed — the client's poll loop depends on
   * that being distinguishable from "issued but expired".
   */
  async ticketsForVehiclePayment(paymentId: string, userId: string) {
    const payment = await this.prisma.payment.findUnique({ where: { id: paymentId } });
    if (!payment || payment.userId !== userId) {
      throw new HttpException('Payment not found', 404);
    }
    if (payment.status !== 'CONFIRMED') {
      throw new HttpException('Payment is not confirmed', 409);
    }

    const tickets = await this.prisma.ticket.findMany({
      where: { paymentId },
      include: { credential: true },
    });
    if (tickets.length === 0) throw new HttpException('Tickets not issued yet', 404);

    return {
      tickets: tickets.map((t) => ({
        ticketId: t.id,
        reference: t.reference,
        status: t.status,
        qrString: t.credential ? this.issuance.buildQrString(t.credential) : null,
        issuedAt: t.issuedAt,
        expiresAt: t.credential?.expiresAt ?? t.expiresAt,
        fareRuleVersion: t.fareRuleVersion,
        usable: isUsable(
          t.status as never,
          t.credential?.expiresAt ?? t.expiresAt,
          new Date(),
        ),
      })),
    };
  }

  /**
   * Issues multiple tickets for a confirmed vehicle payment.
   */
  private async withVehicleTickets(
    payment: PaymentRecord,
    quantity: number,
    vehicle: { id: string; code: string; operator: { id: string } },
    replay: boolean,
  ): Promise<PurchaseResult> {
    const issuedTickets = [];
    for (let i = 0; i < quantity; i++) {
      const issued = await this.issuance.issueForPayment({
        paymentId: payment.id,
        userId: payment.userId,
        fareCalculationId: null,
        journeyId: payment.tripId ?? null,
        mode: 'BUS',
        validForMinutes: 120,
        vehicleId: vehicle.id,
        operatorId: vehicle.operator.id,
      });
      issuedTickets.push({
        ticketId: issued.ticketId,
        reference: issued.ticketReference,
        status: issued.status,
        qrString: issued.qrString,
        issuedAt: issued.issuedAt.toISOString(),
        expiresAt: issued.expiresAt.toISOString(),
        fareRuleVersion: issued.fareRuleVersion,
      });
    }

    return {
      paymentId: payment.id,
      paymentReference: payment.reference,
      status: payment.status,
      amountFils: payment.amountFils,
      currency: payment.currency,
      idempotentReplay: replay,
      shiftId: payment.shiftId ?? null,
      ticket: issuedTickets[0] ?? null, // Backward compat: first ticket
      tickets: issuedTickets,
      providerMode: 'MOCK',
    };
  }

  /**
   * Returns the ticket for a payment if one has been issued.
   *
   * 409 while the payment is unconfirmed — the client's poll loop depends on
   * that being distinguishable from "issued but expired".
   */
  async ticketForPayment(paymentId: string, userId: string) {
    const payment = await this.prisma.payment.findUnique({ where: { id: paymentId } });
    if (!payment || payment.userId !== userId) {
      throw new HttpException('Payment not found', 404);
    }
    if (payment.status !== 'CONFIRMED') {
      throw new HttpException('Payment is not confirmed', 409);
    }

    const ticket = await this.prisma.ticket.findUnique({
      where: { paymentId },
      include: { credential: true },
    });
    if (!ticket?.credential) throw new HttpException('Ticket not issued yet', 404);

    return {
      ticketId: ticket.id,
      reference: ticket.reference,
      status: ticket.status,
      // Reuses the issuance service's serialiser so this endpoint and
      // /tickets/mine cannot drift apart on the QR field order.
      qrString: this.issuance.buildQrString(ticket.credential),
      issuedAt: ticket.issuedAt,
      expiresAt: ticket.credential.expiresAt,
      fareRuleVersion: ticket.fareRuleVersion,
      usable: isUsable(
        ticket.status as never,
        ticket.credential.expiresAt,
        new Date(),
      ),
    };
  }

  /**
   * Issues (or re-reads) the ticket for a confirmed payment.
   *
   * Takes `PaymentRecord` rather than an inline structural copy. A hand-written
   * duplicate of this shape drifted out of date the moment cash attribution added
   * `shiftId`: the DB, the orchestrator and the repository all carried the field,
   * but this copy did not, so reading `payment.shiftId` here stopped compiling
   * while the surrounding accessors were inferred correctly. Referencing the one
   * canonical type keeps the next added field from repeating the same breakage.
   */
  private async withTicket(
    payment: PaymentRecord,
    replay: boolean,
  ): Promise<PurchaseResult> {
    let journeyId: string | null = null;
    if (payment.fareCalculationId) {
      const calc = await this.prisma.fareCalculation.findUnique({
        where: { id: payment.fareCalculationId },
        select: { journeyId: true },
      });
      journeyId = calc?.journeyId ?? null;
    }

    const issued = await this.issuance.issueForPayment({
      paymentId: payment.id,
      userId: payment.userId,
      fareCalculationId: payment.fareCalculationId,
      journeyId,
      mode: 'BUS',
      validForMinutes: 120,
    });

    return {
      paymentId: payment.id,
      paymentReference: payment.reference,
      status: payment.status,
      amountFils: payment.amountFils,
      currency: payment.currency,
      idempotentReplay: replay,
      shiftId: payment.shiftId ?? null,
      ticket: {
        ticketId: issued.ticketId,
        reference: issued.ticketReference,
        status: issued.status,
        qrString: issued.qrString,
        issuedAt: issued.issuedAt.toISOString(),
        expiresAt: issued.expiresAt.toISOString(),
        fareRuleVersion: issued.fareRuleVersion,
      },
      tickets: null,
      providerMode: 'MOCK',
    };
  }
}
