/**
 * In-memory payment adapter for local development and tests.
 *
 * This is NOT a stub that always succeeds — it models the failure modes that
 * actually bite in production (declined, timeout, duplicate), because a mock
 * that only ever succeeds will happily let a broken state machine through CI
 * and then fail in front of a real passenger.
 *
 * Real Telebirr / CBE Birr adapters implement the same interface and slot into
 * `ProviderRegistry` unchanged.
 */

import {
  CaptureRequest,
  InitiateRequest,
  InitiateResult,
  PaymentMethodCode,
  PaymentProviderAdapter,
  PaymentProviderError,
  PaymentStatusCode,
  ProviderStatusResult,
  RefundRequest,
} from './payment-provider';

export type MockBehaviour =
  | 'SUCCEED'
  | 'DECLINE'
  | 'TIMEOUT'
  | 'REQUIRE_ACTION';

export interface MockAdapterOptions {
  behaviour?: MockBehaviour;
  /** Artificial latency, so timeout handling is exercised locally. */
  latencyMs?: number;
}

interface MockRecord {
  status: PaymentStatusCode;
  handle: string;
  settled: boolean;
  amountFils: number;
}

/**
 * Test seam: counts real provider calls, which is how the idempotency tests
 * prove a double-tap did not double-charge.
 */
export const mockAdapterCalls = {
  initiate: 0,
  capture: 0,
  refund: 0,
  status: 0,
};

export function resetMockAdapterCalls(): void {
  mockAdapterCalls.initiate = 0;
  mockAdapterCalls.capture = 0;
  mockAdapterCalls.refund = 0;
  mockAdapterCalls.status = 0;
}

export class MockPaymentAdapter implements PaymentProviderAdapter {
  readonly supportsPolling = true;
  private readonly records = new Map<string, MockRecord>();
  private readonly byIdempotencyKey = new Map<string, string>();

  constructor(
    readonly code: PaymentMethodCode = 'TELEBIRR',
    readonly displayName = 'Mock Provider',
    private options: MockAdapterOptions = {},
  ) {}

  private behaviour(): MockBehaviour {
    return this.options.behaviour ?? 'SUCCEED';
  }

  private async delay(): Promise<void> {
    if (this.options.latencyMs) {
      await new Promise((r) => setTimeout(r, this.options.latencyMs));
    }
  }

  async initiate(req: InitiateRequest, idempotencyKey: string): Promise<InitiateResult> {
    mockAdapterCalls.initiate += 1;
    await this.delay();

    // I2 at the provider boundary: the same key returns the original attempt
    // rather than creating a second one at the provider.
    const existing = this.byIdempotencyKey.get(idempotencyKey);
    if (existing) {
      const rec = this.records.get(existing)!;
      return {
        status: rec.status,
        providerReference: existing,
        providerHandle: rec.handle,
      };
    }

    if (!Number.isInteger(req.amountFils) || req.amountFils <= 0) {
      throw new PaymentProviderError(
        this.code,
        `Invalid amount: ${req.amountFils}`,
        false,
      );
    }

    const handle = `handle-${req.providerReference}`;
    const behaviour = this.behaviour();

    const status: PaymentStatusCode =
      behaviour === 'DECLINE'
        ? 'FAILED'
        : behaviour === 'TIMEOUT'
          ? 'TIMEOUT'
          : behaviour === 'REQUIRE_ACTION'
            ? 'REQUIRES_ACTION'
            : 'CONFIRMED';

    this.records.set(req.providerReference, {
      status,
      handle,
      settled: status === 'CONFIRMED',
      amountFils: req.amountFils,
    });

    if (status === 'CONFIRMED') {
      this.byIdempotencyKey.set(idempotencyKey, req.providerReference);
    }

    return {
      status,
      providerReference: req.providerReference,
      providerHandle: handle,
      redirectUrl:
        status === 'REQUIRES_ACTION'
          ? `https://mock.local/pay/${req.providerReference}`
          : null,
    };
  }

  async capture(req: CaptureRequest): Promise<ProviderStatusResult> {
    mockAdapterCalls.capture += 1;
    await this.delay();

    const rec = this.records.get(req.providerReference);
    if (!rec) {
      throw new PaymentProviderError(
        this.code,
        `Unknown provider reference ${req.providerReference}`,
        false,
      );
    }

    // Over-capture is a revenue leak, so it is rejected rather than clamped.
    if (req.amountFils > rec.amountFils) {
      throw new PaymentProviderError(
        this.code,
        `Capture ${req.amountFils} exceeds authorised ${rec.amountFils}`,
        false,
      );
    }

    rec.status = 'CONFIRMED';
    rec.settled = true;
    return {
      status: rec.status,
      providerReference: req.providerReference,
      providerHandle: rec.handle,
      settled: true,
    };
  }

  async refund(req: RefundRequest): Promise<ProviderStatusResult> {
    mockAdapterCalls.refund += 1;
    await this.delay();

    const rec = this.records.get(req.providerReference);
    if (!rec) {
      throw new PaymentProviderError(
        this.code,
        `Unknown provider reference ${req.providerReference}`,
        false,
      );
    }
    if (req.amountFils > rec.amountFils) {
      throw new PaymentProviderError(
        this.code,
        `Refund ${req.amountFils} exceeds settled ${rec.amountFils}`,
        false,
      );
    }

    rec.status =
      req.amountFils === rec.amountFils ? 'REFUNDED' : 'PARTIALLY_REFUNDED';
    rec.settled = false;
    return {
      status: rec.status,
      providerReference: req.providerReference,
      providerHandle: rec.handle,
      settled: false,
    };
  }

  async status(providerReference: string): Promise<ProviderStatusResult> {
    mockAdapterCalls.status += 1;
    await this.delay();

    const rec = this.records.get(providerReference);
    if (!rec) {
      return { status: 'FAILED', providerReference, settled: false };
    }
    return {
      status: rec.status,
      providerReference,
      providerHandle: rec.handle,
      settled: rec.settled,
    };
  }

  async reverse(providerReference: string): Promise<ProviderStatusResult> {
    const rec = this.records.get(providerReference);
    if (!rec) {
      throw new PaymentProviderError(
        this.code,
        `Unknown provider reference ${providerReference}`,
        false,
      );
    }
    rec.status = 'REVERSED';
    rec.settled = false;
    return {
      status: rec.status,
      providerReference,
      providerHandle: rec.handle,
      settled: false,
    };
  }
}

/**
 * Cash/agent adapter. Settles synchronously because money and ticket change
 * hands in one physical interaction — but it still goes through the orchestrator
 * so assisted sales produce the same core records as self-service.
 */
export class CashPaymentAdapter implements PaymentProviderAdapter {
  readonly code: PaymentMethodCode = 'CASH';
  readonly displayName = 'Cash / Agent';
  /** Nothing to poll: cash is settled by definition when recorded. */
  readonly supportsPolling = false;

  async initiate(req: InitiateRequest): Promise<InitiateResult> {
    return {
      status: 'CONFIRMED',
      providerReference: req.providerReference,
      providerHandle: null,
    };
  }

  async capture(req: CaptureRequest): Promise<ProviderStatusResult> {
    return { status: 'CONFIRMED', providerReference: req.providerReference, settled: true };
  }

  async refund(req: RefundRequest): Promise<ProviderStatusResult> {
    return { status: 'REFUNDED', providerReference: req.providerReference, settled: false };
  }

  async status(providerReference: string): Promise<ProviderStatusResult> {
    return { status: 'CONFIRMED', providerReference, settled: true };
  }
}
