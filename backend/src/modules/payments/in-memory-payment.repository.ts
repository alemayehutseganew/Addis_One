/**
 * In-memory PaymentRepository used by the orchestrator tests.
 *
 * It models the unique index on `idempotencyKey` that the real database
 * enforces, by rejecting a duplicate create the same way Postgres would. That
 * makes these tests meaningful: without the constraint, `createPayment` would
 * happily produce two payments for one key and a passenger would be charged
 * twice.
 */

import {
  NewPaymentRecord,
  PaymentRecord,
  PaymentRepository,
} from './payment-orchestrator';
import { PaymentStatusCode } from './payment-provider';

export class DuplicateKeyError extends Error {
  constructor(key: string) {
    super(`Unique constraint violated on idempotencyKey=${key}`);
    this.name = 'DuplicateKeyError';
  }
}

export class InMemoryPaymentRepository implements PaymentRepository {
  private readonly byId = new Map<string, PaymentRecord>();
  private readonly byKey = new Map<string, string>();
  private seq = 0;

  createCount = 0;
  updateCount = 0;

  async findByIdempotencyKey(key: string): Promise<PaymentRecord | null> {
    const id = this.byKey.get(key);
    return id ? this.byId.get(id) ?? null : null;
  }

  async findById(id: string): Promise<PaymentRecord | null> {
    return this.byId.get(id) ?? null;
  }

  async create(input: NewPaymentRecord): Promise<PaymentRecord> {
    // Mirrors `Payment_idempotencyKey_key` UNIQUE index.
    if (this.byKey.has(input.idempotencyKey)) {
      throw new DuplicateKeyError(input.idempotencyKey);
    }
    this.createCount += 1;
    const record: PaymentRecord = {
      id: `pay-${++this.seq}`,
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
    };
    this.byId.set(record.id, record);
    this.byKey.set(record.idempotencyKey, record.id);
    return record;
  }

  async updateStatus(
    id: string,
    status: PaymentStatusCode,
    extra?: Partial<PaymentRecord>,
  ): Promise<PaymentRecord> {
    const current = this.byId.get(id);
    if (!current) throw new Error(`Payment ${id} not found`);
    this.updateCount += 1;
    const next: PaymentRecord = {
      ...current,
      ...extra,
      status,
      providerReference: extra?.providerReference ?? current.providerReference,
    };
    this.byId.set(id, next);
    return next;
  }

  /** Test helper: how many payments exist in total. */
  get size(): number {
    return this.byId.size;
  }

  all(): PaymentRecord[] {
    return [...this.byId.values()];
  }
}

/**
 * Deterministic reference factory so assertions can rely on stable ids.
 */
export function fixedReferenceFactory(): () => string {
  let n = 0;
  return () => `REF-${++n}`;
}
