import { ProviderRegistry } from './payment-provider';
import { PaymentOrchestratorService, isTerminalStatus } from './payment-orchestrator';
import {
  CashPaymentAdapter,
  MockPaymentAdapter,
  mockAdapterCalls,
  resetMockAdapterCalls,
} from './mock-payment-adapter';
import {
  DuplicateKeyError,
  InMemoryPaymentRepository,
  fixedReferenceFactory,
} from './in-memory-payment.repository';

type Behaviour = 'SUCCEED' | 'DECLINE' | 'TIMEOUT' | 'REQUIRE_ACTION';

function build(behaviour: Behaviour = 'SUCCEED') {
  const repo = new InMemoryPaymentRepository();
  const registry = new ProviderRegistry();
  registry.register(new MockPaymentAdapter('TELEBIRR', 'Mock Telebirr', { behaviour }));
  registry.register(new CashPaymentAdapter());
  const svc = new PaymentOrchestratorService(repo, registry, fixedReferenceFactory());
  return { repo, registry, svc };
}

const baseInput = {
  userId: 'user-1',
  amountFils: 2500,
  currency: 'ETB',
  method: 'TELEBIRR' as const,
  fareCalculationId: 'fc-1',
};

const payer = { payerPhone: '+251911000000', description: 'Bus ticket' };

