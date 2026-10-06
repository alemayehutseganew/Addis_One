/**
 * Prisma-backed persistence for the payment orchestrator.
 *
 * The important behaviour is in `create`: it must let the database's unique
 * index on `idempotencyKey` do the work, and must NOT swallow the violation.
 * The orchestrator catches `P2002` and re-reads the winner, so returning the
 * raw Prisma error is what makes concurrent double-taps converge on one charge
 * instead of an error the passenger would see.
 *
 * Pre-check-then-insert would be wrong: it is not atomic, and under a genuine
 * race both requests pass the check.
 */

import { Injectable } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import {
  PaymentRecord,
  PaymentRepository,
  NewPaymentRecord,
  PaymentRecordStatus,
} from './payment-orchestrator';

@Injectable()
export class PrismaPaymentRepository implements PaymentRepository {
  constructor(private readonly prisma: PrismaService) {}

  private toRecord(row: {
    id: string;
    reference: string;
    userId: string;
    idempotencyKey: string;
    amountFils: number;
    currency: string;
    method: string;
    status: string;
    providerReference: string | null;
    fareCalculationId: string | null;
    vehicleId: string | null;
    tripId: string | null;
    quantity: number | null;
    collectedByStaffId: string | null;
    shiftId: string | null;
  }): PaymentRecord {
    return {
      id: row.id,
      reference: row.reference,
      userId: row.userId,
      idempotencyKey: row.idempotencyKey,
      amountFils: row.amountFils,
      currency: row.currency,
      method: row.method as PaymentRecord['method'],
      status: row.status as PaymentRecordStatus,
      providerReference: row.providerReference,
      fareCalculationId: row.fareCalculationId,
      vehicleId: row.vehicleId,
      tripId: row.tripId,
      quantity: row.quantity,
      collectedByStaffId: row.collectedByStaffId,
      shiftId: row.shiftId,
    };
  }

  async findByIdempotencyKey(key: string): Promise<PaymentRecord | null> {
    const row = await this.prisma.payment.findUnique({
      where: { idempotencyKey: key },
    });
    return row ? this.toRecord(row) : null;
  }

  async findById(id: string): Promise<PaymentRecord | null> {
    const row = await this.prisma.payment.findUnique({ where: { id } });
    return row ? this.toRecord(row) : null;
  }

  /**
   * Inserts without catching unique violations.
   *
   * `reference` is also unique, so a collision there is a genuine defect in the
   * reference factory rather than a lost race. Both surface as P2002 and the
   * orchestrator distinguishes them by re-reading the key and finding nothing.
   */
  async create(input: NewPaymentRecord): Promise<PaymentRecord> {
    const row = await this.prisma.payment.create({
      data: {
        reference: input.reference,
        userId: input.userId,
        idempotencyKey: input.idempotencyKey,
        amountFils: input.amountFils,
        currency: input.currency,
        method: input.method,
        status: input.status,
        providerReference: input.providerReference ?? null,
        fareCalculationId: input.fareCalculationId ?? null,
        vehicleId: input.vehicleId ?? null,
        tripId: input.tripId ?? null,
        quantity: input.quantity ?? 1,
        collectedByStaffId: input.collectedByStaffId ?? null,
        shiftId: input.shiftId ?? null,
      },
    });
    return this.toRecord(row);
  }

  async updateStatus(
    id: string,
    status: PaymentRecordStatus,
    extra: Partial<PaymentRecord> = {},
  ): Promise<PaymentRecord> {
    const data: Record<string, unknown> = { status };

    if (extra.providerReference !== undefined) {
      data.providerReference = extra.providerReference;
    }
    // A confirmation timestamp is what settlement reports group by, so it is set
    // from the status change rather than trusting the caller to remember.
    if (status === 'CONFIRMED') {
      data.confirmedAt = new Date();
    } else if (status === 'FAILED' || status === 'TIMEOUT') {
      data.failedAt = new Date();
    }

    const row = await this.prisma.payment.update({ where: { id }, data });
    return this.toRecord(row);
  }
}
