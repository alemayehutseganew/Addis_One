/**
 * Ticket lifecycle state machine — the enforcement point for I1.
 *
 * I1 states: a ticket exists only against a confirmed payment. That guarantee
 * rests entirely on this file, so the rules are stated explicitly rather than
 * being implied by whichever service happens to write the status column.
 *
 * Two properties matter:
 *
 *  1. Issuance is reachable ONLY from PAYMENT_CONFIRMED. There is deliberately
 *     no transition into TICKET_ISSUED from any other state. This is what stops
 *     the classic bug where the client returning from a payment redirect is
 *     treated as proof of payment.
 *
 *  2. Transitions are total and non-throwing. `canTransition` answers the
 *     question, `assertTransition` raises with a precise reason. Services call
 *     assert; the UI can call `canTransition` to enable or disable an action.
 *
 * Pure domain logic: no Prisma, no Nest. Unit tested in isolation.
 */

/** Mirrors the `TicketStatus` enum in the Prisma schema. */
export type TicketStatus =
  | 'CREATED'
  | 'FARE_QUOTED'
  | 'PAYMENT_PENDING'
  | 'PAYMENT_AUTHORIZED'
  | 'PAYMENT_CONFIRMED'
  | 'TICKET_ISSUED'
  | 'VALID'
  | 'VALIDATED'
  | 'COMPLETED'
  | 'PAYMENT_FAILED'
  | 'PAYMENT_TIMEOUT'
  | 'PAYMENT_REVERSED'
  | 'REFUNDED'
  | 'EXPIRED'
  | 'CANCELLED'
  | 'VOIDED';

/** Statuses from which no further transition is possible. */
export const TERMINAL_STATUSES: readonly TicketStatus[] = [
  'COMPLETED',
  'PAYMENT_FAILED',
  'PAYMENT_TIMEOUT',
  'PAYMENT_REVERSED',
  'REFUNDED',
  'EXPIRED',
  'CANCELLED',
  'VOIDED',
] as const;

/**
 * The happy path, in order:
 *   quote -> pay -> authorize -> confirm -> issue -> board -> ride -> finish
 */
export const HAPPY_PATH: readonly TicketStatus[] = [
  'CREATED',
  'FARE_QUOTED',
  'PAYMENT_PENDING',
  'PAYMENT_AUTHORIZED',
  'PAYMENT_CONFIRMED',
  'TICKET_ISSUED',
  'VALID',
  'VALIDATED',
  'COMPLETED',
] as const;

/**
 * Allowed transitions.
 *
 * Note what is absent: there is no edge into TICKET_ISSUED other than from
 * PAYMENT_CONFIRMED. That absence is the implementation of I1.
 */
const TRANSITIONS: Readonly<Record<TicketStatus, readonly TicketStatus[]>> = {
  CREATED: ['FARE_QUOTED', 'CANCELLED'],

  FARE_QUOTED: [
    'PAYMENT_PENDING',
    // A quote can lapse before anyone pays.
    'EXPIRED',
    'CANCELLED',
  ],

  PAYMENT_PENDING: [
    'PAYMENT_AUTHORIZED',
    // Some providers confirm without a separate authorize step.
    'PAYMENT_CONFIRMED',
    'PAYMENT_FAILED',
    'PAYMENT_TIMEOUT',
    'CANCELLED',
  ],

  PAYMENT_AUTHORIZED: [
    'PAYMENT_CONFIRMED',
    'PAYMENT_FAILED',
    'PAYMENT_TIMEOUT',
    // If capture fails after authorization, the hold must be released.
    'PAYMENT_REVERSED',
    'CANCELLED',
  ],

  PAYMENT_CONFIRMED: ['TICKET_ISSUED', 'PAYMENT_REVERSED', 'REFUNDED', 'CANCELLED'],

  TICKET_ISSUED: ['VALID', 'EXPIRED', 'CANCELLED', 'VOIDED'],

  VALID: ['VALIDATED', 'EXPIRED', 'CANCELLED', 'REFUNDED'],

  VALIDATED: ['COMPLETED', 'REFUNDED'],

  // Terminal states have no outgoing edges. A failed or reversed payment never
  // resurrects — it must be resolved by a NEW payment, not by walking backwards.
  COMPLETED: [],
  PAYMENT_FAILED: [],
  PAYMENT_TIMEOUT: [],
  PAYMENT_REVERSED: [],
  REFUNDED: [],
  EXPIRED: [],
  CANCELLED: [],
  VOIDED: [],
};

export interface TransitionCheck {
  allowed: boolean;
  reason?: string;
}

export function canTransition(from: TicketStatus, to: TicketStatus): boolean {
  return TRANSITIONS[from]?.includes(to) ?? false;
}

/** Explains the decision, for audit records and API error messages. */
export function checkTransition(from: TicketStatus, to: TicketStatus): TransitionCheck {
  if (isTerminal(from)) {
    return {
      allowed: false,
      reason: `Ticket is in terminal state ${from}; no further transitions are permitted`,
    };
  }
  if (!canTransition(from, to)) {
    return {
      allowed: false,
      reason: `Illegal ticket transition ${from} -> ${to}`,
    };
  }
  return { allowed: true };
}

export class IllegalTicketTransitionError extends Error {
  constructor(
    readonly from: TicketStatus,
    readonly to: TicketStatus,
    reason: string,
  ) {
    super(reason);
    this.name = 'IllegalTicketTransitionError';
  }
}

export function assertTransition(from: TicketStatus, to: TicketStatus): void {
  const result = checkTransition(from, to);
  if (!result.allowed) {
    throw new IllegalTicketTransitionError(from, to, result.reason);
  }
}

export function isTerminal(status: TicketStatus): boolean {
  return TERMINAL_STATUSES.includes(status);
}

export function allowedTransitions(from: TicketStatus): readonly TicketStatus[] {
  return TRANSITIONS[from] ?? [];
}

/**
 * The I1 gate. Callers must pass the payment status they observed; this is the
 * only supported path to issuance.
 *
 * A ticket may only be issued when the payment is CONFIRMED. Anything else —
 * including a provider returning "success" to the client, or a user appearing
 * back in the app — must not reach this function.
 */
export function assertIssuable(
  ticketStatus: TicketStatus,
  paymentStatus: string,
): void {
  if (paymentStatus !== 'CONFIRMED') {
    throw new IllegalTicketTransitionError(
      ticketStatus,
      'TICKET_ISSUED',
      `I1 violation: ticket issuance requires a CONFIRMED payment, got ${paymentStatus}`,
    );
  }
  assertTransition(ticketStatus, 'TICKET_ISSUED');
}

/**
 * True when a ticket is usable by a passenger right now.
 *
 * Used by the passenger app to decide between showing the QR and offering a
 * refund. Deliberately conservative: an unexpired credential on a VALID ticket.
 */
export function isUsable(status: TicketStatus, expiresAt: Date, now: Date): boolean {
  return status === 'VALID' && expiresAt.getTime() > now.getTime();
}
