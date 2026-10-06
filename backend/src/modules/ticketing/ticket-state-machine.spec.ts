import {
  allowedTransitions,
  assertIssuable,
  assertTransition,
  canTransition,
  checkTransition,
  HAPPY_PATH,
  IllegalTicketTransitionError,
  isTerminal,
  isUsable,
  TicketStatus,
} from './ticket-state-machine';

const ALL_STATES: TicketStatus[] = [
  'CREATED', 'FARE_QUOTED', 'PAYMENT_PENDING', 'PAYMENT_AUTHORIZED',
  'PAYMENT_CONFIRMED', 'TICKET_ISSUED', 'VALID', 'VALIDATED', 'COMPLETED',
  'PAYMENT_FAILED', 'PAYMENT_TIMEOUT', 'PAYMENT_REVERSED', 'REFUNDED',
  'EXPIRED', 'CANCELLED', 'VOIDED',
];

describe('ticket state machine', () => {
  describe('happy path', () => {
    it('permits every step of the normal journey', () => {
      for (let i = 0; i < HAPPY_PATH.length - 1; i += 1) {
        expect(canTransition(HAPPY_PATH[i], HAPPY_PATH[i + 1])).toBe(true);
      }
    });

    it('reaches COMPLETED through the full chain', () => {
      let status: TicketStatus = 'CREATED';
      for (let i = 1; i < HAPPY_PATH.length; i += 1) {
        assertTransition(status, HAPPY_PATH[i]);
        status = HAPPY_PATH[i];
      }
      expect(status).toBe('COMPLETED');
      expect(isTerminal(status)).toBe(true);
    });
  });

  describe('I1 — issuance requires a confirmed payment', () => {
    it('allows issuance only from PAYMENT_CONFIRMED', () => {
      expect(allowedTransitions('PAYMENT_CONFIRMED')).toContain('TICKET_ISSUED');

      // No other state may reach TICKET_ISSUED. This absence is the invariant.
      for (const state of ALL_STATES) {
        if (state === 'PAYMENT_CONFIRMED') continue;
        expect(canTransition(state, 'TICKET_ISSUED')).toBe(false);
      }
    });

    it('rejects issuance when the payment is not CONFIRMED', () => {
      const notConfirmed = [
        'CREATED', 'PENDING', 'REQUIRES_ACTION', 'AUTHORIZED',
        'FAILED', 'TIMEOUT', 'REVERSED', 'REFUNDED',
      ];
      for (const status of notConfirmed) {
        expect(() => assertIssuable('PAYMENT_CONFIRMED', status)).toThrow(
          IllegalTicketTransitionError,
        );
      }
    });

    it('accepts issuance when the payment is CONFIRMED', () => {
      expect(() => assertIssuable('PAYMENT_CONFIRMED', 'CONFIRMED')).not.toThrow();
    });

    it('rejects the redirect false positive explicitly', () => {
      // The exact bug the blueprint warns about: a client returning from a
      // payment screen being treated as proof of payment.
      expect(() => assertIssuable('PAYMENT_PENDING', 'REQUIRES_ACTION')).toThrow(
        /I1 violation/,
      );
    });

    it('rejects issuance when the ticket is in the wrong state', () => {
      expect(() => assertIssuable('FARE_QUOTED', 'CONFIRMED')).toThrow(
        /Illegal ticket transition/,
      );
    });
  });

  describe('illegal transitions', () => {
    it('refuses to skip payment entirely', () => {
      expect(canTransition('CREATED', 'TICKET_ISSUED')).toBe(false);
      expect(canTransition('FARE_QUOTED', 'VALID')).toBe(false);
      expect(canTransition('PAYMENT_PENDING', 'VALID')).toBe(false);
    });

    it('refuses to resurrect a failed payment', () => {
      expect(canTransition('PAYMENT_FAILED', 'PAYMENT_PENDING')).toBe(false);
      expect(canTransition('PAYMENT_TIMEOUT', 'PAYMENT_AUTHORIZED')).toBe(false);
      expect(canTransition('PAYMENT_REVERSED', 'PAYMENT_CONFIRMED')).toBe(false);
    });

    it('refuses to resurrect a terminal ticket', () => {
      expect(canTransition('CANCELLED', 'VALID')).toBe(false);
      expect(canTransition('EXPIRED', 'TICKET_ISSUED')).toBe(false);
      expect(canTransition('REFUNDED', 'VALID')).toBe(false);
      expect(canTransition('VOIDED', 'VALID')).toBe(false);
    });

    it('throws with a precise reason', () => {
      const result = checkTransition('CREATED', 'VALID');
      expect(result.allowed).toBe(false);
      expect(result.reason).toMatch(/Illegal ticket transition CREATED -> VALID/);
      expect(() => assertTransition('CREATED', 'VALID')).toThrow(
        IllegalTicketTransitionError,
      );
    });

    it('reports terminal states distinctly', () => {
      const result = checkTransition('CANCELLED', 'VALID');
      expect(result.reason).toMatch(/terminal state CANCELLED/);
    });
  });

  describe('failure paths', () => {
    it('allows reversal of a settled payment before issuance', () => {
      // A charge that settles then reverses must not yield a ticket.
      expect(canTransition('PAYMENT_CONFIRMED', 'PAYMENT_REVERSED')).toBe(true);
      expect(canTransition('PAYMENT_REVERSED', 'TICKET_ISSUED')).toBe(false);
    });

    it('allows a confirmed payment to be refunded instead of issued', () => {
      expect(canTransition('PAYMENT_CONFIRMED', 'REFUNDED')).toBe(true);
      expect(canTransition('REFUNDED', 'TICKET_ISSUED')).toBe(false);
    });

    it('allows a payment hold to be released after authorisation', () => {
      expect(canTransition('PAYMENT_AUTHORIZED', 'PAYMENT_REVERSED')).toBe(true);
    });

    it('lets an unused quote expire', () => {
      expect(canTransition('FARE_QUOTED', 'EXPIRED')).toBe(true);
    });

    it('allows refund of an already-used ticket', () => {
      expect(canTransition('VALID', 'REFUNDED')).toBe(true);
      expect(canTransition('VALIDATED', 'REFUNDED')).toBe(true);
    });
  });

  describe('usability', () => {
    const now = new Date('2026-01-15T12:00:00Z');

    it('is usable when VALID and unexpired', () => {
      expect(isUsable('VALID', new Date('2026-01-15T13:00:00Z'), now)).toBe(true);
    });

    it('is not usable once expired', () => {
      expect(isUsable('VALID', new Date('2026-01-15T11:00:00Z'), now)).toBe(false);
    });

    it('is not usable before validation', () => {
      expect(isUsable('TICKET_ISSUED', new Date('2026-01-15T13:00:00Z'), now)).toBe(false);
    });

    it('is not usable once validated', () => {
      expect(isUsable('VALIDATED', new Date('2026-01-15T13:00:00Z'), now)).toBe(false);
    });
  });

  describe('exhaustiveness', () => {
    it('every state is either terminal or has at least one successor', () => {
      for (const state of ALL_STATES) {
        if (isTerminal(state)) continue;
        expect(allowedTransitions(state).length).toBeGreaterThan(0);
      }
    });

    it('terminal states have no successors', () => {
      for (const state of ALL_STATES) {
        if (!isTerminal(state)) continue;
        expect(allowedTransitions(state)).toHaveLength(0);
      }
    });

    it('no state transitions to itself', () => {
      for (const state of ALL_STATES) {
        expect(canTransition(state, state)).toBe(false);
      }
    });
  });
});