describe('PaymentOrchestratorService', () => {
  beforeEach(() => resetMockAdapterCalls());

  describe('I2 — idempotency', () => {
    it('creates a payment on first call', async () => {
      const { svc, repo } = build();
      const res = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-abc-123' });
      expect(res.idempotentReplay).toBe(false);
      expect(res.payment.status).toBe('CREATED');
      expect(repo.size).toBe(1);
    });

    it('returns the original payment when the key is replayed', async () => {
      const { svc, repo } = build();
      const first = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-abc-123' });
      const second = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-abc-123' });
      expect(second.idempotentReplay).toBe(true);
      expect(second.payment.id).toBe(first.payment.id);
      expect(repo.size).toBe(1);
    });

    it('collapses concurrent retries into one payment', async () => {
      const { svc, repo } = build();
      const key = 'key-concurrent-1';
      const results = await Promise.all(
        Array.from({ length: 5 }, () =>
          svc.createPayment({ ...baseInput, idempotencyKey: key }),
        ),
      );
      expect(repo.size).toBe(1);
      expect(new Set(results.map((r) => r.payment.id)).size).toBe(1);
    });

    it('surfaces the database unique violation as DuplicateKeyError', async () => {
      // Proves the constraint exists independently of application logic.
      const { repo } = build();
      await repo.create({
        ...baseInput, reference: 'R1', status: 'CREATED', idempotencyKey: 'dup-1',
      });
      await expect(
        repo.create({
          ...baseInput, reference: 'R2', status: 'CREATED', idempotencyKey: 'dup-1',
        }),
      ).rejects.toBeInstanceOf(DuplicateKeyError);
    });

    it('rejects a weak idempotency key', async () => {
      const { svc } = build();
      await expect(
        svc.createPayment({ ...baseInput, idempotencyKey: 'abc' }),
      ).rejects.toThrow(/idempotencyKey/);
    });

    it('requires a positive integer amount', async () => {
      const { svc } = build();
      await expect(
        svc.createPayment({ ...baseInput, amountFils: 0, idempotencyKey: 'key-zero-1' }),
      ).rejects.toThrow(/positive integer/);
      await expect(
        svc.createPayment({ ...baseInput, amountFils: 10.5, idempotencyKey: 'key-frac-1' }),
      ).rejects.toThrow(/positive integer/);
    });
  });

  describe('I1 — no path to a ticket without a CONFIRMED payment', () => {
    it('exposes only payment state, never a ticket', async () => {
      const { svc } = build();
      const res = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-i1-001' });
      expect(Object.keys(res.payment)).not.toContain('ticket');
      expect(res.payment.status).toBe('CREATED');
    });

    it('REQUIRES_ACTION is not CONFIRMED and must not unlock issuance', async () => {
      const { svc } = build('REQUIRE_ACTION');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-i1-002' });
      const started = await svc.initiate(created.payment.id, 'idem-init-002', payer);
      expect(started.payment.status).toBe('REQUIRES_ACTION');
      // The redirect exists, but the payment is NOT confirmed. This is exactly
      // the state that must never be mistaken for a completed payment.
      expect(started.redirectUrl).toContain('mock.local');
      expect(started.payment.status).not.toBe('CONFIRMED');
    });

    it('a declined payment stays FAILED and never confirms', async () => {
      const { svc } = build('DECLINE');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-i1-003' });
      const started = await svc.initiate(created.payment.id, 'idem-init-003', payer);
      expect(started.payment.status).toBe('FAILED');
    });
  });

  describe('terminal states', () => {
    it('classifies settled and failed states as terminal', () => {
      expect(isTerminalStatus('CONFIRMED')).toBe(true);
      expect(isTerminalStatus('FAILED')).toBe(true);
      expect(isTerminalStatus('REFUNDED')).toBe(true);
      expect(isTerminalStatus('PENDING')).toBe(false);
      expect(isTerminalStatus('AUTHORIZED')).toBe(false);
    });

    it('does not re-initiate a terminal payment', async () => {
      const { svc } = build('DECLINE');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-term-01' });
      await svc.initiate(created.payment.id, 'idem-01', payer);
      const before = mockAdapterCalls.initiate;
      const again = await svc.initiate(created.payment.id, 'idem-01', payer);
      expect(again.payment.status).toBe('FAILED');
      expect(mockAdapterCalls.initiate).toBe(before);
    });
  });

  describe('confirm and refund', () => {
    it('capture confirms the payment', async () => {
      const { svc } = build();
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-cap-001' });
      const confirmed = await svc.capture(created.payment.id, 'idem-cap-001');
      expect(confirmed.status).toBe('CONFIRMED');
    });

    it('capture is idempotent once confirmed', async () => {
      const { svc } = build();
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-cap-002' });
      await svc.capture(created.payment.id, 'idem-cap-002');
      const before = mockAdapterCalls.capture;
      const again = await svc.capture(created.payment.id, 'idem-cap-002');
      expect(again.status).toBe('CONFIRMED');
      expect(mockAdapterCalls.capture).toBe(before);
    });

    it('refuses to refund a payment that was never confirmed', async () => {
      const { svc } = build('DECLINE');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-ref-001' });
      await svc.initiate(created.payment.id, 'idem-ref-001', payer);
      await expect(
        svc.refund(created.payment.id, 'idem-ref-002', 2500, 'test'),
      ).rejects.toThrow(/Cannot refund/);
    });

    it('refuses to refund more than was paid', async () => {
      const { svc } = build();
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-ref-002' });
      await svc.capture(created.payment.id, 'idem-ref-003');
      await expect(
        svc.refund(created.payment.id, 'idem-ref-004', 999999, 'too much'),
      ).rejects.toThrow(/Invalid refund amount/);
    });

    it('refunds a confirmed payment', async () => {
      const { svc } = build();
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-ref-005' });
      await svc.capture(created.payment.id, 'idem-ref-005');
      const refunded = await svc.refund(created.payment.id, 'idem-ref-006', 2500, 'service issue');
      expect(refunded.status).toBe('REFUNDED');
    });
  });

  describe('webhook reconciliation', () => {
    it('confirms a payment from a webhook', async () => {
      const { svc } = build('REQUIRE_ACTION');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-wh-001' });
      await svc.initiate(created.payment.id, 'idem-wh-001', payer);
      const updated = await svc.applyWebhookResult(created.payment.id, 'CONFIRMED');
      expect(updated.status).toBe('CONFIRMED');
    });

    it('ignores a stale webhook that would undo a settled payment', async () => {
      const { svc } = build();
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-wh-002' });
      await svc.capture(created.payment.id, 'idem-wh-002');
      const updated = await svc.applyWebhookResult(created.payment.id, 'FAILED');
      expect(updated.status).toBe('CONFIRMED');
    });

    it('ignores a duplicate webhook for an already-failed payment', async () => {
      const { svc } = build('DECLINE');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-wh-003' });
      await svc.initiate(created.payment.id, 'idem-wh-003', payer);
      const updated = await svc.applyWebhookResult(created.payment.id, 'CONFIRMED');
      expect(updated.status).toBe('FAILED');
    });

    it('ignores non-authoritative intermediate webhook states', async () => {
      const { svc } = build('REQUIRE_ACTION');
      const created = await svc.createPayment({ ...baseInput, idempotencyKey: 'key-wh-004' });
      await svc.initiate(created.payment.id, 'idem-wh-004', payer);
      const updated = await svc.applyWebhookResult(created.payment.id, 'PENDING');
      expect(updated.status).toBe('REQUIRES_ACTION');
    });
  });

  describe('cash and agent assisted sales', () => {
    it('settles cash synchronously through the same orchestrator', async () => {
      const { svc } = build();
      const created = await svc.createPayment({
        ...baseInput,
        method: 'CASH',
        idempotencyKey: 'key-cash-001',
        collectedByStaffId: 'staff-7',
        shiftId: 'shift-3',
      });
      const started = await svc.initiate(created.payment.id, 'idem-cash-001', payer);
      // Assisted sales must produce the same core records as self-service.
      expect(started.payment.status).toBe('CONFIRMED');
      expect(started.payment.collectedByStaffId).toBe('staff-7');
      expect(started.payment.shiftId).toBe('shift-3');
    });

    it('does not poll a cash payment', async () => {
      const { svc } = build();
      const created = await svc.createPayment({
        ...baseInput, method: 'CASH', idempotencyKey: 'key-cash-002',
      });
      await svc.initiate(created.payment.id, 'idem-cash-002', payer);
      const before = mockAdapterCalls.status;
      await svc.refreshStatus(created.payment.id);
      expect(mockAdapterCalls.status).toBe(before);
    });
  });

  describe('unknown providers', () => {
    it('fails loudly rather than silently skipping payment', async () => {
      // No CBE adapter registered — the orchestrator must refuse, not no-op.
      const repo = new InMemoryPaymentRepository();
      const svc = new PaymentOrchestratorService(repo, new ProviderRegistry());
      const created = await svc.createPayment({
        ...baseInput, method: 'CBE_BIRR', idempotencyKey: 'key-unk-001',
      });
      await expect(
        svc.initiate(created.payment.id, 'idem-unk-001', payer),
      ).rejects.toThrow(/No payment adapter registered/);
    });
  });
});
